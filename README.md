# homelab

## Bootstrap

ArgoCD is self-managing — it watches `kubernetes/bootstrap/argocd/` in this repo
and syncs its own installation. Renovate proposes version bumps via PR; merging
triggers ArgoCD to upgrade itself.

### Fresh cluster

```bash
just bootstrap
```

Runs: namespace → SOPS age secret → `kubectl apply -k` (ArgoCD HA install) →
wait for components → apply self-managing Application + root Applications.

### Re-bootstrap (existing cluster)

Same command — all steps are idempotent (SSA with `--force-conflicts`).

### Operational recipes

```bash
just argocd prune    # find and delete orphaned resources after upgrades
```

## Structure

```
kubernetes/
├── apps/                          # Application manifests (managed by ArgoCD)
├── infra/                         # Infrastructure manifests (managed by ArgoCD)
└── bootstrap/
    ├── argocd/
    │   ├── kustomization.yaml     # Upstream HA base + patches (?ref= pinned)
    │   ├── app.yaml               # Self-managing ArgoCD Application
    │   ├── namespace.yaml         # argocd namespace
    │   ├── mod.just               # Operational recipes (prune)
    │   └── patches/               # Kustomize patches (cm, ksops, etc.)
    ├── infra.yaml                 # Root infra Application
    ├── apps.yaml                  # Root apps Application
    └── mod.just                   # Bootstrap recipes
```
