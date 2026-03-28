set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

[doc('Bootstrap the cluster (ArgoCD + apps)')]
mod bootstrap "kubernetes/bootstrap"
mod argocd "kubernetes/bootstrap/argocd"
mod velero "kubernetes/infra/velero"
[doc('Validate Kubernetes manifests (Kustomize, Helm, images)')]
mod validate ".just/validate.just"
[doc('Lint code (YAML, JSON, Actions, Markdown, Renovate)')]
mod lint ".just/lint.just"

[doc('List available recipes')]
[private]
default:
    @just --color always --list --list-submodules \
      | sed 's/^    bootstrap:$/    bootstrap \x1b[34m#\x1b[0m \x1b[34mBootstrap the cluster (ArgoCD + apps)\x1b[0m/' \
      | sed 's/^    validate:$/    validate  \x1b[34m#\x1b[0m \x1b[34mValidate Kubernetes manifests (Kustomize, Helm, images)\x1b[0m/' \
      | sed 's/^    lint:$/    lint      \x1b[34m#\x1b[0m \x1b[34mLint code (YAML, JSON, Actions, Markdown, Renovate)\x1b[0m/'

[private]
_require *tools:
    #!/usr/bin/env bash
    for tool in {{tools}}; do
      if ! command -v "$tool" &>/dev/null; then
        echo "Error: '$tool' is required but not installed." >&2
        exit 1
      fi
    done

[doc('Run all linters and validators')]
verify:
    @echo "==> Linting..."
    @just lint
    @echo ""
    @echo "==> Validating manifests..."
    @just validate

[doc('Restart all deployments that use PVCs (e.g. after PCS failover)')]
restart-deployments-with-pvc: (_require "kubectl" "jq")
    #!/usr/bin/env bash
    set -euo pipefail

    echo "==> Finding deployments with PersistentVolumeClaims..."
    PODS=$(kubectl get deploy -A -o json | \
      jq -r '.items[] | select(.spec.template.spec.volumes[]? | has("persistentVolumeClaim")) | "\(.metadata.namespace) \(.metadata.name)"')

    if [ -z "$PODS" ]; then
      echo "No deployments with PVCs found."
      exit 0
    fi

    echo "$PODS" | while read ns name; do
      echo "  Restarting $ns/$name..."
      kubectl rollout restart deployment "$name" -n "$ns"
    done

    echo "==> Waiting for rollouts to complete..."
    echo "$PODS" | while read ns name; do
      kubectl rollout status deployment "$name" -n "$ns" --timeout=120s || \
        echo "  WARNING: $ns/$name rollout did not complete within 120s"
    done

    echo "==> Done!"
