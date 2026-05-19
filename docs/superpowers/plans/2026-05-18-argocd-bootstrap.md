# ArgoCD Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up ArgoCD on the existing k3s cluster, register an App-of-Apps root, and have ArgoCD self-deploy MetalLB, Longhorn, SMB CSI driver, and its own config.

**Architecture:** All ArgoCD configuration lives in `argocd/` in this repo. A kustomization installs ArgoCD (patched to use a LoadBalancer service). A single `root-app.yaml` is the App-of-Apps root, watching `apps/`. Sync waves order MetalLB → Longhorn/SMB CSI → argocd-self. Sync policy is auto-sync + prune, no self-heal. After a one-time `bootstrap.sh`, every cluster-state change is a git push.

**Tech Stack:** ArgoCD, kustomize, kubectl, bash, Helm charts (MetalLB, Longhorn, csi-driver-smb), public GitHub repo `trumpet7347/homelab`.

**Spec:** [docs/superpowers/specs/2026-05-18-argocd-bootstrap-design.md](../specs/2026-05-18-argocd-bootstrap-design.md)

**Notes for the implementer:**
- This is YAML/shell, not application code. There is no unit-test framework. Per-task verification is `kubectl apply --dry-run=client -f <file>` (syntax/schema check) or `kubectl kustomize <dir>` (kustomization render). The real integration test is Task 11, where the operator runs `bootstrap.sh` against the live cluster.
- Operator handles git commits — do NOT run `git add` or `git commit` from subagent code.
- `kubectl` is assumed installed on the workstation. If `kubectl apply --dry-run=client` is unavailable, just confirm files were written with correct content.

---

## File Structure

```
d:\Homelab\argocd\
├── README.md                              # operator-facing docs
├── bootstrap.sh                           # one-shot rebuild script (idempotent)
├── install/                               # raw ArgoCD install kustomization
│   ├── kustomization.yaml                 # references upstream + patches
│   └── patches/
│       ├── server-service.yaml            # argocd-server svc -> LoadBalancer
│       └── server-args.yaml               # argocd-server --insecure (no TLS yet)
├── root-app.yaml                          # App-of-Apps root, watches apps/
├── apps/                                  # one Application per cluster add-on
│   ├── argocd-self.yaml                   # wave 2 — ArgoCD managing its own install
│   ├── metallb.yaml                       # wave 0 — Helm + repo-side config
│   ├── longhorn.yaml                      # wave 1
│   └── smb-csi.yaml                       # wave 1
└── apps-config/                           # config that complements upstream charts
    └── metallb/
        ├── ipaddresspool.yaml             # 192.168.50.154-.159
        └── l2advertisement.yaml
```

**Responsibility split:**

- `install/` — what to put on the cluster to make ArgoCD itself exist.
- `root-app.yaml` — the bridge: tells ArgoCD "watch `apps/`".
- `apps/*.yaml` — one Application per cluster add-on, each pointing at either a remote Helm chart, a path in this repo, or both (`sources:`).
- `apps-config/<name>/` — chart-complementary manifests (IPAddressPool, etc.) that aren't in the upstream chart.
- `bootstrap.sh` — operator-runnable shell. Three commands + a "next steps" message.

---

## Pre-implementation note: version pins

These versions are the recommended pins at writing time (May 2026). The implementer should check the upstream release page for each and bump to the latest stable. The plan body uses these specific values:

- **ArgoCD:** `v2.13.4` (from `argoproj/argo-cd` releases)
- **MetalLB Helm chart:** `0.14.9` (from `metallb.github.io/metallb`)
- **Longhorn Helm chart:** `1.7.2` (from `charts.longhorn.io`)
- **csi-driver-smb Helm chart:** `v1.16.0` (from `kubernetes-csi/csi-driver-smb`)

If newer stable versions exist when implementing, prefer those; values inside `helm.values` may need minor adjustments if a chart's value schema changed.

---

## Task 1: Workspace scaffolding

**Files:**
- Create: `argocd/` (directory)
- Create: `argocd/install/patches/` (directory)
- Create: `argocd/apps/` (directory)
- Create: `argocd/apps-config/metallb/` (directory)

