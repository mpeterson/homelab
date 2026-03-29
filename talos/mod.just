set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

talos_dir := source_directory()

export SOPS_AGE_KEY_FILE := env("SOPS_AGE_KEY_FILE", env("HOME") / ".config/sops/age/keys.txt")

[private]
default:
    @just --unstable --list talos

[doc('Generate Talos configs from talconfig.yaml')]
genconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    mise install --quiet
    cd "{{ talos_dir }}"
    mise x -- talhelper genconfig

[doc('Diff generated config against running node config')]
diff node: genconfig
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ talos_dir }}"

    ip=$(mise x -- yq '.nodes[] | select(.hostname == "{{ node }}") | .ipAddress' talconfig.yaml)
    if [ -z "$ip" ]; then
      echo "Error: node '{{ node }}' not found in talconfig.yaml" >&2
      exit 1
    fi

    ep=$(mise x -- yq '.nodes[] | select(.controlPlane == true) | .ipAddress' talconfig.yaml | head -1)
    config_file="clusterconfig/talos-proxmox-cluster-{{ node }}.yaml"

    echo "Diffing generated config against running config on {{ node }} ($ip)..."
    mise x -- talosctl --talosconfig clusterconfig/talosconfig \
      -e "$ep" -n "$ip" \
      apply-config --file "$config_file" --dry-run 2>&1 \
      | sed -e 's/^-.*$/\x1b[31m&\x1b[0m/' -e 's/^+.*$/\x1b[32m&\x1b[0m/' -e 's/^@@.*$/\x1b[36m&\x1b[0m/' \
      || true

[doc('Apply generated config to a node')]
apply node *flags: genconfig
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ talos_dir }}"

    ip=$(mise x -- yq '.nodes[] | select(.hostname == "{{ node }}") | .ipAddress' talconfig.yaml)
    if [ -z "$ip" ]; then
      echo "Error: node '{{ node }}' not found in talconfig.yaml" >&2
      exit 1
    fi

    ep=$(mise x -- yq '.nodes[] | select(.controlPlane == true) | .ipAddress' talconfig.yaml | head -1)
    config_file="clusterconfig/talos-proxmox-cluster-{{ node }}.yaml"

    echo "Applying config to {{ node }} ($ip)..."
    mise x -- talosctl --talosconfig clusterconfig/talosconfig \
      -e "$ep" -n "$ip" \
      apply-config --file "$config_file" {{ flags }}

[doc('Validate all generated Talos configs')]
validate: genconfig
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ talos_dir }}"

    status=0
    for f in clusterconfig/talos-proxmox-cluster-*.yaml; do
      name=$(basename "$f" .yaml | sed 's/talos-proxmox-cluster-//')
      if mise x -- talosctl validate -m metal -c "$f" 2>&1; then
        printf "  \033[32m✓\033[0m %s\n" "$name"
      else
        printf "  \033[31m✗\033[0m %s\n" "$name"
        status=1
      fi
    done
    exit "$status"
