set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

[doc('Bootstrap the cluster (ArgoCD + apps)')]
mod bootstrap "kubernetes/bootstrap"
[doc('Manage ArgoCD reconciliation and pruning')]
mod argocd "kubernetes/bootstrap/argocd"
[doc('Manage Velero backups and PVC restores')]
mod velero "kubernetes/infra/velero"

[doc('List available recipes')]
[private]
default:
    @just --list

[private]
_require *tools:
    #!/usr/bin/env bash
    for tool in {{tools}}; do
      if ! command -v "$tool" &>/dev/null; then
        echo "Error: '$tool' is required but not installed." >&2
        exit 1
      fi
    done

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