- [ ] **Step 1: Create the directory tree**

Run (PowerShell):
```powershell
New-Item -ItemType Directory -Force -Path `
  argocd/install/patches, `
  argocd/apps, `
  argocd/apps-config/metallb `
  | Out-Null
```

- [ ] **Step 2: Verify**

Run: `Get-ChildItem -Recurse -Directory argocd`
Expected: lists `argocd`, `argocd\install`, `argocd\install\patches`, `argocd\apps`, `argocd\apps-config`, `argocd\apps-config\metallb`.

**Checkpoint:** directory skeleton in place.

---

## Task 2: ArgoCD install kustomization

**Files:**
- Create: `argocd/install/namespace.yaml`
- Create: `argocd/install/kustomization.yaml`
- Create: `argocd/install/patches/server-service.yaml`
- Create: `argocd/install/patches/server-args.yaml`

- [ ] **Step 1: Write `argocd/install/namespace.yaml`**

The upstream ArgoCD `install.yaml` does not create the `argocd` namespace itself, so we include it explicitly as a kustomization resource.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
```

- [ ] **Step 2: Write `argocd/install/kustomization.yaml`**

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: argocd

resources:
  - namespace.yaml
  # Pin ArgoCD to a specific upstream release. Bump deliberately.
  - https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.4/manifests/install.yaml

patches:
  - path: patches/server-service.yaml
    target:
      kind: Service
      name: argocd-server
  - path: patches/server-args.yaml
    target:
      kind: Deployment
      name: argocd-server
```

- [ ] **Step 3: Write `argocd/install/patches/server-service.yaml`**

```yaml
# Patch: make argocd-server reachable via MetalLB once MetalLB lands.
# Before MetalLB is up, the service sits Pending — that's fine, ClusterIP
# access (port-forward) still works.
apiVersion: v1
kind: Service
metadata:
  name: argocd-server
spec:
  type: LoadBalancer
  loadBalancerIP: 192.168.50.154
```

- [ ] **Step 4: Write `argocd/install/patches/server-args.yaml`**

```yaml
# Patch: pass --insecure to argocd-server so it serves HTTP (no TLS).
# Acceptable on a LAN homelab; revisit when adding hostname-based ingress.
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-server
spec:
  template:
    spec:
      containers:
        - name: argocd-server
          command:
            - argocd-server
            - --insecure
```

- [ ] **Step 5: Render the kustomization to verify it builds**

Run (from `d:\Homelab`):
```powershell
kubectl kustomize argocd/install/ | Out-Null
```
Expected: exit 0, no errors. The kustomize render downloads the upstream install.yaml, applies the two patches, and emits all the merged manifests. We don't pipe to a file; we just confirm it succeeds.

If kubectl is not installed locally, skip this step. The integration verification is Task 11.

**Checkpoint:** install kustomization complete; bootstrap can install ArgoCD via `kubectl apply -k argocd/install/`.

---

## Task 3: App-of-Apps root

**Files:**
- Create: `argocd/root-app.yaml`

- [ ] **Step 1: Write `argocd/root-app.yaml`**

