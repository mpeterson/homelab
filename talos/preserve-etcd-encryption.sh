#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -eq 0 ]; then
  echo "Usage: $0 <machine-config.yaml>..." >&2
  exit 1
fi

tmp=
cleanup_tmp() {
  if [ -n "$tmp" ]; then
    rm -f -- "$tmp"
  fi
}
trap cleanup_tmp EXIT
trap 'cleanup_tmp; exit 1' HUP INT TERM

for config in "$@"; do
  encryption_docs=$(yq eval-all '[select(.kind == "KubeEtcdEncryptionConfig")] | length' "$config")
  if [ "$encryption_docs" = "0" ]; then
    continue
  fi
  if [ "$encryption_docs" != "1" ]; then
    echo "Error: expected one KubeEtcdEncryptionConfig in $config, found $encryption_docs" >&2
    exit 1
  fi

  key_names=$(yq eval-all -o=json -I=0 \
    'select(.kind == "KubeEtcdEncryptionConfig") | [.config.resources[0].providers[] | select(.secretbox != null) | .secretbox.keys[].name]' \
    "$config")
  providers=$(yq eval-all -o=json -I=0 \
    'select(.kind == "KubeEtcdEncryptionConfig") | .config.resources[0].providers | map(keys | .[0])' \
    "$config")

  if [ "$key_names" = '["key2"]' ] && [ "$providers" = '["secretbox","identity"]' ]; then
    continue
  fi

  if [ "$key_names" != '["key1"]' ] || [ "$providers" != '["secretbox"]' ]; then
    echo "Error: unexpected KubeEtcdEncryptionConfig structure in $config" >&2
    exit 1
  fi

  # Temporary Talhelper v3.1.17 compatibility shim; remove during the TOPF migration tracked in #1028.
  tmp=$(mktemp "${config}.tmp.XXXXXX")
  chmod 600 "$tmp"
  yq eval-all \
    'with(select(.kind == "KubeEtcdEncryptionConfig"); .config.resources[0].providers[0].secretbox.keys[0].name = "key2" | .config.resources[0].providers += [{"identity": {}}])' \
    "$config" > "$tmp"
  mv "$tmp" "$config"
  tmp=
done
