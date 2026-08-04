# Velero offsite backups

Velero stores Kubernetes metadata and weekly file-system backups in the externally
managed Backblaze B2 bucket `backup-talos-proxmox-cluster` through the
`https://s3.us-west-001.backblazeb2.com` endpoint.

## Backup scope

The weekly schedule uses Velero file-system backup in opt-in mode. Workload pod
templates must explicitly list approved PVC volume names in the
`backup.velero.io/backup-volumes` annotation.

The daily schedule references a separate policy that forces annotated CSI volumes
through snapshots instead of FSB. This preserves daily local snapshots while the same
pod annotations opt volumes into weekly offsite FSB.

The `velero-weekly-volume-policies` resource policy provides defense in depth:

- all NFS volumes are skipped;
- `emptyDir` volumes are skipped;
- individual volumes of 100 GiB or larger are skipped.

NAS media and existing backup repositories are protected by their dedicated backup
processes and must not be included in Velero.

CronJob-only PVCs are not included in weekly FSB because completed Pods do not keep
their volumes mounted. Their declarative configuration remains in Git and daily local
CSI snapshots still protect their PVCs.

FSB reads mounted files from running Pods and is not an application-consistent
snapshot. Workloads with live databases must retain their application-native backup
files inside the approved config volume, and restores must include the application's
integrity checks. Daily CSI snapshots remain the primary crash-consistent local
recovery point.

## Backblaze lifecycle

The bucket configuration is not reconciled by ArgoCD. It must use the following
lifecycle rule so S3-deleted objects do not remain as billable hidden versions:

```json
{
  "daysFromHidingToDeleting": 1,
  "daysFromUploadingToHiding": null,
  "fileNamePrefix": ""
}
```

Verify the external settings:

```sh
b2 bucket get backup-talos-proxmox-cluster \
  | jq '{lifecycleRules,isFileLockEnabled,defaultRetention,replication}'
```

Expected settings:

- hidden versions are deleted after one day;
- File Lock and default retention are disabled;
- replication is disabled.

Lifecycle processing runs daily, so physical storage can remain billable for up to
one additional day after Kopia deletes an object.

## Backblaze caps and alerts

Backblaze caps apply to the entire account, including non-Velero buckets. Configure
them in **B2 Cloud Storage > Caps & Alerts** only after measuring the corrected
account-wide baseline.

Recommended starting values when the other buckets remain below these thresholds:

| Category | Warning | Hard cap |
| --- | ---: | ---: |
| Storage | USD 0.10/day | USD 0.25/day |
| Downloads | USD 0.25/day | USD 1.00/day |
| Class A/B/C transactions | USD 0.10/day | USD 0.50/day |

Backblaze sends notifications at 75% and 100% of a cap. Reaching a cap can fail every
backup that uses the account, so verify notification recipients and update this table
when configured values change.
