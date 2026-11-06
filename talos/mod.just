set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

talos_dir := source_directory()

export SOPS_AGE_KEY_FILE := env("SOPS_AGE_KEY_FILE", env("HOME") / ".config/sops/age/keys.txt")

[private]
default:
    @just --unstable --list talos

[doc('Check TOPF/Talos compatibility and the existing encrypted secrets bundle')]
check:
    #!/usr/bin/env bash
    set -euo pipefail
    just talos versions
    umask 077
    mkdir -p "{{ talos_dir }}/../.local/topf"
    work=$(mktemp -d "{{ talos_dir }}/../.local/topf/check.XXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    just talos _secrets "$work/secrets.yaml"

[doc('Check the configured version contract without decrypting secrets')]
versions:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ talos_dir }}/.."
    target=$(mise exec -- yq -er '.talosVersion' talos/topf.yaml)
    [[ "$target" =~ ^v1\.14\.(0|[1-9][0-9]*)$ ]] || { echo "Expected a reviewed stable Talos 1.14 contract" >&2; exit 1; }
    patch="${BASH_REMATCH[1]}"
    generator=$(mise exec -- topf --version)
    [[ "$generator" =~ ^topf\ version\ [0-9]+\.[0-9]+\.[0-9]+\ \(Talos\ v1\.14\.([0-9]+)\)$ ]] || { echo "Cannot establish released TOPF/Talos support" >&2; exit 1; }
    mise exec -- jq -en --argjson target "$patch" --argjson supported "${BASH_REMATCH[1]}" \
      '$target <= $supported' >/dev/null || { echo "Talos target exceeds TOPF support" >&2; exit 1; }
    client=$(mise exec -- talosctl version --client | sed -nE 's/^[[:space:]]*Tag:[[:space:]]+(v[0-9.]+)[[:space:]]*$/\1/p')
    [[ "$client" == "$target" ]] || { echo "talosctl must match the Talos target" >&2; exit 1; }
    upgrade=$(mise exec -- yq -er 'select(.kind == "TalosUpgrade") | .spec.talos.version' kubernetes/infra/tuppr/upgrades/talos.yaml)
    [[ "$upgrade" == "$target" ]] || { echo "Tuppr must match the TOPF Talos target" >&2; exit 1; }
    TARGET="$target" mise exec -- yq -e \
      '(.nodes | length > 0) and ([.nodes[] | select((.talosVersion // strenv(TARGET)) != strenv(TARGET))] | length == 0)' talos/topf.yaml >/dev/null
    echo "TOPF supports the Talos target; talosctl, every node and Tuppr agree"

[private]
[positional-arguments]
_secrets output:
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    bundle=$(mise exec -- yq -er '.secretsPath // "secrets.yaml"' "{{ talos_dir }}/topf.yaml")
    [[ -s "{{ talos_dir }}/$bundle" ]] || { echo "Existing encrypted secrets bundle is missing" >&2; exit 1; }
    if ! mise exec -- sops --decrypt "{{ talos_dir }}/$bundle" >"$1" 2>"$1.errors"; then
      echo "Cannot decrypt existing secrets; private diagnostics withheld" >&2
      exit 1
    fi
    if ! mise exec -- yq -o=json '.' "$1" >"$1.json" 2>"$1.errors" ||
      ! mise exec -- jq -e \
      '[.cluster.id, .cluster.secret, .secrets.bootstraptoken, .secrets.secretboxencryptionsecret, .trustdinfo.token, .certs.os.crt, .certs.os.key, .certs.etcd.crt, .certs.etcd.key, .certs.k8s.crt, .certs.k8s.key, .certs.k8saggregator.crt, .certs.k8saggregator.key, .certs.k8sserviceaccount.key] | all(type == "string" and length > 0)' "$1.json" >/dev/null 2>"$1.errors"; then
      echo "Existing cluster identity/certificate bundle is incomplete" >&2
      exit 1
    fi

