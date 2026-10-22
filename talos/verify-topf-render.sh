#!/usr/bin/env bash
set -euo pipefail

umask 077

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
topf_bin=${TOPF_BIN:-}
expected_sha256=f743f07894f296ae9ca41bde42045df8a62aab53258e855fa753421637693c2d

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

assert_equal() {
  local label=$1
  local actual=$2
  local expected=$3

  if [ "$actual" != "$expected" ]; then
    fail "$label"
  fi
}

assert_file() {
  [ -f "$1" ] || fail "missing generated file: $1"
}

[ -n "$topf_bin" ] || fail "set TOPF_BIN to the locally built postfinance/topf#177 binary"
[ -x "$topf_bin" ] || fail "TOPF_BIN is not executable: $topf_bin"

actual_sha256=$(shasum -a 256 "$topf_bin" | awk '{print $1}')
assert_equal "TOPF SHA-256 mismatch" "$actual_sha256" "$expected_sha256"

module_info=$(go version -m "$topf_bin")
for module in github.com/siderolabs/talos github.com/siderolabs/talos/pkg/machinery; do
  version=$(awk -v module="$module" '$1 == "dep" && $2 == module {print $3}' <<<"$module_info")
  assert_equal "$module must be exactly v1.14.4" "$version" "v1.14.4"
done

workdir=$(mktemp -d "${TMPDIR:-/tmp}/topf-render-proof.XXXXXX")
trap 'rm -rf -- "$workdir"' EXIT
chmod 700 "$workdir"

mkdir -p "$workdir/talhelper" "$workdir/topf"
chmod 700 "$workdir/talhelper" "$workdir/topf"

cd "$repo_root"

talhelper genconfig \
  --offline-mode \
  --config-file "$repo_root/talos/talconfig.yaml" \
  --env-file "$repo_root/talos/talenv.sops.yaml" \
  --secret-file "$repo_root/talos/talsecret.sops.yaml" \
  --out-dir "$workdir/talhelper" \
  --no-gitignore >/dev/null
"$repo_root/talos/preserve-etcd-encryption.sh" \
  "$workdir"/talhelper/talos-proxmox-cluster-*.yaml

envfile=$(mktemp "$workdir/talenv.XXXXXX")
sops --decrypt --output-type dotenv talos/talenv.sops.yaml > "$envfile"
chmod 600 "$envfile"
set -a
# shellcheck disable=SC1090
source "$envfile"
set +a
rm -f "$envfile"

"$topf_bin" \
  --topfconfig "$repo_root/talos/topf.yaml" \
  --log-level error \
  render --output "$workdir/topf" >/dev/null

nodes=(talos-cp-01 talos-cp-02 talos-cp-03 talos-01 talos-02 talos-03)

