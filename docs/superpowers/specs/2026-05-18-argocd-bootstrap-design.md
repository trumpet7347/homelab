# ArgoCD Bootstrap — Design

**Date:** 2026-05-18
**Status:** Approved, ready for implementation
**Author:** psmith@riskexec.com

## Goals

Stand up ArgoCD on the existing 3-node k3s cluster (`192.168.50.150–.152`)
as the GitOps controller for every subsequent cluster add-on (MetalLB,
Longhorn, SMB CSI driver) and, eventually, the workload apps (media
stack). ArgoCD reads from the public GitHub repo
`trumpet7347/homelab` at `argocd/` and reconciles continuously.

Once bootstrapped, every cluster-state change is a `git push`. The only
manual steps are the one-time `bootstrap.sh` after a fresh cluster and
retrieving the initial admin password.

## Non-goals

- TLS / proper signed cert for the ArgoCD UI (uses self-signed +
  `--insecure` for now; revisit when adding hostname-based ingress)
- OIDC / SSO (default `admin` only)
- Secrets stored in git (no sealed-secrets / SOPS yet; sensitive values
  live as cluster-side Secrets created out-of-band)
- ApplicationSets (overkill for ~5 apps)
- Multi-cluster (single cluster)
- Workload app configs themselves (each gets its own spec later)

## Environment

| Item | Value |
|---|---|
| Cluster | 3-node k3s on Proxmox (existing, provisioned by `tofu/`) |
| Cluster API | `https://192.168.50.150:6443` |
| Repo (public) | `github.com/trumpet7347/homelab` |
| LB IP pool | `192.168.50.154–.159` (reserved earlier, to be claimed by MetalLB) |
| ArgoCD target LB IP | `192.168.50.154` (first in pool) |

## Architecture

ArgoCD runs in the `argocd` namespace. The bootstrap is a single shell
script the operator runs on their workstation against the cluster's
kubeconfig:

1. `kubectl apply -k argocd/install/` — installs ArgoCD with its
   `argocd-server` service patched to `type: LoadBalancer`. With no
   LB controller in the cluster yet, the service stays `Pending`;
   ClusterIP access (port-forward) still works.
2. `kubectl apply -f argocd/root-app.yaml` — registers the App-of-Apps
   root, a single `Application` whose source is `argocd/apps/` as a
   `directory`. ArgoCD discovers every `apps/*.yaml` as a child app.
3. ArgoCD reconciles child apps in sync-wave order:
   - **Wave 0:** `metallb` (Helm chart + this repo's `apps-config/metallb`
     for `IPAddressPool` and `L2Advertisement`).
   - **Wave 1:** `longhorn`, `smb-csi` — parallel, no inter-dependency.
   - **Wave 2:** `argocd-self` — points back at `argocd/install/`,
     putting ArgoCD's own install under GitOps control.
4. Once MetalLB is up, it sees the Pending `argocd-server` service and
   assigns `192.168.50.154`. The UI becomes reachable at that IP.

```
[operator] -- ./bootstrap.sh --> [k3s cluster]
                                  │
                                  ├─ kubectl apply -k argocd/install/  (ArgoCD up, svc Pending)
                                  ├─ rollout status (wait for ready)
                                  └─ kubectl apply -f argocd/root-app.yaml
                                              │
                                              ▼
                                       [root-app discovers apps/]
                                              │
                                              ├ wave 0 ─> metallb        ─┐
                                              ├ wave 1 ─> longhorn        │   reconcile
                                              ├ wave 1 ─> smb-csi         │   loop
                                              └ wave 2 ─> argocd-self    ─┘
                                              │
                                              ▼
                                    MetalLB assigns 192.168.50.154
                                    to argocd-server (svc)
```

## Repo layout

```
d:\Homelab\
├── tofu/                                # (existing)
└── argocd/
    ├── README.md                        # operator-facing: how to bootstrap, day-2 ops
    ├── bootstrap.sh                     # idempotent one-shot script
    ├── install/                         # raw ArgoCD install (kustomization)
    │   ├── kustomization.yaml           # references upstream install.yaml @ a pinned tag
    │   └── patches/
    │       ├── server-service.yaml      # patch argocd-server svc -> type: LoadBalancer
    │       └── server-args.yaml         # patch argocd-server cmd args (--insecure for now)
    ├── root-app.yaml                    # the App-of-Apps root, watches apps/
    ├── apps/                            # one Application per cluster add-on
    │   ├── metallb.yaml                 # wave 0
    │   ├── longhorn.yaml                # wave 1
    │   ├── smb-csi.yaml                 # wave 1
    │   └── argocd-self.yaml             # wave 2
    └── apps-config/                     # per-app config that complements upstream charts
        └── metallb/
            ├── ipaddresspool.yaml       # 192.168.50.154-.159
            └── l2advertisement.yaml
```

### Key choices

- **Single repo for tofu + argocd.** No split. One operator, one repo,
  no cross-repo coordination.
- **`install/` is a kustomization over the upstream ArgoCD
  `install.yaml`** at a pinned release tag. Upgrades = bump the tag.
- **`root-app.yaml` is plain top-level YAML** because applying it is the
  manual bootstrap step. Source: `argocd/apps/` as `directory` so any new
  `apps/*.yaml` is auto-discovered.
