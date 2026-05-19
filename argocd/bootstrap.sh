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
