set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

mod bootstrap "kubernetes/bootstrap"
mod argocd "kubernetes/bootstrap/argocd"

# List available backups
velero-backups:
    velero backup get

# Restore a PVC from a Velero backup using CSI snapshots.
#
# This handles the full lifecycle: pausing ArgoCD, scaling down,
# deleting the old PVC, restoring from backup, scaling back up,
# and re-enabling ArgoCD.
#
# Usage:
#   just velero-restore-pvc overseerr media overseerr-config velero-daily-backups-20260316010049
#   just velero-restore-pvc paperless paperless paperless-data velero-daily-backups-20260325010002
velero-restore-pvc app namespace pvc backup:
    #!/usr/bin/env bash
    set -euo pipefail

    echo "==> Pausing ArgoCD reconciliation for '{{app}}'..."
    kubectl annotate application {{app}} -n argocd \
      argocd.argoproj.io/skip-reconcile="true" --overwrite

    echo "==> Scaling down '{{app}}' in namespace '{{namespace}}'..."
    kubectl scale deployment {{app}} -n {{namespace}} --replicas=0
    kubectl wait --for=delete pod \
      -l app.kubernetes.io/name={{app}} -n {{namespace}} --timeout=120s || true

    echo "==> Deleting PVC '{{pvc}}'..."
    kubectl delete pvc {{pvc}} -n {{namespace}} --timeout=60s

    echo "==> Restoring from backup '{{backup}}'..."
    RESTORE_NAME="{{app}}-{{pvc}}-restore-$(date +%s)"
    velero restore create "$RESTORE_NAME" \
      --from-backup {{backup}} \
      --include-namespaces {{namespace}} \
      --include-resources persistentvolumeclaims,persistentvolumes,volumesnapshots.snapshot.storage.k8s.io,volumesnapshotcontents.snapshot.storage.k8s.io \
      --selector "app.kubernetes.io/name={{app}}" \
      --existing-resource-policy none

    echo "==> Waiting for PVC '{{pvc}}' to bind..."
    for i in $(seq 1 30); do
      STATUS=$(kubectl get pvc {{pvc}} -n {{namespace}} -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
      if [ "$STATUS" = "Bound" ]; then
        echo "    PVC is Bound!"
        break
      fi
      echo "    [$i/30] PVC status: $STATUS"
      sleep 10
    done

    if [ "$STATUS" != "Bound" ]; then
      echo "ERROR: PVC did not bind within 5 minutes. Check events:"
      kubectl get events -n {{namespace}} \
        --field-selector involvedObject.name={{pvc}} \
        --sort-by=.lastTimestamp | tail -5
      exit 1
    fi

    echo "==> Scaling up '{{app}}'..."
    kubectl scale deployment {{app}} -n {{namespace}} --replicas=1
    kubectl rollout status deployment {{app}} -n {{namespace}} --timeout=120s

    echo "==> Resuming ArgoCD reconciliation for '{{app}}'..."
    kubectl annotate application {{app}} -n argocd \
      argocd.argoproj.io/skip-reconcile-

    echo "==> Done! Verify the application is working correctly."

# Check which PVCs are included in a specific Velero backup
velero-check-backup backup app="":
    #!/usr/bin/env bash
    if [ -n "{{app}}" ]; then
      velero backup describe {{backup}} --details 2>&1 | grep -i "{{app}}"
    else
      velero backup describe {{backup}} --details 2>&1 | grep -E "Operation for|Operation ID"
    fi

# Pause ArgoCD reconciliation for an application
argocd-pause app:
    kubectl annotate application {{app}} -n argocd \
      argocd.argoproj.io/skip-reconcile="true" --overwrite
    @echo "ArgoCD reconciliation paused for '{{app}}'"

# Resume ArgoCD reconciliation for an application
argocd-resume app:
    kubectl annotate application {{app}} -n argocd \
      argocd.argoproj.io/skip-reconcile-
    @echo "ArgoCD reconciliation resumed for '{{app}}'"

# Restart all deployments that use iSCSI PVCs (e.g., after PCS failover)
restart-iscsi-pods:
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
