#!/bin/bash
set -e

S3_ARGS="--bucket=${KOPIA_S3_BUCKET} --endpoint=${KOPIA_S3_ENDPOINT} --access-key=${AWS_ACCESS_KEY_ID} --secret-access-key=${AWS_SECRET_ACCESS_KEY}"
CONN_ARGS="--override-hostname=kopia-nas-backup --override-username=cronjob"

connect_or_create() {
  if kopia repository connect s3 ${S3_ARGS} ${CONN_ARGS} 2>/dev/null; then
    return
  fi

  echo "Repository not found, initializing..."
  kopia repository create s3 ${S3_ARGS} ${CONN_ARGS} \
    --retention-mode COMPLIANCE \
    --retention-period 30d

  kopia policy set --global \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --keep-annual 2 \
    --compression=zstd

  kopia maintenance set --extend-object-locks true
}

ping_healthcheck() {
  if [ -n "${HEALTHCHECK_URL}" ]; then
    curl -fsS -m 10 --retry 5 "${HEALTHCHECK_URL}" > /dev/null 2>&1 || true
  fi
}

echo "==> Connecting to B2 repository..."
connect_or_create

# Autodiscover: snapshot each mounted directory under /data
for dir in /data/*/; do
  [ -d "$dir" ] || continue
  name=$(basename "$dir")
  echo "==> Backing up ${name}..."
  kopia snapshot create "$dir" --tags="source:nas,dataset:${name}" \
    --progress-update-interval 1m 2>&1 | stdbuf -oL -eL tr '\r' '\n'
done

echo "==> Running maintenance..."
kopia maintenance run --full

echo "==> Backup completed successfully"
ping_healthcheck
