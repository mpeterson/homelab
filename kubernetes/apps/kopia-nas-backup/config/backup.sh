#!/bin/sh
set -e

connect_or_create() {
  if kopia repository connect b2 \
    --bucket="${KOPIA_B2_BUCKET}" \
    --key-id="${B2_KEY_ID}" \
    --key="${B2_KEY}" \
    --password="${KOPIA_REPOSITORY_PASSWORD}" \
    --override-hostname=kopia-nas-backup \
    --override-username=cronjob 2>/dev/null; then
    return
  fi

  echo "Repository not found, initializing..."
  kopia repository create b2 \
    --bucket="${KOPIA_B2_BUCKET}" \
    --key-id="${B2_KEY_ID}" \
    --key="${B2_KEY}" \
    --password="${KOPIA_REPOSITORY_PASSWORD}" \
    --override-hostname=kopia-nas-backup \
    --override-username=cronjob

  kopia policy set --global \
    --keep-daily 7 \
    --keep-weekly 4 \
    --keep-monthly 6 \
    --keep-annual 2
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
  kopia snapshot create "$dir" --tags="source:nas,dataset:${name}"
done

echo "==> Running maintenance..."
kopia maintenance run --full

echo "==> Backup completed successfully"
ping_healthcheck
