set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

talos_dir := source_directory()
inventory := env("ANSIBLE_INVENTORY", talos_dir / "../../homelab-private/ansible/inventories")

export SOPS_AGE_KEY_FILE := env("SOPS_AGE_KEY_FILE", env("HOME") / ".config/sops/age/keys.txt")

[private]
default:
    @just --unstable --list talos

[doc('Check TOPF/Talos compatibility and the existing encrypted secrets bundle')]
check:
    mise exec -- python3 "{{ talos_dir }}/manage.py" check

[doc('Check the configured version contract without decrypting secrets')]
versions:
    mise exec -- python3 "{{ talos_dir }}/manage.py" versions

[doc('Generate and strictly validate all TOPF node configs locally')]
genconfig:
    mise exec -- python3 "{{ talos_dir }}/manage.py" genconfig

[doc('Strictly validate a fresh complete TOPF generation')]
validate:
    mise exec -- python3 "{{ talos_dir }}/manage.py" validate

[doc('Run an exact-payload server-side dry-run with a secret-safe document summary')]
[positional-arguments]
diff node:
    mise exec -- python3 "{{ talos_dir }}/manage.py" diff "$1"

[doc('Apply one exact node with confirmation, no reboot, and readiness gates')]
[positional-arguments]
apply node:
    mise exec -- python3 "{{ talos_dir }}/manage.py" apply "$1"

[doc('Generate client credentials from existing secrets without rendering machine configs')]
credentials:
    mise exec -- python3 "{{ talos_dir }}/manage.py" credentials

[private]
[positional-arguments]
_node-address node:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ talos_dir }}"
    NODE="$1" mise exec -- yq -er \
      '[.nodes[] | select(.host == strenv(NODE))] | select(length == 1) | .[0].ip' topf.yaml

[doc('Reset one node and wipe STATE + EPHEMERAL (mode: reboot or no-reboot)')]
[positional-arguments]
reset-node node mode="reboot":
    #!/usr/bin/env bash
    set -euo pipefail
    ip=$(just talos _node-address "$1")
    config="${TALOSCONFIG:-{{ talos_dir }}/clusterconfig/talosconfig}"
    [[ -s "$config" ]] || { echo "Missing client credentials; run just talos credentials" >&2; exit 1; }
    flags=(--system-labels-to-wipe STATE --system-labels-to-wipe EPHEMERAL --graceful=false)
    case "$2" in
      reboot) flags+=(--reboot) ;;
      no-reboot) ;;
      *) echo "Mode must be reboot or no-reboot" >&2; exit 1 ;;
    esac
    read -r -p "Reset $1 ($ip) and wipe STATE + EPHEMERAL? Type the hostname: " confirm
    [[ "$confirm" == "$1" ]] || { echo "Reset not confirmed" >&2; exit 1; }
    mise exec -- talosctl --talosconfig "$config" -e "$ip" -n "$ip" reset "${flags[@]}"

[doc('Power-cycle one node (hostname confirmation required)')]
[positional-arguments]
reboot-node node:
    #!/usr/bin/env bash
    set -euo pipefail
    ip=$(just talos _node-address "$1")
    config="${TALOSCONFIG:-{{ talos_dir }}/clusterconfig/talosconfig}"
    [[ -s "$config" ]] || { echo "Missing client credentials; run just talos credentials" >&2; exit 1; }
    read -r -p "Power-cycle $1 ($ip)? Type the hostname: " confirm
    [[ "$confirm" == "$1" ]] || { echo "Reboot not confirmed" >&2; exit 1; }
    mise exec -- talosctl --talosconfig "$config" -e "$ip" -n "$ip" reboot -m powercycle

[private]
[positional-arguments]
_iso node:
    #!/usr/bin/env bash
    set -euo pipefail
    just talos _node-address "$1" >/dev/null
    image=$(mise exec -- yq -er 'select(.kind == "UnattendedInstallConfig") | .installer.image' "{{ talos_dir }}/clusterconfig/$1.yaml")
    if [[ ! "$image" =~ ^factory\.talos\.dev/metal-installer/([a-f0-9]{64}):(v[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
      echo "Unexpected installer reference" >&2
      exit 1
    fi
    schematic="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[2]}"
    printf '%s\t%s\n' "talos-${version}-${schematic:0:8}.iso" \
      "https://factory.talos.dev/image/$schematic/$version/metal-amd64.iso"

[doc('Download the existing factory ISOs for all unique rendered schematics')]
download-iso: genconfig
    #!/usr/bin/env bash
    set -euo pipefail
    nodes=$(mise exec -- yq -r '.nodes[].host' "{{ talos_dir }}/topf.yaml")
    isos=$(for node in $nodes; do just talos _iso "$node"; done | sort -u)
    while IFS=$'\t' read -r file url; do
      mise exec -- curl -fL --retry 5 --retry-delay 5 --retry-all-errors -o "{{ talos_dir }}/$file" "$url"
    done <<< "$isos"

[private]
[positional-arguments]
_reprovision node dry_run:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "$2" == true || "$2" == false ]] || { echo "dry_run must be true or false" >&2; exit 1; }
    iso=$(just talos _iso "$1")
    IFS=$'\t' read -r file url <<< "$iso"
    [[ -e "{{ inventory }}" ]] || { echo "Missing Ansible inventory; set ANSIBLE_INVENTORY" >&2; exit 1; }
    printf '%s: %s (dry_run=%s)\n' "$1" "$url" "$2"
    if [[ "$2" == false ]]; then
      read -r -p "Recreate $1's VM disk? Type the hostname: " confirm
      [[ "$confirm" == "$1" ]] || { echo "Reprovisioning not confirmed" >&2; exit 1; }
    fi
    targets=$(mise exec -- jq -cn --arg node "$1" '{target_vms: [$node]}')
    cd "{{ talos_dir }}/../ansible"
    mise exec -- ansible-playbook playbooks/utilities/reprovision-talos-vm.yaml -i "{{ inventory }}" \
      -e "$targets" -e "iso_file=$file" -e "iso_url=$url" -e "dry_run=$2"

[doc('Reprovision one VM using its rendered schematic (destructive unless dry_run=true)')]
[positional-arguments]
reprovision-node node dry_run="false": genconfig
    just talos _reprovision "$1" "$2"

[doc('Reprovision ALL inventory VMs with upfront and per-node destructive confirmation')]
[positional-arguments]
reprovision-cluster dry_run="false": genconfig
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "$1" == true || "$1" == false ]] || { echo "dry_run must be true or false" >&2; exit 1; }
    nodes=$(mise exec -- yq -r '.nodes[].host' "{{ talos_dir }}/topf.yaml")
    printf 'Nodes to reprovision (ALL VM disks will be recreated):\n%s\n' "$nodes"
    if [[ "$1" == false ]]; then
      read -r -p "Reprovision ALL nodes above? Type reprovision-all: " confirm
      [[ "$confirm" == reprovision-all ]] || { echo "Reprovisioning not confirmed" >&2; exit 1; }
    fi
    for node in $nodes; do just talos _reprovision "$node" "$1"; done

[doc('Run secret-free TOPF workflow regression tests')]
test:
    mise exec -- python3 -m unittest discover -s "{{ talos_dir }}/tests" -v
