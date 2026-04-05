# Kopia NAS Backup

Daily offsite backup of NAS ZFS datasets to Backblaze B2 using
[Kopia](https://kopia.io/). NFS shares are mounted **read-only**.

## Schedule and retention

- **Daily at 2:00 AM UTC**
- Retention: 7 daily, 4 weekly, 6 monthly, 2 yearly snapshots
- Auto-initializes the Kopia repository on first run

## Setup

### Prerequisites

```bash
pip install b2
# or: brew install b2-tools
```

### Create bucket and key

```bash
# Create bucket with File Lock (cannot be enabled after creation)
b2 bucket create kopia-nas-offsite allPrivate --file-lock-enabled

# Create scoped key with Object Lock permissions (no deleteFiles)
b2 key create --bucket kopia-nas-offsite kopia-nas-backup \
  listBuckets,readBuckets,listFiles,readFiles,writeFiles,readBucketEncryption,readBucketReplications,readBucketRetentions,readFileRetentions,writeFileRetentions,readFileLegalHolds
```

### Export NFS shares on NAS

```bash
# Read-only exports to worker node IPs
sudo zfs set sharenfs="ro=@10.3.0.34:@10.3.0.35:@10.3.0.36,no_root_squash,no_subtree_check" \
  <pool>/<dataset>

# Verify
sudo exportfs -v
```

### Encrypt the secret

Fill in `secret.sops.yaml` with B2 credentials, Kopia repository
password, and healthcheck URL, then encrypt:

```bash
sops -e -i secret.sops.yaml
```

## Adding more datasets

1. Export the new dataset as a read-only NFS share on the NAS
2. Add an NFS volume in `values.yaml` mounted under `/data/<name>`

The backup script autodiscovers all directories under `/data/` and
snapshots each one — no script changes needed.

## Monitoring

- Healthcheck ping on success (via healthchecks instance)
- CronJob success/failure visible in ArgoCD and `kubectl get jobs -n backup`
- Kopia repository stats: `kopia repository status` and `kopia snapshot list`

## Restoring data

From any machine with Kopia and the repository password:

```bash
kopia repository connect s3 \
  --bucket=kopia-nas-offsite \
  --endpoint=s3.us-west-004.backblazeb2.com \
  --access-key=<key-id> \
  --secret-access-key=<key>

# List snapshots
kopia snapshot list

# Restore a snapshot
kopia restore <snapshot-id> /restore/target/
```