normalize_common_documents() {
  local input=$1
  local output=$2

  yq -o=json -I=0 '
    select(
      .kind == "DiscoveryServiceConfig" or
      .kind == "ResolverConfig" or
      .kind == "FilesystemTrimConfig" or
      .kind == "HostnameConfig" or
      .kind == "KubeNetworkConfig" or
      .kind == "KubeAdmissionControlConfig" or
      .kind == "KubeAuditPolicyConfig" or
      .kind == "KubeAuthenticationConfig" or
      .kind == "KubeAuthorizerConfig" or
      .kind == "KubeAPIServerConfig" or
      .kind == "KubeControllerManagerConfig" or
      .kind == "KubeSchedulerConfig" or
      .kind == "KubeProxyConfig" or
      .kind == "LinkAliasConfig" or
      .kind == "DHCPv4Config" or
      .kind == "Layer2VIPConfig" or
      .kind == "ExtensionServiceConfig"
    ) |
    (.environment[]? |= sub("^TS_AUTHKEY=.*$"; "TS_AUTHKEY=<redacted>"))
  ' "$input" | jq -s -S 'sort_by(.kind, .name // "")' > "$output"
}

document_count() {
  local file=$1
  local last_index

  last_index=$(yq -N 'document_index' "$file" | tail -1)
  echo $((last_index + 1))
}

first_document_json() {
  yq -o=json -I=0 'select(document_index == 0)' "$1"
}

document_json() {
  local kind=$1
  local file=$2

  yq -o=json -I=0 "select(.kind == \"$kind\")" "$file"
}

for node in "${nodes[@]}"; do
  talhelper_config="$workdir/talhelper/talos-proxmox-cluster-$node.yaml"
  topf_config="$workdir/topf/$node.yaml"

  assert_file "$talhelper_config"
  assert_file "$topf_config"

  talosctl validate -m metal -c "$talhelper_config" >/dev/null
  talosctl validate -m metal -c "$topf_config" >/dev/null

  normalize_common_documents "$talhelper_config" "$workdir/$node-talhelper-common.json"
  normalize_common_documents "$topf_config" "$workdir/$node-topf-common.json"
  cmp -s "$workdir/$node-talhelper-common.json" "$workdir/$node-topf-common.json" ||
    fail "$node common documents differ"

  talhelper_hostname=$(yq -r 'select(.kind == "HostnameConfig") | .hostname' "$talhelper_config")
  topf_hostname=$(yq -r 'select(.kind == "HostnameConfig") | .hostname' "$topf_config")
  assert_equal "$node Talhelper hostname mismatch" "$talhelper_hostname" "$node"
  assert_equal "$node TOPF hostname mismatch" "$topf_hostname" "$node"

  talhelper_endpoint=$(first_document_json "$talhelper_config" | jq -r '.cluster.controlPlane.endpoint')
  topf_endpoint=$(yq -r 'select(.kind == "KubeClusterConfig") | .endpoint' "$topf_config")
  assert_equal "$node cluster endpoint mismatch" "$topf_endpoint" "$talhelper_endpoint"

  talhelper_kubelet_args=$(first_document_json "$talhelper_config" | jq -c '.machine.kubelet.extraArgs')
  topf_kubelet_args=$(yq -o=json -I=0 'select(.kind == "KubeletConfig") | .extraArgs' "$topf_config")
  assert_equal "$node kubelet arguments mismatch" "$topf_kubelet_args" "$talhelper_kubelet_args"

  talhelper_machine_fields=$(first_document_json "$talhelper_config" | jq -c '
    [
      .machine.type,
      .machine.certSANs,
      .machine.kernel.modules,
      .machine.sysctls,
      .machine.features.diskQuotaSupport
    ]
  ')
  topf_machine_fields=$(first_document_json "$topf_config" | jq -c '
    [
      .machine.type,
      .machine.certSANs,
      .machine.kernel.modules,
      .machine.sysctls,
      .machine.features.diskQuotaSupport
    ]
  ')
  assert_equal "$node machine fields mismatch" "$topf_machine_fields" "$talhelper_machine_fields"

  assert_equal "$node NFS config content mismatch" \
    "$(document_json EtcFileConfig "$topf_config" | jq -r 'select(.name == "nfsmount.conf") | .contents')" \
    "$(first_document_json "$talhelper_config" | jq -r '.machine.files[] | select(.path == "/etc/nfsmount.conf") | .content')"
  assert_equal "$node NFS config mode mismatch" \
    "$(document_json EtcFileConfig "$topf_config" | jq -r 'select(.name == "nfsmount.conf") | .mode')" \
    "$(first_document_json "$talhelper_config" | jq -r '.machine.files[] | select(.path == "/etc/nfsmount.conf") | .permissions')"
  assert_equal "$node CRI customization mismatch" \
    "$(document_json CRICustomizationConfig "$topf_config" | jq -r 'select(.name == "20-customization") | .content')" \
    "$(first_document_json "$talhelper_config" | jq -r '.machine.files[] | select(.path == "/etc/cri/conf.d/20-customization.part") | .content')"
  assert_equal "$node udev rules mismatch" \
    "$(document_json UdevRulesConfig "$topf_config" | jq -c '.rules')" \
    "$(first_document_json "$talhelper_config" | jq -c '.machine.udev.rules')"

  talhelper_image=$(first_document_json "$talhelper_config" | jq -r '.machine.install.image')
  topf_image=$(yq -r 'select(.kind == "UnattendedInstallConfig") | .installer.image' "$topf_config")
  assert_equal "$node installer image mismatch" "$topf_image" "$talhelper_image"
  assert_equal "$node Talhelper install disk mismatch" \
    "$(first_document_json "$talhelper_config" | jq -r '.machine.install.disk')" \
    "/dev/sda"
  assert_equal "$node TOPF install disk selector mismatch" \
    "$(yq -r 'select(.kind == "UnattendedInstallConfig") | .provisioning.diskSelector.match' "$topf_config")" \
    'disk.dev_path == "/dev/sda"'

  case "$node" in
    talos-01|talos-02)
      expected_schematic=4f8ddeb720971458e26626be4ed22e98c03f9ebfafb9fdbfe8d2f3536bcfe4f8
      expected_modules='["nvidia","nvidia_uvm","nvidia_drm","nvidia_modeset"]'
      ;;
    talos-cp-*|talos-03)
      expected_schematic=58e4656b31857557c8bad0585e1b2ee53f7446f4218f3fae486aa26d4f6470d8
      expected_modules='[]'
      ;;
  esac

  schematic=$(sed -E 's#^.*/metal-installer/([^:]+):v.*$#\1#' <<<"$topf_image")
  assert_equal "$node schematic mismatch" "$schematic" "$expected_schematic"

  modules=$(first_document_json "$topf_config" | jq -c '[.machine.kernel.modules[]?.name]')
  assert_equal "$node kernel modules mismatch" "$modules" "$expected_modules"

  [[ "$topf_image" == *":v1.14.4" ]] || fail "$node Talos version mismatch"
  assert_equal "$node Kubernetes version mismatch" \
    "$(yq -r 'select(.kind == "KubeletConfig") | .image' "$topf_config")" \
    "ghcr.io/siderolabs/kubelet:v1.35.3"

  talhelper_auth=$(yq -r 'select(.kind == "ExtensionServiceConfig" and .name == "tailscale") | .environment[] | select(test("^TS_AUTHKEY="))' "$talhelper_config")
  topf_auth=$(yq -r 'select(.kind == "ExtensionServiceConfig" and .name == "tailscale") | .environment[] | select(test("^TS_AUTHKEY="))' "$topf_config")
  assert_equal "$node Tailscale auth environment mismatch" "$topf_auth" "$talhelper_auth"

  assert_equal "$node machine SANs mismatch" \
    "$(first_document_json "$topf_config" | jq -c '.machine.certSANs')" \
    "$(first_document_json "$talhelper_config" | jq -c '.machine.certSANs')"

  if [[ "$node" == talos-cp-* ]]; then
    talhelper_provider_names=$(document_json KubeEtcdEncryptionConfig "$talhelper_config" |
      jq -c '[.config.resources[0].providers[] | keys | .[0]]')
    talhelper_key_names=$(document_json KubeEtcdEncryptionConfig "$talhelper_config" |
      jq -c '[.config.resources[0].providers[].secretbox.keys[]?.name]')
    provider_names=$(document_json KubeEtcdEncryptionConfig "$topf_config" |
      jq -c '[.config.resources[0].providers[] | keys | .[0]]')
    key_names=$(document_json KubeEtcdEncryptionConfig "$topf_config" |
      jq -c '[.config.resources[0].providers[].secretbox.keys[]?.name]')
    assert_equal "$node Talhelper encryption provider order mismatch" "$talhelper_provider_names" '["secretbox","identity"]'
    assert_equal "$node Talhelper encryption key name mismatch" "$talhelper_key_names" '["key2"]'
    assert_equal "$node encryption provider order mismatch" "$provider_names" '["secretbox","identity"]'
    assert_equal "$node encryption key name mismatch" "$key_names" '["key2"]'

    talhelper_encryption_secret=$(yq -r '
      select(.kind == "KubeEtcdEncryptionConfig") |
      .config.resources[0].providers[0].secretbox.keys[0].secret
    ' "$talhelper_config")
    topf_encryption_secret=$(yq -r '
      select(.kind == "KubeEtcdEncryptionConfig") |
      .config.resources[0].providers[0].secretbox.keys[0].secret
    ' "$topf_config")
    assert_equal "$node encryption secret mismatch" "$topf_encryption_secret" "$talhelper_encryption_secret"

    assert_equal "$node control-plane label mismatch" \
      "$(yq -r 'select(.kind == "KubeNodeConfig") | .labels."node.kubernetes.io/exclude-from-external-load-balancers"' "$topf_config")" \
      ""
    assert_equal "$node Talos API roles mismatch" \
      "$(document_json KubeTalosAPIAccessConfig "$topf_config" | jq -c '.allowedRoles')" \
      '["os:admin"]'
    assert_equal "$node Talos API namespaces mismatch" \
      "$(document_json KubeTalosAPIAccessConfig "$topf_config" | jq -c '.allowedKubernetesNamespaces')" \
      '["actions-runner-system","system-upgrade"]'
    assert_equal "$node API server SANs mismatch" \
      "$(yq -o=json -I=0 'select(.kind == "KubeAPIServerConfig") | .certSANs' "$topf_config")" \
      "null"
  fi

  talhelper_docs=$(document_count "$talhelper_config")
  topf_docs=$(document_count "$topf_config")
  [ "$talhelper_docs" -gt 1 ] || fail "$node Talhelper output is not multi-document"
  [ "$topf_docs" -gt "$talhelper_docs" ] || fail "$node TOPF output did not expand to Talos 1.14 documents"

  printf '%-12s %-14s %-16s %-13s %-8s\n' \
    "$node" \
    "documents:${talhelper_docs}->${topf_docs}" \
    "schematic:${schematic:0:8}" \
    "versions:match" \
    "PASS"
done

echo
echo "TOPF render proof passed for all six nodes."
echo "Generated machine configs were stored only in $workdir and will be removed on exit."
