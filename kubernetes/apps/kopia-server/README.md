# Kopia Repository Server

Persistent [Kopia](https://kopia.io/) repository server for receiving
backups from laptops and devices. Data is stored on the NAS via NFS
(`nibbler/apps/kopia-backups`). A nightly CronJob mirrors the repository
to Backblaze B2 (`kopia-server-offsite`) using `kopia repository sync-to`.

## Access

- **Web UI + CLI**: `https://kopia.lan.peterson.com.ar` (LoadBalancer with cert-manager TLS)
- Kopia clients connect with GRPC over the same HTTPS endpoint

## Schedule

- **Offsite sync**: daily at 01:00 UTC to `kopia-server-offsite` B2 bucket

## Setup

### Create NFS dataset on the NAS

```bash
sudo zfs create nibbler/apps/kopia-backups
sudo zfs set sharenfs="rw=@10.3.0.34:@10.3.0.35:@10.3.0.36,no_root_squash,no_subtree_check" \
  nibbler/apps/kopia-backups
```

### Create B2 bucket and key

```bash
# Create bucket with File Lock and lifecycle rule (cannot be enabled after creation)
# Lifecycle: auto-delete hidden file versions after 30 days
# See https://kopia.io/docs/advanced/ransomware-protection/
b2 bucket create kopia-server-offsite allPrivate --file-lock-enabled \
  --lifecycle-rules '[{"daysFromHidingToDeleting":30,"fileNamePrefix":""}]'

# Create scoped key (no deleteFiles)
b2 key create --bucket kopia-server-offsite kopia-server-backup \
  listBuckets,readBuckets,listFiles,readFiles,writeFiles,readBucketEncryption,readBucketReplications,readBucketRetentions,readFileRetentions,writeFileRetentions,readFileLegalHolds
```

### Encrypt the secret

Fill in `secret.sops.yaml` with:

- `KOPIA_REPOSITORY_PASSWORD` — password for the filesystem repository on NAS
- `KOPIA_SERVER_USERNAME` — admin username for the web UI / server control
- `KOPIA_SERVER_PASSWORD` — admin password for the web UI / server control
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — B2 app key for offsite sync
- `KOPIA_OFFSITE_PASSWORD` — password for the B2 offsite repository (can differ from local)
- `HEALTHCHECK_URL` — optional healthcheck ping URL for the sync job

```bash
sops -e -i secret.sops.yaml
```

## Connecting a laptop

```bash
kopia repository connect server \
  --url=https://kopia.lan.peterson.com.ar \
  --override-hostname=<laptop-name> \
  --override-username=<user>
```

The server admin must first add the user via the web UI or CLI:

```bash
kubectl exec -n backup deploy/kopia-server -- \
  kopia server user add <user>@<hostname> --user-password=<password>
```

## Architecture

```text
Laptop ──HTTPS──▶ Kopia Server ──NFS──▶ NAS (nibbler/apps/kopia-backups)
                                              │
                  offsite-sync CronJob ◀──────┘
                        │
                        ▼
                   Backblaze B2 (kopia-server-offsite)
```

## Restoring from offsite

```bash
kopia repository connect s3 \
  --bucket=kopia-server-offsite \
  --endpoint=<s3-endpoint> \
  --access-key=<key-id> \
  --secret-access-key=<key>

kopia snapshot list
kopia restore <snapshot-id> /restore/target/
```