- **`apps/argocd-self.yaml` points at `argocd/install/`.** This closes
  the loop: post-bootstrap, ArgoCD config changes are reconciled from
  git like anything else.
- **`apps-config/<app>/` holds chart values + complementary manifests**
  that aren't part of the upstream chart (e.g., MetalLB's `IPAddressPool`).
  Apps that need this use `sources:` (plural) with two entries.
- **Each child Application gets its own namespace** managed by the
  Application itself (`syncOptions: [CreateNamespace=true]`),
  matching each chart's upstream convention
  (`metallb-system`, `longhorn-system`, etc.).

## ArgoCD configuration

- **Version:** ArgoCD pinned to a specific release tag in
  `install/kustomization.yaml` (selected at implementation time;
  latest stable v2.x or v3.x). Bump deliberately.
- **`argocd-server` service:** `type: LoadBalancer` from day one. Sits
  Pending on a fresh cluster; MetalLB fulfills it during sync. ClusterIP
  access (port-forward) always works as a side channel.
- **`argocd-server` args:** `--insecure` (no TLS termination at the
  ArgoCD pod). Acceptable for LAN-only homelab; revisit when adding
  ingress-based hostname + cert.
- **Auth:** default `admin`. Operator retrieves the initial password
  from `argocd-initial-admin-secret` post-bootstrap and changes it via
  the UI. No OIDC.

## Sync policy

All child Applications use the same sync policy (project convention):

```yaml
syncPolicy:
  automated:
    prune: true        # delete in git -> delete from cluster
    selfHeal: false    # allow ad-hoc kubectl edits without revert
  syncOptions: [CreateNamespace=true]
```

The root App-of-Apps Application uses the same policy so newly-added
files in `apps/` are picked up automatically.

## Sync waves

The `argocd.argoproj.io/sync-wave` annotation orders apps. Lower numbers
sync first; ties run in parallel.

| Wave | App | Rationale |
|---|---|---|
| 0 | metallb | LB IPs needed by `argocd-server` (and everything else) |
| 1 | longhorn, smb-csi | independent, run in parallel |
| 2 | argocd-self | reconciles ArgoCD's own install; idempotent — confirms what's already there |

The ordering is for clarity/observability in the UI. Strictly speaking,
ArgoCD could deploy itself first with a Pending LB and MetalLB second;
the Pending state resolves whenever MetalLB lands.

## Bootstrap script

`argocd/bootstrap.sh` — idempotent shell:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Sanity: KUBECONFIG must point at the target cluster.
kubectl cluster-info >/dev/null

# 1. Install ArgoCD via our kustomization
kubectl apply -k argocd/install/

# 2. Wait for the controller to be ready before applying the root app
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m

# 3. Register the App-of-Apps root
kubectl apply -f argocd/root-app.yaml

# 4. Operator next-steps
cat <<EOF

ArgoCD bootstrapped. Next steps:

  Initial admin password:
    kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath='{.data.password}' | base64 -d ; echo

  UI (while waiting for MetalLB):
    kubectl -n argocd port-forward svc/argocd-server 8080:443

  Once MetalLB has provisioned the LB IP (~2 min):
    kubectl -n argocd get svc argocd-server
EOF
```

Re-runnable any number of times. Both `kubectl apply -k` and `apply -f`
are idempotent; the rollout-status wait short-circuits on subsequent
runs.

## Prerequisites

Before running `bootstrap.sh`:

1. The k3s cluster from the `tofu/` spec is up. `kubectl get nodes` shows
   3 `Ready` nodes.
2. `KUBECONFIG` env var points at the cluster's kubeconfig
   (`d:\Homelab\kubeconfig` from the tofu phase).
3. `kubectl` and (for some day-2 ops) `argocd` CLI installed on the
   workstation.
4. The repo is pushed to `github.com/trumpet7347/homelab` and the
   `argocd/` directory is reachable as a public source.

## Day-2 ops the design supports

| Action | How |
|---|---|
| Add a new app | Drop `apps/<name>.yaml` into git, push. Root app auto-discovers. |
| Upgrade an app | Bump `targetRevision` in `apps/<name>.yaml`, commit. ArgoCD pulls new chart, syncs. |
| Tweak ArgoCD itself (TLS, ingress, OIDC, etc.) | Edit `install/`. Push. `apps/argocd-self.yaml` reconciles. |
| Move to Traefik + `argocd.lan` (the "option C" end state) | Add IngressRoute to `install/`, add Pi-hole DNS entry, push. |
| Rebuild cluster | `tofu destroy && tofu apply`, then `./bootstrap.sh`. Convergence is automatic; no rollback dance required. |
| Quick debug edit | `kubectl edit ...` works — `selfHeal: false` means ArgoCD won't revert it. Sync from UI/CLI when ready to bake it back into git. |

## Out of scope (deferred)

- TLS termination for the ArgoCD UI (added when hostname-based ingress lands)
- OIDC / SSO
- Sealed-secrets or SOPS for committable secrets
- ApplicationSets (revisit if app count grows beyond ~10)
- Multi-cluster setup
- Backup of ArgoCD state (it's all reconstructible from git anyway)
- Workload apps (media stack, etc.) — each gets its own spec
