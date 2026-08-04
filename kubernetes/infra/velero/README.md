# Velero offsite backups

Velero stores Kubernetes metadata and weekly file-system backups in the externally
managed Backblaze B2 bucket `backup-talos-proxmox-cluster` through the
`https://s3.us-west-001.backblazeb2.com` endpoint.

## Backup scope

The weekly schedule uses FSB in opt-out mode so new mounted application PVCs are
protected automatically. A Velero volume policy prevents direct NFS and `emptyDir`
volumes from reaching FSB.

The daily schedule references a separate policy that sends CSI volumes through local
snapshots instead of FSB.

The `velero-weekly-volume-policies` resource policy provides defense in depth:

- all NFS volumes are skipped;
- `emptyDir` volumes are skipped;
- all other eligible mounted volumes are backed up through FSB.

NAS media and existing backup repositories are protected by their dedicated backup
processes and must not be included in Velero.

Known disposable cache volumes use
`backup.velero.io/backup-volumes-excludes` pod annotations. Missing an exclusion can
only back up extra cache data; it cannot omit application data. Provider-side caps and
backup alerts bound unexpected growth.

CronJob-only PVCs are not included in weekly FSB because completed Pods do not keep
their volumes mounted. Their declarative configuration remains in Git and daily local
CSI snapshots still protect their PVCs.

FSB reads mounted files from running Pods and is not an application-consistent
snapshot. Workloads with live databases must retain their application-native backup
files inside the approved config volume, and restores must include the application's
integrity checks. Daily CSI snapshots remain the primary crash-consistent local
recovery point.

## Restore canary

The restore canary is not deployed by ArgoCD. Run it on demand:

```sh
mise exec -- just velero test-fsb
```

The recipe creates a temporary source Pod and PVC, triggers a weekly-style backup,
restores only the canary into a separate namespace, and compares sentinel checksums.
It prints explicit namespace cleanup commands after successful validation.

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
