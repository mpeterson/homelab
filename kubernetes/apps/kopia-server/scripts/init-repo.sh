#!/bin/bash
set -eo pipefail

if kopia repository connect filesystem --path /repo \
  --override-hostname=kopia-server --override-username=server 2>/dev/null; then
  echo "==> Repository already initialized"
  exit 0
fi

echo "==> Initializing repository..."
kopia repository create filesystem --path /repo \
  --override-hostname=kopia-server --override-username=server

kopia policy set --global \
  --keep-daily 7 \
  --keep-weekly 4 \
  --keep-monthly 6 \
  --keep-annual 2 \
  --compression=zstd

echo "==> Repository initialized successfully"
