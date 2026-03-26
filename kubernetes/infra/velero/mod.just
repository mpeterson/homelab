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

[doc('Check which PVCs are included in a Velero backup')]
check-backup backup app="": (_require "velero")
    #!/usr/bin/env bash
    if [ -n "{{app}}" ]; then
      velero backup describe {{backup}} --details 2>&1 | grep -i "{{app}}"
    else
      velero backup describe {{backup}} --details 2>&1 | grep -E "Operation for|Operation ID"
    fi

# Usage:
#   just velero restore-pvc overseerr media overseerr-config velero-daily-backups-20260316010049
#   just velero restore-pvc paperless paperless paperless-data velero-daily-backups-20260325010002
[doc('Restore a PVC from a Velero backup using CSI snapshots')]
restore-pvc app namespace pvc backup: (_require "velero" "kubectl")
    #!/usr/bin/env bash
    set -euo pipefail

    echo "==> Pausing ArgoCD reconciliation for '{{app}}'..."
    just argocd pause {{app}}

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
    just argocd resume {{app}}

    echo "==> Done! Verify the application is working correctly."