```yaml
# The App-of-Apps root. Applied by bootstrap.sh after the install kustomization
# is up. Watches argocd/apps/ as a directory and creates one Application per
# YAML file found.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  project: default

  source:
    repoURL: https://github.com/trumpet7347/homelab.git
    targetRevision: main
    path: argocd/apps
    directory:
      recurse: false

  destination:
    server: https://kubernetes.default.svc
    namespace: argocd

  syncPolicy:
    automated:
      prune: true
      selfHeal: false
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 2: Validate syntax**

Run: `kubectl apply --dry-run=client -f argocd/root-app.yaml`
Expected: `application.argoproj.io/root created (dry run)` or similar success message.

If kubectl is not available, just verify the file is valid YAML by running `python -c "import yaml; yaml.safe_load(open('argocd/root-app.yaml'))"` or similar — and confirm it has `apiVersion`, `kind: Application`, `metadata.name`.

**Checkpoint:** root app in place.

---

## Task 4: MetalLB Application + config

**Files:**
- Create: `argocd/apps/metallb.yaml`
- Create: `argocd/apps-config/metallb/ipaddresspool.yaml`
- Create: `argocd/apps-config/metallb/l2advertisement.yaml`

- [ ] **Step 1: Write `argocd/apps/metallb.yaml`**

```yaml
# MetalLB Application — Helm chart + repo-side config.
# Sync wave 0: must come first so LoadBalancer services (including
# argocd-server itself) get IPs assigned.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: metallb
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default

  sources:
    - repoURL: https://metallb.github.io/metallb
      chart: metallb
      targetRevision: 0.14.9
      helm:
        releaseName: metallb
    - repoURL: https://github.com/trumpet7347/homelab.git
      targetRevision: main
      path: argocd/apps-config/metallb

  destination:
    server: https://kubernetes.default.svc
    namespace: metallb-system

  syncPolicy:
    automated:
      prune: true
      selfHeal: false
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Write `argocd/apps-config/metallb/ipaddresspool.yaml`**

```yaml
# The LB IP pool MetalLB hands out to LoadBalancer services.
# Range matches the reservation in the tofu design.
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lan-pool
  namespace: metallb-system
spec:
  addresses:
    - 192.168.50.154-192.168.50.159
```

- [ ] **Step 3: Write `argocd/apps-config/metallb/l2advertisement.yaml`**

```yaml
# Advertise the pool via L2 (ARP/NDP) so the local LAN sees the IPs.
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lan-pool-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - lan-pool
```

- [ ] **Step 4: Validate each file**

Run:
```powershell
kubectl apply --dry-run=client -f argocd/apps/metallb.yaml
kubectl apply --dry-run=client -f argocd/apps-config/metallb/ipaddresspool.yaml
kubectl apply --dry-run=client -f argocd/apps-config/metallb/l2advertisement.yaml
```
Expected: each prints `... created (dry run)`. (Client-side dry-run won't know about MetalLB CRDs so it may just confirm the YAML parses with the basic required fields — that's fine.)

**Checkpoint:** MetalLB will install (chart) and immediately get its IP pool configured (apps-config).

---

## Task 5: Longhorn Application

**Files:**
- Create: `argocd/apps/longhorn.yaml`

- [ ] **Step 1: Write `argocd/apps/longhorn.yaml`**

