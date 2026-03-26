set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
_require *tools:
    #!/usr/bin/env bash
    for tool in {{tools}}; do
      if ! command -v "$tool" &>/dev/null; then
        echo "Error: '$tool' is required but not installed." >&2
        exit 1
      fi
    done

[doc('List available Velero backups')]
backups: (_require "velero")
    velero backup get

[doc('List PVCs included in a Velero backup, optionally filtered by search string')]
view-pvc backup filter="": (_require "velero")
    #!/usr/bin/env bash
    set -euo pipefail

    DETAILS=$(velero backup describe {{backup}} --details 2>&1)

    if echo "$DETAILS" | grep -q "not found"; then
      echo "ERROR: Backup '{{backup}}' not found"
      exit 1
    fi

    PHASE=$(echo "$DETAILS" | awk '/^Phase:/{print $2}')
    echo "Backup: {{backup}} (Phase: $PHASE)"
    echo ""

    PVCS=$(echo "$DETAILS" \
      | sed -n '/v1\/PersistentVolumeClaim:/,/^  [a-zA-Z]/p' \
      | grep '^ *- ' \
      | sed 's/^ *- //' \
      | sort)

    if [ -z "$PVCS" ]; then
      echo "No PVCs found in this backup."
      exit 0
    fi

    if [ -n "{{filter}}" ]; then
      echo "PVCs matching '{{filter}}':"
      echo "$PVCS" | grep -i "{{filter}}" || echo "  (none)"
    else
      echo "PVCs in backup:"
      echo "$PVCS" | awk -F'/' '{printf "  %-20s %s\n", $1, $2}'
    fi

# Usage:
#   just velero restore-pvc velero-daily-backups-20260316010049 overseerr
#   just velero restore-pvc velero-daily-backups-20260325010002 paperless paperless-data
#   just velero restore-pvc velero-daily-backups-20260325010002 stirling-pdf stirling-pdf-configs stirling-pdf-logs
[doc('Restore PVCs from a Velero backup (namespace inferred from ArgoCD, PVC defaults to all)')]
restore-pvc backup app *pvc: (_require "velero" "kubectl")
    #!/usr/bin/env bash
    set -euo pipefail

    NAMESPACE=$(kubectl get application {{app}} -n argocd \
      -o jsonpath='{.spec.destination.namespace}' 2>/dev/null) || {
      echo "ERROR: Could not find ArgoCD application '{{app}}'"
      exit 1
    }
    echo "==> Resolved namespace: $NAMESPACE"

    echo "==> Pausing ArgoCD reconciliation for '{{app}}'..."
    just argocd pause {{app}}

    echo "==> Scaling down '{{app}}' in namespace '$NAMESPACE'..."
    kubectl scale deployment {{app}} -n "$NAMESPACE" --replicas=0
    kubectl wait --for=delete pod \
      -l app.kubernetes.io/name={{app}} -n "$NAMESPACE" --timeout=120s || true

    if [ -n "{{pvc}}" ]; then
      PVCS="{{pvc}}"
    else
      PVCS=$(kubectl get pvc -n "$NAMESPACE" \
        -l app.kubernetes.io/name={{app}} \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
      if [ -z "$PVCS" ]; then
        echo "ERROR: No PVCs found for app '{{app}}' in namespace '$NAMESPACE'"
        exit 1
      fi
      echo "==> Found PVCs: $PVCS"
    fi

    for PVC_NAME in $PVCS; do
      echo "==> Deleting PVC '$PVC_NAME'..."
      kubectl delete pvc "$PVC_NAME" -n "$NAMESPACE" --timeout=60s
    done

    echo "==> Restoring from backup '{{backup}}'..."
    RESTORE_NAME="{{app}}-restore-$(date +%s)"
    velero restore create "$RESTORE_NAME" \
      --from-backup {{backup}} \
      --include-namespaces "$NAMESPACE" \
      --include-resources persistentvolumeclaims,persistentvolumes,volumesnapshots.snapshot.storage.k8s.io,volumesnapshotcontents.snapshot.storage.k8s.io \
      --selector "app.kubernetes.io/name={{app}}" \
      --existing-resource-policy none

    echo "==> Waiting for PVCs to bind..."
    for PVC_NAME in $PVCS; do
      for i in $(seq 1 30); do
        STATUS=$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
        if [ "$STATUS" = "Bound" ]; then
          echo "    PVC '$PVC_NAME' is Bound!"
          break
        fi
        echo "    [$i/30] PVC '$PVC_NAME' status: $STATUS"
        sleep 10
      done

      if [ "$STATUS" != "Bound" ]; then
        echo "ERROR: PVC '$PVC_NAME' did not bind within 5 minutes. Check events:"
        kubectl get events -n "$NAMESPACE" \
          --field-selector "involvedObject.name=$PVC_NAME" \
          --sort-by=.lastTimestamp | tail -5
        echo ""
        echo "WARNING: ArgoCD reconciliation is still paused for '{{app}}'."
        echo "  Resume manually when ready: just argocd resume {{app}}"
        exit 1
      fi
    done

    echo "==> Scaling up '{{app}}'..."
    kubectl scale deployment {{app}} -n "$NAMESPACE" --replicas=1
    kubectl rollout status deployment {{app}} -n "$NAMESPACE" --timeout=120s

    echo "==> Resuming ArgoCD reconciliation for '{{app}}'..."
    just argocd resume {{app}}

    echo "==> Done! Verify the application is working correctly."
