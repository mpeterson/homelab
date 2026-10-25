#!/usr/bin/env bash
set -euo pipefail
umask 077

source_dir=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'status=$?; if (( status )); then echo "Isolated Talos fixture failed" >&2; [[ ! -f "$work/state/output" ]] || cat "$work/state/output" >&2; fi; rm -rf -- "$work"; exit "$status"' EXIT
mkdir -p "$work"/{talos,ansible,bin,state,kubernetes/infra/tuppr/upgrades}
cp "$source_dir/mod.just" "$work/talos/mod.just"
cp "$source_dir/../ansible/mod.just" "$work/ansible/mod.just"
printf 'set unstable := true\nmod talos\nmod ansible\n' >"$work/.justfile"
cat >"$work/talos/topf.yaml" <<'YAML'
---
clusterEndpoint: https://10.0.0.10:6443
talosVersion: v1.14.4
secretsPath: bundle.yaml
nodes:
  - host: cp-01
    role: control-plane
    ip: 10.0.0.1
  - host: worker-01
    role: worker
    ip: 10.0.0.2
YAML
printf '%s\n' '---' 'kind: TalosUpgrade' 'spec:' '  talos:' '    version: v1.14.4' >"$work/kubernetes/infra/tuppr/upgrades/talos.yaml"
cat >"$work/talos/bundle.yaml" <<'YAML'
---
cluster: {id: synthetic-id, secret: synthetic-discovery}
secrets: {bootstraptoken: synthetic-bootstrap, secretboxencryptionsecret: synthetic-secretbox}
trustdinfo: {token: synthetic-talos}
certs:
  os: {crt: synthetic-ca, key: synthetic-os-key}
  etcd: {crt: synthetic-etcd, key: synthetic-etcd-key}
  k8s: {crt: synthetic-k8s, key: synthetic-k8s-key}
  k8saggregator: {crt: synthetic-aggregator, key: synthetic-aggregator-key}
  k8sserviceaccount: {key: synthetic-account}
YAML
cat >"$work/cp.yaml" <<'YAML'
---
version: v1alpha1
machine:
  ca: {crt: synthetic-ca, key: synthetic-os-key}
  token: synthetic-talos
cluster: {token: synthetic-bootstrap}
---
apiVersion: v1alpha1
kind: HostnameConfig
hostname: cp-01
---
apiVersion: v1alpha1
kind: DiscoveryIdentityConfig
clusterID: synthetic-id
clusterSecret: synthetic-discovery
---
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: tailscale
environment: [TS_AUTHKEY=synthetic-auth]
---
apiVersion: v1alpha1
kind: KubeEtcdEncryptionConfig
config:
  resources:
    - resources: [secrets]
      providers:
        - secretbox:
            keys: [{name: key2, secret: synthetic-secretbox}]
        - identity: {}
---
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: factory.talos.dev/metal-installer/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:v1.14.4
YAML
yq 'select(.kind != "KubeEtcdEncryptionConfig") |
  with(select(.version == "v1alpha1"); .machine.ca.key = "") |
  with(select(.kind == "HostnameConfig"); .hostname = "worker-01")' "$work/cp.yaml" >"$work/worker.yaml"
cat >>"$work/worker.yaml" <<'YAML'
---
apiVersion: v1alpha1
kind: SysctlConfig
params:
  net.core.bpf_jit_harden: "1"
YAML
cp "$work/worker.yaml" "$work/worker-original.yaml"
cat >"$work/bin/mise" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == exec && "$2" == -- ]] || exit 98
shift 2
exec "$@"
SH
cat >"$work/bin/sops" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == --decrypt ]] || exit 98
cat "$2"
SH
cat >"$work/bin/topf" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *" --version "*) printf '%s\n' "${TOPF_VERSION:-topf version 0.6.2 (Talos v1.14.4)}" ;;
  *" render "*)
    echo render >>"$TEST_ROOT/state/rendered"
    while [[ "$1" != --output ]]; do shift; done
    cp "$TEST_ROOT/cp.yaml" "$2/cp-01.yaml"
    [[ "${PARTIAL_RENDER:-false}" == true ]] || cp "$TEST_ROOT/worker.yaml" "$2/worker-01.yaml"
    [[ "${BAD_ENCRYPTION:-false}" != true ]] || yq -i 'with(select(.kind == "KubeEtcdEncryptionConfig"); .config.resources[0].providers[0].secretbox.keys[0].name = "key1")' "$2/cp-01.yaml"
    [[ "${BAD_AUTH:-false}" != true ]] || yq -i 'with(select(.kind == "ExtensionServiceConfig"); .environment += ["TS_AUTHKEY="])' "$2/cp-01.yaml"
    [[ "${BAD_SYSCTL:-false}" != true ]] || yq -i 'with(select(.kind == "SysctlConfig"); .params["net.core.bpf_jit_harden"] = "0")' "$2/worker-01.yaml"
    [[ "${BAD_MODULES:-false}" != true ]] || yq -i 'select(.kind != "KernelModuleConfig")' "$2/worker-01.yaml"
    ;;
  *" talosconfig "*) echo synthetic-client ;;
  *) exit 98 ;;