```yaml
# Longhorn Application — block storage for in-cluster persistent volumes.
# Sync wave 1: needs MetalLB-allocated LB IPs not strictly required, but
# we group it after MetalLB for predictable ordering.
# Uses the 100 GB scsi1 disk on each k3s-agent node (configured in tofu).
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: longhorn
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default

  source:
    repoURL: https://charts.longhorn.io
    chart: longhorn
    targetRevision: 1.7.2
    helm:
      releaseName: longhorn
      values: |
        # Use the secondary disk attached at /dev/sdb on each worker.
        # Longhorn auto-discovers disks declared in node annotations; the
        # default scans /var/lib/longhorn which lives on the root disk.
        # For now we use the chart default (root-disk-backed) and add the
        # extra-disk config in a follow-up after the cluster is healthy.
        defaultSettings:
          defaultReplicaCount: 2
          # Avoid scheduling Longhorn replicas across the same disk.
          replicaSoftAntiAffinity: true

  destination:
    server: https://kubernetes.default.svc
    namespace: longhorn-system

  syncPolicy:
    automated:
      prune: true
      selfHeal: false
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Validate syntax**

Run: `kubectl apply --dry-run=client -f argocd/apps/longhorn.yaml`
Expected: `application.argoproj.io/longhorn created (dry run)`.

**Checkpoint:** Longhorn Application ready. Disk-discovery configuration on the secondary disk is intentionally deferred to a follow-up — get Longhorn running first, then point it at `/dev/sdb` via node annotations once it's healthy.

---

## Task 6: SMB CSI driver Application

**Files:**
- Create: `argocd/apps/smb-csi.yaml`

- [ ] **Step 1: Write `argocd/apps/smb-csi.yaml`**

```yaml
# csi-driver-smb Application — installs the CSI driver only.
# StorageClass + Secret for the actual media share is added later, once
# the cluster is healthy and we're ready to wire the media stack.
# Sync wave 1: parallel with Longhorn, no inter-dependency.
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: smb-csi
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: default

  source:
    repoURL: https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/charts
    chart: csi-driver-smb
    targetRevision: v1.16.0
    helm:
      releaseName: csi-driver-smb

  destination:
    server: https://kubernetes.default.svc
    namespace: kube-system

  syncPolicy:
    automated:
      prune: true
      selfHeal: false
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
```

- [ ] **Step 2: Validate syntax**

Run: `kubectl apply --dry-run=client -f argocd/apps/smb-csi.yaml`
Expected: `application.argoproj.io/smb-csi created (dry run)`.

**Checkpoint:** SMB CSI driver Application ready.

---

## Task 7: argocd-self Application

**Files:**
- Create: `argocd/apps/argocd-self.yaml`

- [ ] **Step 1: Write `argocd/apps/argocd-self.yaml`**

```yaml
# argocd-self Application — ArgoCD reconciling its own install.
# Points at argocd/install/, the same kustomization the bootstrap script
# applied. Once this is Synced, any change to argocd/install/ propagates
# via git push, no manual kubectl reapply needed.
#
# Sync wave 2: deploys after MetalLB so the LoadBalancer service can be
# assigned an IP cleanly. (Strictly speaking, wave order is for clarity;
# the install is idempotent and applies fine in any order.)
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd-self
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "2"
spec:
  project: default

  source:
    repoURL: https://github.com/trumpet7347/homelab.git
    targetRevision: main
    path: argocd/install

  destination:
    server: https://kubernetes.default.svc
    namespace: argocd

  syncPolicy:
    automated:
      prune: false       # don't let ArgoCD prune its own resources
      selfHeal: false
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - ApplyOutOfSyncOnly=true
```

**Why `prune: false` for argocd-self specifically:** if ArgoCD ever decides one of its own controller resources is "out of scope" and prunes it, the controller can knock itself offline. Auto-prune is fine for everything else where we control the manifests fully; for the self-reconciliation loop, conservative is correct.

- [ ] **Step 2: Validate syntax**

Run: `kubectl apply --dry-run=client -f argocd/apps/argocd-self.yaml`
Expected: `application.argoproj.io/argocd-self created (dry run)`.

**Checkpoint:** the self-management loop is wired.

---

## Task 8: Bootstrap script

**Files:**
- Create: `argocd/bootstrap.sh`

- [ ] **Step 1: Write `argocd/bootstrap.sh`**

```bash
#!/usr/bin/env bash
#
# argocd/bootstrap.sh — install ArgoCD and register the App-of-Apps root.
# Idempotent: safe to re-run any number of times.
#
# Prerequisites:
#   - kubectl on PATH
#   - KUBECONFIG env var (or default ~/.kube/config) points at the target cluster
#   - The k3s cluster from tofu/ is up and healthy
#   - This repo is pushed to github.com/trumpet7347/homelab on the main branch

set -euo pipefail

# Resolve the directory this script lives in, so it works regardless of cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Sanity: cluster reachable?
kubectl cluster-info >/dev/null

echo "==> Installing ArgoCD (kustomize, pinned version)"
kubectl apply -k "${SCRIPT_DIR}/install/"

echo "==> Waiting for argocd-server to be ready (up to 5 minutes)"
kubectl -n argocd rollout status deploy/argocd-server --timeout=5m

echo "==> Registering App-of-Apps root"
kubectl apply -f "${SCRIPT_DIR}/root-app.yaml"

cat <<'EOF'

ArgoCD bootstrapped.

Initial admin password:
  kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' | base64 -d ; echo

UI (while MetalLB is still coming up):
  kubectl -n argocd port-forward svc/argocd-server 8080:443
  # Then visit http://localhost:8080 (NOTE: --insecure, no TLS)

