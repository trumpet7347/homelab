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
