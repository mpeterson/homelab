set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    @just --unstable --list velero

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

# This workflow restores CSI snapshots from daily backups. FSB backups require a
# whole-workload restore so Velero can inject the PodVolumeRestore helper.
#
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

    PVB_COUNT=$(kubectl get podvolumebackups.velero.io -n velero \
      -l velero.io/backup-name={{backup}} \
      -o jsonpath='{.items[*].metadata.name}' | wc -w | tr -d ' ')
    if [ "$PVB_COUNT" -gt 0 ]; then
      echo "ERROR: Backup '{{backup}}' contains file-system backups."
      echo "  restore-pvc supports CSI snapshot backups only."
      exit 1
    fi

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
      while true; do
        BOUND=false
        for i in $(seq 1 30); do
          STATUS=$(kubectl get pvc "$PVC_NAME" -n "$NAMESPACE" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
          if [ "$STATUS" = "Bound" ]; then
            echo "    PVC '$PVC_NAME' is Bound!"
            BOUND=true
            break
          fi
          echo "    [$i/30] PVC '$PVC_NAME' status: $STATUS"
          sleep 10
        done

        if [ "$BOUND" = "true" ]; then
          break
        fi

        echo ""
        echo "    PVC '$PVC_NAME' has not bound after 5 minutes."
        read -rp "    Continue waiting? [Y/n] " REPLY
        if [[ "$REPLY" =~ ^[Nn]$ ]]; then
          echo ""
          echo "WARNING: ArgoCD reconciliation is still paused for '{{app}}'."
          echo "  Resume manually when ready: just argocd resume {{app}}"
          exit 1
        fi
        echo "    Waiting another 5 minutes..."
      done
    done

    echo "==> Scaling up '{{app}}'..."
    kubectl scale deployment {{app}} -n "$NAMESPACE" --replicas=1
    kubectl rollout status deployment {{app}} -n "$NAMESPACE" --timeout=120s

    echo "==> Resuming ArgoCD reconciliation for '{{app}}'..."
    just argocd resume {{app}}

    echo "==> Done! Verify the application is working correctly."

[doc('Create, back up, and restore an on-demand synthetic FSB canary')]
test-fsb: (_require "velero" "kubectl" "jq")
    #!/usr/bin/env bash
    set -euo pipefail

    SOURCE_NAMESPACE="velero-restore-canary-source"
    TIMESTAMP=$(date +%s)
    BACKUP_NAME="velero-restore-canary-$TIMESTAMP"
    RESTORE_NAME="restore-canary-$TIMESTAMP"
    RESTORE_NAMESPACE="velero-restore-canary-target-$TIMESTAMP"

    if kubectl get namespace "$SOURCE_NAMESPACE" > /dev/null 2>&1; then
      echo "ERROR: Namespace '$SOURCE_NAMESPACE' already exists."
      echo "  Clean up the previous canary before running another test."
      exit 1
    fi

    kubectl apply -f kubernetes/infra/velero/restore-canary.yaml
    kubectl wait pod/velero-restore-canary \
      -n "$SOURCE_NAMESPACE" \
      --for=condition=Ready \
      --timeout=5m

    EXPECTED_SHA=$(kubectl exec -n "$SOURCE_NAMESPACE" velero-restore-canary -- \
      sha256sum /data/sentinel.txt | awk '{print $1}')

    velero backup create "$BACKUP_NAME" \
      --from-schedule velero-weekly-offsite \
      --wait

    CANARY_PVB_COUNT=$(kubectl get podvolumebackups.velero.io -n velero \
      -l velero.io/backup-name="$BACKUP_NAME" -o json \
      | jq '[.items[]
          | select(.spec.pod.namespace == "velero-restore-canary-source")
          | select(.spec.pod.name == "velero-restore-canary")
          | select(.spec.volume == "data")
          | select(.status.phase == "Completed")]
          | length')
    if [ "$CANARY_PVB_COUNT" -ne 1 ]; then
      echo "ERROR: Backup '$BACKUP_NAME' does not contain one completed canary FSB."
      exit 1
    fi

    kubectl create namespace "$RESTORE_NAMESPACE"
    velero restore create "$RESTORE_NAME" \
      --from-backup "$BACKUP_NAME" \
      --namespace-mappings "$SOURCE_NAMESPACE:$RESTORE_NAMESPACE" \
      --selector app.kubernetes.io/name=velero-restore-canary \
      --include-resources persistentvolumeclaims,persistentvolumes,pods \
      --existing-resource-policy none \
      --wait

    kubectl wait pod \
      -n "$RESTORE_NAMESPACE" \
      -l app.kubernetes.io/name=velero-restore-canary \
      --for=condition=Ready \
      --timeout=10m
    ACTUAL_SHA=$(kubectl exec -n "$RESTORE_NAMESPACE" velero-restore-canary -- \
      sha256sum /data/sentinel.txt | awk '{print $1}')

    if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
      echo "ERROR: Restored canary checksum does not match the source."
      exit 1
    fi

    echo "Canary restore verified from backup '$BACKUP_NAME'."
    echo "Cleanup requires explicit approval:"
    echo "  kubectl delete namespace $SOURCE_NAMESPACE $RESTORE_NAMESPACE"