[private]
[positional-arguments]
_validate node secrets:
    #!/usr/bin/env bash
    set -euo pipefail
    payload=$(cat)
    role=$(NODE="$1" mise exec -- yq -er '.nodes[] | select(.host == strenv(NODE)) | .role' "{{ talos_dir }}/topf.yaml")
    gpu=$(NODE="$1" mise exec -- yq -r '.nodes[] | select(.host == strenv(NODE)) | .data.gpu // false' "{{ talos_dir }}/topf.yaml")
    if ! printf '%s\n' "$payload" | mise exec -- yq -o=json -I=0 '.' - 2>"$2.errors" |
      mise exec -- jq -se --arg node "$1" --arg role "$role" --argjson gpu "$gpu" --slurpfile bundle "$2.json" '
      . as $docs | $bundle[0] as $s |
      ($docs | map(select(.version == "v1alpha1")) | .[0]) as $base |
      ($docs | map(select(.kind == "DiscoveryIdentityConfig")) | .[0]) as $identity |
      ($docs | map(select(.kind == "KubeEtcdEncryptionConfig"))) as $encryption |
      ($docs | map(select(.kind == "ExtensionServiceConfig" and .name == "tailscale")) |
        .[0].environment | map(select(startswith("TS_AUTHKEY=")))) as $auth |
      (($docs | map((.kind // "MachineConfig") + "/" + (.name // "")) | unique | length) == ($docs | length)) and
      (($docs | map(select(.kind == "HostnameConfig")) | .[0].hostname) == $node) and
      ($base.machine.ca.crt == $s.certs.os.crt) and
      ((($role == "worker") and ($base.machine.ca.key == "")) or
       (($role == "control-plane") and ($base.machine.ca.key == $s.certs.os.key))) and
      ($base.machine.token == $s.trustdinfo.token) and ($base.cluster.token == $s.secrets.bootstraptoken) and
      ($identity.clusterID == $s.cluster.id) and ($identity.clusterSecret == $s.cluster.secret) and
      (($role != "worker") or (
        ($base.machine | has("sysctls") or (.kernel // {} | has("modules")) | not) and
        ($docs | map(select(.kind == "SysctlConfig")) | length == 1) and
        ($docs | map(select(.kind == "SysctlConfig")) | .[0].params["net.core.bpf_jit_harden"] == "1") and
        (($docs | map(select(.kind == "KernelModuleConfig") | .name) | sort) ==
          (if $gpu then ["nvidia", "nvidia_drm", "nvidia_modeset", "nvidia_uvm"] else [] end))
      )) and
      ($auth | length == 1) and ($auth[0] | test("^TS_AUTHKEY=.+$")) and
      ((($role == "worker") and ($encryption | length == 0)) or
       (($role == "control-plane") and ($encryption | length == 1) and
        ($encryption[0].config.resources == [{"resources": ["secrets"], "providers": [
          {"secretbox": {"keys": [{"name": "key2", "secret": $s.secrets.secretboxencryptionsecret}]}},
          {"identity": {}}]}])))
      ' >/dev/null 2>"$2.errors"; then
      echo "$1: generated identity, worker, Tailscale or encryption invariant failed; values withheld" >&2
      exit 1
    fi
    if ! printf '%s\n' "$payload" | mise exec -- talosctl validate --strict -m metal -c /dev/stdin >"$2.errors" 2>&1; then
      echo "$1: strict Talos validation failed; private diagnostics withheld" >&2
      exit 1
    fi

[private]
[positional-arguments]
_generate work:
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    cd "{{ talos_dir }}/.."
    just talos versions
    nodes=$(mise exec -- yq -r '.nodes[].host' talos/topf.yaml)
    for node in $nodes; do
      [[ "$node" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo "Invalid node hostname" >&2; exit 1; }
    done
    just talos _secrets "$1/secrets.yaml"
    mkdir "$1/render"
    if ! mise exec -- topf --topfconfig talos/topf.yaml --submit-to-factory=false render --output "$1/render" >"$1/log" 2>&1; then
      echo "TOPF rendering failed; private diagnostics withheld" >&2
      exit 1
    fi
    files=("$1/render/"*)
    expected=$(mise exec -- yq '.nodes | length' talos/topf.yaml)
    [[ "${#files[@]}" == "$expected" ]] || { echo "Incomplete or unexpected render output" >&2; exit 1; }
    for node in $nodes; do
      file="$1/render/$node.yaml"
      [[ -f "$file" && ! -L "$file" ]] || { echo "Missing or unsafe node output" >&2; exit 1; }
      chmod 600 "$file"
      just talos _validate "$node" "$1/secrets.yaml" <"$file"
    done
    if ! mise exec -- topf --topfconfig talos/topf.yaml talosconfig >"$1/render/talosconfig" 2>"$1/log"; then
      echo "Client credential generation failed; private diagnostics withheld" >&2
      exit 1
    fi

[doc('Generate and strictly validate all TOPF node configs locally')]
genconfig:
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    mkdir -p "{{ talos_dir }}/../.local/topf"
    work=$(mktemp -d "{{ talos_dir }}/../.local/topf/render.XXXXXX")
    lock=
    trap '[[ -z "$lock" ]] || rmdir "$lock"; rm -rf -- "$work"' EXIT
    just talos _generate "$work"
    mkdir "{{ talos_dir }}/../.local/topf/publish.lock" || { echo "Another generation is publishing output" >&2; exit 1; }
    lock="{{ talos_dir }}/../.local/topf/publish.lock"
    [[ ! -L "{{ talos_dir }}/output" ]] || { echo "Refusing symlink output directory" >&2; exit 1; }
    mkdir -p "{{ talos_dir }}/output"
    chmod 700 "{{ talos_dir }}/output"
    mv "$work/render/"* "{{ talos_dir }}/output/"
    echo "Generated and strictly validated every inventory node"

[doc('Strictly validate a fresh complete TOPF generation')]
validate: genconfig

[doc('Run an exact-payload server-side dry-run with a secret-safe document summary')]
[positional-arguments]
diff node:
    just talos _operation "$1" diff

[doc('Apply one exact node with confirmation, no reboot, and readiness gates')]
[positional-arguments]
apply node:
    just talos _operation "$1" apply

[private]
[positional-arguments]
_operation node mode:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "$2" == diff || "$2" == apply ]] || { echo "Expected diff or apply" >&2; exit 1; }
    ip=$(just talos _node-address "$1")
    umask 077
    mkdir -p "{{ talos_dir }}/../.local/topf"
    work=$(mktemp -d "{{ talos_dir }}/../.local/topf/apply.XXXXXX")
    lock=
    trap '[[ -z "$lock" ]] || rmdir "$lock"; rm -rf -- "$work"' EXIT
    if [[ "$2" == apply ]]; then
      mkdir "{{ talos_dir }}/../.local/topf/apply.lock" || { echo "Another application is active" >&2; exit 1; }
      lock="{{ talos_dir }}/../.local/topf/apply.lock"
    fi
    endpoint=$(mise exec -- yq -er '.clusterEndpoint' "{{ talos_dir }}/topf.yaml")
    just talos _generate "$work"
    payload=$(cat "$work/render/$1.yaml")
    readonly payload
    printf '%s\n' "$payload" | just talos _validate "$1" "$work/secrets.yaml"
    connection=(mise exec -- talosctl --talosconfig "$work/render/talosconfig" -e "$ip" -n "$ip")
    command=("${connection[@]}" apply-config --mode=no-reboot --file /dev/stdin)
    if ! printf '%s\n' "$payload" | "${command[@]}" --dry-run >"$work/preview" 2>&1; then
      echo "$1: server-side dry-run failed; private diagnostics withheld" >&2
      exit 1
    fi
    grep -Eq '^Applied configuration without a reboot \(skipped in dry-run\)\.?[[:space:]]*$' "$work/preview" || { echo "Dry-run did not confirm no-reboot application; values withheld" >&2; exit 1; }
    echo "$1: validated payload accepted by server-side dry-run without a reboot (diff values withheld)"
    [[ "$2" == apply ]] || exit 0
    cps=$(mise exec -- yq -r '[.nodes[] | select(.role == "control-plane") | .ip] | join(",")' "{{ talos_dir }}/topf.yaml")
    workers=$(mise exec -- yq -r '[.nodes[] | select(.role == "worker") | .ip] | join(",")' "{{ talos_dir }}/topf.yaml")
    health=(mise exec -- talosctl --talosconfig "$work/render/talosconfig" -e "$cps" -n "${cps%%,*}" health --server=true --control-plane-nodes "$cps" --worker-nodes "$workers" --k8s-endpoint "$endpoint")
    read -r -p "Apply to $1 ($ip)? Type the exact hostname: " confirm
    [[ "$confirm" == "$1" ]] || { echo "Application not confirmed" >&2; exit 1; }
    "${health[@]}" --wait-timeout=120s
    if ! printf '%s\n' "$payload" | "${command[@]}" >"$work/result" 2>&1; then
      echo "$1: application failed; verify node state before retrying; private diagnostics withheld" >&2
      exit 1
    fi
    deadline=$((SECONDS + 300))
    stable=-1
    while (( SECONDS < deadline )); do
      remaining=$((deadline - SECONDS))
      (( remaining <= 10 )) || remaining=10
      "${health[@]}" --wait-timeout="${remaining}s"
      (( stable >= 0 )) || stable=$SECONDS
      if (( SECONDS - stable >= 30 )); then
        echo "$1: applied the validated payload; native Talos/Kubernetes health checks sustained for 30 seconds"
        exit 0
      fi
      sleep 2
    done
    echo "$1: sustained readiness deadline exceeded" >&2
    exit 1

[doc('Generate client credentials from existing secrets without rendering machine configs')]
credentials:
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    mkdir -p "{{ talos_dir }}/../.local/topf"
    work=$(mktemp -d "{{ talos_dir }}/../.local/topf/credentials.XXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    just talos _secrets "$work/secrets.yaml"
    if ! mise exec -- topf --topfconfig "{{ talos_dir }}/topf.yaml" talosconfig >"$work/talosconfig" 2>"$work/log"; then
      echo "Client credential generation failed; private diagnostics withheld" >&2
      exit 1
    fi
    [[ ! -L "{{ talos_dir }}/output" ]] || { echo "Refusing symlink output directory" >&2; exit 1; }
    mkdir -p "{{ talos_dir }}/output"
    chmod 700 "{{ talos_dir }}/output"
    mv "$work/talosconfig" "{{ talos_dir }}/output/talosconfig"

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
    config="${TALOSCONFIG:-{{ talos_dir }}/output/talosconfig}"
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
    config="${TALOSCONFIG:-{{ talos_dir }}/output/talosconfig}"
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
    image=$(mise exec -- yq -er 'select(.kind == "UnattendedInstallConfig") | .installer.image' "{{ talos_dir }}/output/$1.yaml")
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
    printf '%s: %s (dry_run=%s)\n' "$1" "$url" "$2"
    if [[ "$2" == false ]]; then
      read -r -p "Recreate $1's VM disk? Type the hostname: " confirm
      [[ "$confirm" == "$1" ]] || { echo "Reprovisioning not confirmed" >&2; exit 1; }
    fi
    targets=$(mise exec -- jq -cn --arg node "$1" '{target_vms: [$node]}')
    mise exec -- just ansible playbook utilities/reprovision-talos-vm.yaml \
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
    bash "{{ talos_dir }}/test.sh"