Once MetalLB has provisioned the LB IP (~2 minutes), check it:
  kubectl -n argocd get svc argocd-server

Then the UI is reachable at http://192.168.50.154.
EOF
```

- [ ] **Step 2: Verify bash syntax**

Run (from `d:\Homelab` via Git Bash or WSL):
```bash
bash -n argocd/bootstrap.sh
```
Expected: exit 0, no output. (`bash -n` parses the script without executing it.)

If running on Windows where `bash` isn't readily available, skip — the script will be executed at Task 11 anyway and will fail loudly if there are syntax errors.

**Checkpoint:** bootstrap script ready. The script handles the entire bootstrap with three commands plus a "what to do next" message.

---

## Task 9: README for the argocd/ directory

**Files:**
- Create: `argocd/README.md`

- [ ] **Step 1: Write `argocd/README.md`**

```markdown
# ArgoCD configuration

This directory holds everything ArgoCD needs to bootstrap and manage the
cluster's add-ons. Once bootstrapped, every change here is reconciled by
ArgoCD on the next git push (auto-sync, auto-prune, no self-heal).

## Layout

- `install/` — kustomization that installs ArgoCD (with `argocd-server`
  patched to `type: LoadBalancer` and `--insecure` for now).
- `root-app.yaml` — the App-of-Apps root; applied once by `bootstrap.sh`.
- `apps/*.yaml` — one Application per cluster add-on. Add a file here,
  push, ArgoCD picks it up.
