#!/bin/bash
set -e

export KOPIA_PASSWORD="${KOPIA_REPOSITORY_PASSWORD}"

kopia repository connect filesystem --path /repo \
  --override-hostname=kopia-server --override-username=server

S3_ARGS="--bucket=${KOPIA_S3_BUCKET} --endpoint=${KOPIA_S3_ENDPOINT} --access-key=${AWS_ACCESS_KEY_ID} --secret-access-key=${AWS_SECRET_ACCESS_KEY}"

echo "==> Syncing repository to B2..."
kopia repository sync-to s3 ${S3_ARGS} \
  --password="${KOPIA_OFFSITE_PASSWORD}" \
  --must-exist=false \
  --parallel 4 \
  --progress-update-interval 1m 2>&1 | stdbuf -oL -eL tr '\r' '\n'

echo "==> Sync completed successfully"

if [ -n "${HEALTHCHECK_URL}" ]; then
  curl -fsS -m 10 --retry 5 "${HEALTHCHECK_URL}" > /dev/null 2>&1 || true
fi