esac
SH
cat >"$work/bin/talosctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_ROOT/state/calls"
case " $* " in
  *" version "*) printf 'Client:\n  Tag: %s\n' "${CLIENT_VERSION:-v1.14.4}" ;;
  *" validate "*)
    cat >"$TEST_ROOT/state/validated"
    [[ "${FAIL_VALIDATE:-false}" != true ]] || { echo private-invalid-config >&2; exit 1; }
    ;;
  *" apply-config "*)
    if [[ " $* " == *" --dry-run "* ]]; then
      cat >"$TEST_ROOT/state/dryrun"
      if [[ "${REBOOT_REQUIRED:-false}" == true ]]; then
        echo "Reboot required" >&2
      else
        echo "Applied configuration without a reboot (skipped in dry-run)." >&2
      fi
      echo old-private-auth
      echo new-private-auth >&2
      [[ "${MUTATE_AFTER_DRYRUN:-false}" != true ]] || echo unvalidated-source-change >"$TEST_ROOT/worker.yaml"
    else
      cat >"$TEST_ROOT/state/applied"
    fi
    ;;
  *" health "*) [[ "${FAIL_HEALTH:-false}" != true ]] ;;
  *" reset "*|*" reboot "*) ;;
  *) exit 98 ;;
esac
SH
cat >"$work/bin/ansible-playbook" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$TEST_ROOT/state/ansible-args"
SH
chmod 700 "$work/bin/"*
export TEST_ROOT="$work" PATH="$work/bin:$PATH"
cd "$work"

fail() { echo "FAIL: $*" >&2; exit 1; }
expect_failure() {
  if "$@" >state/output 2>&1; then fail "Unexpected success: $*"; fi
}

just talos versions >state/output
TOPF_VERSION='topf version dev' expect_failure just talos versions
CLIENT_VERSION=v1.13.12 expect_failure just talos versions
yq -i '.spec.talos.version = "v1.14.5"' kubernetes/infra/tuppr/upgrades/talos.yaml
expect_failure just talos versions
yq -i '.spec.talos.version = "v1.14.4"' kubernetes/infra/tuppr/upgrades/talos.yaml
for version in v1.14.5 v1.15.0 v1.14.5-rc.1 v1.14.99999999999999999999999; do
  TARGET="$version" yq -i '.talosVersion = strenv(TARGET)' talos/topf.yaml
  expect_failure just talos versions
done
yq -i '.talosVersion = "v1.14.4" | .nodes[1].talosVersion = "v1.14.5"' talos/topf.yaml
expect_failure just talos versions
yq -i 'del(.nodes[1].talosVersion)' talos/topf.yaml
just talos genconfig >state/output 2>&1
cp talos/output/worker-01.yaml state/published
PARTIAL_RENDER=true expect_failure just talos genconfig
cmp -s state/published talos/output/worker-01.yaml || fail "Failed generation replaced published output"
FAIL_VALIDATE=true expect_failure just talos genconfig
BAD_ENCRYPTION=true expect_failure just talos genconfig
BAD_AUTH=true expect_failure just talos genconfig
BAD_SYSCTL=true expect_failure just talos genconfig
for module in nvidia nvidia_uvm nvidia_drm nvidia_modeset; do
  printf '%s\n' '---' 'apiVersion: v1alpha1' 'kind: KernelModuleConfig' "name: $module" >>worker.yaml