- `apps-config/<name>/` — manifests that complement a chart but aren't
  in it (e.g., MetalLB's `IPAddressPool` and `L2Advertisement`).
- `bootstrap.sh` — idempotent one-shot for fresh clusters.

## Bootstrap (fresh cluster)

```bash
export KUBECONFIG=<path-to-cluster-kubeconfig>
bash argocd/bootstrap.sh
```

The script:
1. Applies `install/` (ArgoCD itself).
2. Waits for `argocd-server` to be Ready.
3. Applies `root-app.yaml`.

Then ArgoCD takes over and syncs everything in `apps/`.

## First-time login

```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d ; echo
```

Username is `admin`. Change the password from the UI after logging in;
the initial secret can then be deleted (`kubectl -n argocd delete secret
argocd-initial-admin-secret`).

## Day-2 ops

| Action | How |
|---|---|
| Add a cluster add-on | Drop `apps/<name>.yaml`; push. |
| Upgrade an add-on | Bump `targetRevision` in `apps/<name>.yaml`; push. |
| Tweak ArgoCD itself | Edit `install/`; push. The `argocd-self` Application reconciles. |
| Add Pi-hole DNS + Traefik ingress for `argocd.lan` | Add IngressRoute to `install/`, add DNS entry, push. |
| Rebuild the cluster | `tofu destroy && tofu apply` (in `../tofu`), then re-run `bootstrap.sh`. |

## Sync waves

The Applications in `apps/` use the
`argocd.argoproj.io/sync-wave` annotation to order startup:

| Wave | Apps |
|---|---|
| 0 | metallb |
| 1 | longhorn, smb-csi |
| 2 | argocd-self |
```

- [ ] **Step 2: Verify the file rendered correctly**

Run: `Get-Content argocd/README.md -TotalCount 5`
Expected: shows the top of the README (the title `# ArgoCD configuration` plus the next few lines).

**Checkpoint:** documentation in place.

---

## Task 10: Operator pushes to GitHub

**Files:** none — operator action.

Before running `bootstrap.sh`, the `argocd/` directory must exist on the
`main` branch of `github.com/trumpet7347/homelab`. ArgoCD clones from there,
not from the local filesystem.

- [ ] **Step 1: Stage and commit**

The operator handles their own commits. Suggested:
```powershell
git add argocd/ docs/superpowers/specs/2026-05-18-argocd-bootstrap-design.md docs/superpowers/plans/2026-05-18-argocd-bootstrap.md
git status   # confirm only intended files staged
git commit -m "Add ArgoCD bootstrap"
```

- [ ] **Step 2: Push to main**

```powershell
git push homelab main
```

- [ ] **Step 3: Verify the repo URL is reachable**

```powershell
curl.exe -sI https://raw.githubusercontent.com/trumpet7347/homelab/main/argocd/root-app.yaml
```
Expected: `HTTP/2 200`. Anything else (404, 403) means ArgoCD won't be able to fetch the manifests — fix before continuing.

**Checkpoint:** `argocd/` is live on GitHub `main`, reachable to ArgoCD.

---

## Task 11: Run the bootstrap

**Files:** none — operator action against the live cluster.

- [ ] **Step 1: Verify cluster is reachable**

```powershell
$env:KUBECONFIG = (Resolve-Path d:\Homelab\kubeconfig).Path
kubectl get nodes
```
Expected: three `Ready` nodes.

- [ ] **Step 2: Run the bootstrap**

```powershell
bash argocd/bootstrap.sh
```
Expected output (approximate):
```
==> Installing ArgoCD (kustomize, pinned version)
namespace/argocd created
customresourcedefinition.apiextensions.k8s.io/applications.argoproj.io created
... (many resources)
==> Waiting for argocd-server to be ready (up to 5 minutes)
deployment "argocd-server" successfully rolled out
==> Registering App-of-Apps root
application.argoproj.io/root created

ArgoCD bootstrapped.
...
```

If the script errors, the most likely causes are:
- `kubectl cluster-info` fails → KUBECONFIG isn't pointing at the cluster
- `kubectl apply -k install/` fails → check `kubectl kustomize argocd/install/` output for the actual problem
- Rollout times out → check `kubectl -n argocd get pods` for ImagePullBackOff or CrashLoopBackOff

- [ ] **Step 3: Get the initial admin password and log in via port-forward**

```powershell
kubectl -n argocd get secret argocd-initial-admin-secret `
  -o jsonpath='{.data.password}' | base64 -d
# in a separate shell:
kubectl -n argocd port-forward svc/argocd-server 8080:443
# visit http://localhost:8080, log in as admin with the password above
```

In the UI, you should see five Applications: `root`, `metallb`, `longhorn`, `smb-csi`, `argocd-self`. They sync in wave order. After ~2-3 minutes, all should be `Synced` and `Healthy`.

- [ ] **Step 4: Verify the LB IP got assigned**

```powershell
kubectl -n argocd get svc argocd-server
```
Expected: the `EXTERNAL-IP` column shows `192.168.50.154` (not `<pending>`). If it's still pending after 5 minutes, check MetalLB:
```powershell
kubectl -n metallb-system get pods
kubectl -n metallb-system get ipaddresspool,l2advertisement
```

- [ ] **Step 5: Visit the UI at the LAN IP**

In a browser: `http://192.168.50.154`. Log in. You should see the same Applications. Port-forward is no longer needed.

- [ ] **Step 6: Change the admin password and delete the initial secret**

In the ArgoCD UI: User Info → Update Password. Then:
```powershell
kubectl -n argocd delete secret argocd-initial-admin-secret
```

**Checkpoint:** cluster has ArgoCD up at `http://192.168.50.154`, managing MetalLB / Longhorn / SMB CSI / itself. Every future change is a git push.

---

## Self-review notes

- **Spec coverage:** Bootstrap flow (Task 11), install kustomization (Task 2), root-app (Task 3), MetalLB+config (Task 4), Longhorn (Task 5), SMB CSI (Task 6), argocd-self (Task 7), bootstrap.sh (Task 8), README + day-2 ops (Task 9), repo layout (file structure section). The spec's "out of scope" items (TLS, OIDC, sealed-secrets, etc.) are correctly absent from the plan.
- **Placeholder scan:** No "TBD" / "TODO" / "fill in details" remain. Each step has exact content.
- **Type/name consistency:** App names (`metallb`, `longhorn`, `smb-csi`, `argocd-self`, `root`) consistent across files and tasks. Namespace names (`argocd`, `metallb-system`, `longhorn-system`, `kube-system`) consistent. Sync-wave numbers consistent with spec (0/1/1/2).
- **Commits are deferred** per project convention. Operator handles them in Task 10.
