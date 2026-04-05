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
# Create bucket with Object Lock (cannot be enabled after creation)
b2 bucket create <bucket-name> allPrivate --object-lock

# Create scoped key (no deleteFiles capability)
b2 key create --bucket <bucket-name> <key-name> \
  listBuckets,listFiles,readFiles,writeFiles
```

### Export NFS shares on NAS

```bash
# Read-only exports to worker node IPs
sudo zfs set sharenfs="ro=@<worker1-ip>:@<worker2-ip>:@<worker3-ip>,no_root_squash,no_subtree_check" \
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
2. Add an NFS volume and mount to `values.yaml`
3. Add a `kopia snapshot create` line to the CronJob script in `values.yaml`

## Monitoring

- Healthcheck ping on success (via healthchecks instance)
- CronJob success/failure visible in ArgoCD and `kubectl get jobs -n backup`
- Kopia repository stats: `kopia repository status` and `kopia snapshot list`

## Restoring data

From any machine with Kopia and the repository password:

```bash
kopia repository connect b2 \
  --bucket=<bucket-name> \
  --key-id=<key-id> \
  --key=<key>

# List snapshots
kopia snapshot list

# Restore a snapshot
kopia restore <snapshot-id> /restore/target/
```
