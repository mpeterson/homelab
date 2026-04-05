#!/bin/bash
set -eo pipefail

kopia repository connect filesystem --path /repo \
  --password="${KOPIA_PASSWORD}" \
  --override-hostname=kopia-server --override-username=server

S3_ARGS="--bucket=${KOPIA_S3_BUCKET} --endpoint=${KOPIA_S3_ENDPOINT} --access-key=${AWS_ACCESS_KEY_ID} --secret-access-key=${AWS_SECRET_ACCESS_KEY}"

echo "==> Syncing repository to S3..."
kopia repository sync-to s3 ${S3_ARGS} \
  --password="${KOPIA_OFFSITE_PASSWORD}" \
  --no-must-exist \
  --parallel 4 \
  --progress-update-interval 1m 2>&1 | tr '\r' '\n'

echo "==> Sync completed successfully"

if [ -n "${HEALTHCHECK_URL}" ]; then
  curl -fsS -m 10 --retry 5 "${HEALTHCHECK_URL}" > /dev/null 2>&1 || true
fi
