#!/bin/bash
set -e

export KOPIA_PASSWORD="${KOPIA_REPOSITORY_PASSWORD}"

kopia repository connect filesystem --path /repo \
  --override-hostname=kopia-server --override-username=server

exec kopia server start \
  --address=0.0.0.0:51515 \
  --insecure \
  --without-password \
  --server-control-username="${KOPIA_SERVER_USERNAME}" \
  --server-control-password="${KOPIA_SERVER_PASSWORD}"