done
expect_failure just talos genconfig
yq -i '.nodes[1].data.gpu = true' talos/topf.yaml
just talos genconfig >state/output 2>&1
BAD_MODULES=true expect_failure just talos genconfig
cp worker-original.yaml worker.yaml
expect_failure just talos genconfig
yq -i 'del(.nodes[1].data)' talos/topf.yaml
cp worker.yaml state/native-worker
yq -i 'with(select(.version == "v1alpha1"); .machine.sysctls["net.core.bpf_jit_harden"] = "1")' worker.yaml
expect_failure just talos genconfig
cp state/native-worker worker.yaml
yq -i 'with(select(.version == "v1alpha1"); .machine.kernel.modules = [{"name": "nvidia"}])' worker.yaml
expect_failure just talos genconfig
cp state/native-worker worker.yaml
cp state/rendered state/before-invalid-bundle
mv talos/bundle.yaml talos/saved-bundle.yaml
expect_failure just talos genconfig
mv talos/saved-bundle.yaml talos/bundle.yaml
cp talos/bundle.yaml state/bundle
yq -i '.certs.os.key = ""' talos/bundle.yaml
expect_failure just talos genconfig
cp state/bundle talos/bundle.yaml
cmp -s state/before-invalid-bundle state/rendered || fail "Invalid/missing secrets reached TOPF"
mv talos/bundle.yaml talos/secrets.yaml
yq -i 'del(.secretsPath)' talos/topf.yaml
just talos genconfig >state/output 2>&1
just talos credentials >state/output 2>&1
grep -Fxq synthetic-client talos/output/talosconfig || fail "Credentials did not use the TOPF output directory"
expect_failure just talos diff '.*'
REBOOT_REQUIRED=true expect_failure just talos diff worker-01
just talos diff worker-01 >state/output 2>&1
cmp -s state/validated state/dryrun || fail "Dry-run did not receive the validated payload"
if grep -Eq 'old-private-auth|new-private-auth|private-invalid-config' state/output; then fail "Private tool output leaked"; fi
if printf 'no\n' | just talos apply worker-01 >state/output 2>&1; then fail "Unconfirmed application succeeded"; fi
[[ ! -f state/applied ]] || fail "Unconfirmed application reached the node"
printf 'worker-01\n' | MUTATE_AFTER_DRYRUN=true just talos apply worker-01 >state/output 2>&1
cmp -s state/validated state/dryrun || fail "Dry-run bytes changed"
cmp -s state/dryrun state/applied || fail "Application rerendered or reread the payload"
grep -Fq -- '--k8s-endpoint https://10.0.0.10:6443' state/calls || fail "Health checks were not endpoint-bound"
grep -Fq -- '--server=true' state/calls || fail "Health used ambient client-side Kubernetes credentials"
if grep -Eq 'old-private-auth|new-private-auth' state/output; then fail "Application leaked private output"; fi
cp worker-original.yaml worker.yaml
printf 'worker-01\n' | FAIL_HEALTH=true just talos apply worker-01 >state/output 2>&1 && fail "Failed health gate was ignored"
mkdir -p .local/topf/apply.lock
expect_failure just talos apply worker-01
just talos versions >state/output
rmdir .local/topf/apply.lock
yq -i '.talosVersion = "v1.99.0"' talos/topf.yaml
printf 'worker-01\n' | just talos reset-node worker-01 no-reboot >state/output 2>&1
tail -1 state/calls | grep -q ' reset ' || fail "Recovery required generation"
if tail -1 state/calls | grep -q -- '--reboot'; then fail "Non-reboot reset mode was lost"; fi
printf 'worker-01\n' | just talos reboot-node worker-01 >state/output 2>&1
yq -i '.talosVersion = "v1.14.4"' talos/topf.yaml
printf 'no\n' | just talos reprovision-cluster >state/output 2>&1 && fail "Cluster reprovision lacked upfront confirmation"
[[ ! -f state/ansible-args ]] || fail "Unconfirmed cluster reprovision reached Ansible"
touch portable-inventory
ANSIBLE_INVENTORY="$work/portable-inventory" just talos reprovision-node worker-01 true >state/output 2>&1
grep -Fxq "$work/portable-inventory" state/ansible-args || fail "An arbitrary inventory was not accepted"
grep -Fxq '{"target_vms":["worker-01"]}' state/ansible-args || fail "Ansible arguments lost their quoting"
echo "Talos shell guards passed: versions, secrets, native worker settings, complete render, strict validation, immutable payload, private output, native health, recovery and portable inventory"
