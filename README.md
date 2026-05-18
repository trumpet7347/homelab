# Homelab

Infrastructure-as-code for my homelab.

## Layout

- `tofu/` — OpenTofu configuration that provisions the k3s cluster on Proxmox.
- `docs/superpowers/specs/` — design documents.
- `docs/superpowers/plans/` — implementation plans.

Future siblings will include `ansible/` and `argocd/` directories.

## k3s cluster bootstrap

See `tofu/README.md` (created during cluster setup) or the design at
`docs/superpowers/specs/2026-05-16-k3s-cluster-opentofu-design.md`.
