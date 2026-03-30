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



[doc('Reset a node (wipe STATE + EPHEMERAL)')]
reset-node node mode="reboot":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ talos_dir }}"

    ip=$(mise x -- yq '.nodes[] | select(.hostname == "{{ node }}") | .ipAddress' talconfig.yaml)
    if [ -z "$ip" ]; then
      echo "Error: node '{{ node }}' not found in talconfig.yaml" >&2
      exit 1
    fi

    ep=$(mise x -- yq '.nodes[] | select(.controlPlane == true) | .ipAddress' talconfig.yaml | head -1)

    read -r -p "Reset node {{ node }} ($ip)? This will wipe STATE and EPHEMERAL. [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi

    reboot_flag=""
    if [ "{{ mode }}" = "reboot" ]; then
      reboot_flag="--reboot"
    fi

    mise x -- talosctl --talosconfig clusterconfig/talosconfig \
      -e "$ep" -n "$ip" \
      reset --system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL \
      --graceful=false $reboot_flag

[doc('Reboot a node')]
reboot-node node:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ talos_dir }}"

    ip=$(mise x -- yq '.nodes[] | select(.hostname == "{{ node }}") | .ipAddress' talconfig.yaml)
    if [ -z "$ip" ]; then
      echo "Error: node '{{ node }}' not found in talconfig.yaml" >&2
      exit 1
    fi

    ep=$(mise x -- yq '.nodes[] | select(.controlPlane == true) | .ipAddress' talconfig.yaml | head -1)

    read -r -p "Reboot node {{ node }} ($ip)? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi

    mise x -- talosctl --talosconfig clusterconfig/talosconfig \
      -e "$ep" -n "$ip" \
      reboot -m powercycle

[doc('Download factory ISOs for all unique schematics in talconfig.yaml')]
download-iso:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ talos_dir }}"

    version=$(mise x -- yq '.talosVersion' talconfig.yaml)

    # Collect unique schematics: controlPlane, worker, and per-node overrides
    declare -A schematics

    cp_schematic=$(mise x -- yq '.controlPlane.schematic' talconfig.yaml -o json 2>/dev/null || echo "null")
    if [ "$cp_schematic" != "null" ]; then
      schematics["controlPlane"]="$cp_schematic"
    fi

    worker_schematic=$(mise x -- yq '.worker.schematic' talconfig.yaml -o json 2>/dev/null || echo "null")
    if [ "$worker_schematic" != "null" ]; then
      schematics["worker"]="$worker_schematic"
    fi

    for node in $(mise x -- yq '.nodes[].hostname' talconfig.yaml); do
      node_schematic=$(mise x -- yq ".nodes[] | select(.hostname == \"$node\") | .schematic" talconfig.yaml -o json 2>/dev/null || echo "null")
      if [ "$node_schematic" != "null" ] && [ "$node_schematic" != "{}" ]; then
        schematics["$node"]="$node_schematic"
      fi
    done

    if [ ${#schematics[@]} -eq 0 ]; then
      echo "No schematics found in talconfig.yaml"
      exit 1
    fi

    # Deduplicate by schematic ID and download ISOs
    declare -A seen_ids
    for label in "${!schematics[@]}"; do
      schematic_json="${schematics[$label]}"
      schematic_yaml=$(echo "$schematic_json" | mise x -- yq -P)

      schematic_id=$(echo "$schematic_yaml" | curl -sX POST --data-binary @- "https://factory.talos.dev/schematics" | mise x -- yq '.id')
      if [ -z "$schematic_id" ] || [ "$schematic_id" = "null" ]; then
        echo "Error: failed to get schematic ID for $label" >&2
        continue
      fi

      if [ -n "${seen_ids[$schematic_id]+x}" ]; then
        echo "Skipping $label (same schematic as ${seen_ids[$schematic_id]})"
        continue
      fi
      seen_ids["$schematic_id"]="$label"

      short_id="${schematic_id:0:8}"
      iso_file="talos-${version}-${short_id}.iso"

      echo "Downloading ISO for $label (schematic: ${short_id}...)..."
      curl -sfL --retry 5 --retry-delay 5 --retry-all-errors \
        -o "$iso_file" \
        "https://factory.talos.dev/image/${schematic_id}/${version}/metal-amd64.iso"
      printf "  \033[32m✓\033[0m %s\n" "$iso_file"
    done

[doc('Reprovision a Talos VM via ansible (resolves correct ISO from schematic)')]
reprovision-node node dry_run="false": genconfig
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ talos_dir }}"

    version=$(mise x -- yq '.talosVersion' talconfig.yaml)
    is_cp=$(mise x -- yq ".nodes[] | select(.hostname == \"{{ node }}\") | .controlPlane" talconfig.yaml)
    if [ -z "$is_cp" ]; then
      echo "Error: node '{{ node }}' not found in talconfig.yaml" >&2
      exit 1
    fi

    # Resolve schematic: per-node override > group default
    node_schematic=$(mise x -- yq ".nodes[] | select(.hostname == \"{{ node }}\") | .schematic" talconfig.yaml -o json 2>/dev/null)
    if [ "$node_schematic" != "null" ] && [ -n "$node_schematic" ]; then
      schematic_yaml=$(echo "$node_schematic" | mise x -- yq -P)
    elif [ "$is_cp" = "true" ]; then
      schematic_yaml=$(mise x -- yq '.controlPlane.schematic' talconfig.yaml -o json | mise x -- yq -P)
    else
      schematic_yaml=$(mise x -- yq '.worker.schematic' talconfig.yaml -o json | mise x -- yq -P)
    fi

    schematic_id=$(echo "$schematic_yaml" | curl -sX POST --data-binary @- "https://factory.talos.dev/schematics" | mise x -- yq '.id')
    short_id="${schematic_id:0:8}"
    iso_file="talos-${version}-${short_id}.iso"
    iso_url="https://factory.talos.dev/image/${schematic_id}/${version}/metal-amd64.iso"

    echo "Node: {{ node }} ($([ "$is_cp" = "true" ] && echo "controlplane" || echo "worker"))"
    echo "ISO:  $iso_file (schematic: ${short_id}...)"
    echo ""

    if [ "{{ dry_run }}" != "true" ]; then
      read -r -p "Reprovision {{ node }}? This will wipe and recreate the VM disk. [y/N] " confirm
      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
      fi
    fi

    cd "{{ talos_dir }}/../ansible"
    mise x -- ansible-playbook playbooks/utilities/reprovision-talos-vm.yaml \
      -e '{"target_vms":["{{ node }}"]}' -e "iso_file=$iso_file" -e "iso_url=$iso_url" -e "dry_run={{ dry_run }}"

[doc('Reprovision ALL Talos VMs (discovers nodes from talconfig.yaml)')]
reprovision-cluster dry_run="false":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ talos_dir }}"

    nodes=$(mise x -- yq '.nodes[].hostname' talconfig.yaml)
    echo "Nodes to reprovision:"
    echo "$nodes" | sed 's/^/  - /'
    echo ""

    if [ "{{ dry_run }}" != "true" ]; then
      read -r -p "Reprovision ALL nodes listed above? This is destructive! [y/N] " confirm
      if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted."
        exit 0
      fi
    fi

    for node in $nodes; do
      echo ""
      echo "========================================="
      echo "Reprovisioning $node..."
      echo "========================================="
      just talos reprovision-node "$node" "{{ dry_run }}"
    done
