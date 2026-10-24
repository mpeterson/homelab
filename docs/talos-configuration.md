# Talos configuration operations

## Source configuration

TOPF v0.6.2 embeds Talos v1.14.4. The pinned `talosctl` version must match
`talosVersion` exactly. All nodes must use the same verified Talos 1.14 contract;
newer patch versions than TOPF supports, prereleases, and unreviewed minor
versions are rejected. Tuppr's `TalosUpgrade` target must match this contract too.
`just talos versions` checks these inputs without decrypting secrets and runs on
every PR alongside `just talos test`. The active `main` ruleset requires
**All validations passed**, which fails unless the Talos guard succeeds. An
unsupported bump therefore blocks normal PR merging, including a Tuppr-only bump.

| Input | Purpose |
| --- | --- |
| `talos/topf.yaml` | Cluster versions, endpoint, six node identities and schematic classes |
| `talos/patches/all/00-machine.yaml.tpl` | Shared native Talos settings and hostname |
| `talos/patches/all/90-tailscale.sops.yaml` | Encrypted Tailscale extension-service configuration |
| `talos/patches/control-plane/00-control-plane.yaml` | VIP/networking, API access, labels, proxy and encryption |
| `talos/patches/worker/00-worker.yaml.tpl` | Worker sysctl and GPU modules from explicit per-node data |
| `talos/schematics/*.yaml` | Control-plane, GPU-worker and standard-worker extension sets |
| `talos/talsecret.sops.yaml` | Unchanged, existing cluster identity and encryption material |

TOPF applies global patches, role patches, then `patches/node/<hostname>/`
overrides if present. Filenames sort within a layer. Multi-document files keep
related native Talos settings together without a separate inventory abstraction.

SOPS decrypts non-template patches internally. The encrypted Tailscale patch
replaces the former environment substitution file; no decrypted dotenv is
sourced. The control-plane encryption patch resolves the existing encrypted
Secretbox key through pinned vals tooling. Keep the secret reference relative
to the repository root; the wrappers always run TOPF there.

The effective provider order is **Secretbox with `key2`, then `identity`**.
The key bytes, key name, and provider ordering must not change. Generation checks
this invariant before publishing output. There is no post-generation encryption
rewrite and no secret generation/bootstrap workflow.

The three schematic classes remain separate even though control planes and the
standard worker currently share ID
`58e4656b31857557c8bad0585e1b2ee53f7446f4218f3fae486aa26d4f6470d8`.
GPU workers retain
`4f8ddeb720971458e26626be4ed22e98c03f9ebfafb9fdbfe8d2f3536bcfe4f8`.
The paired NVIDIA LTS extensions must continue resolving to R580-compatible
drivers for the Quadro P2000. Generation computes existing schematic IDs locally;
it does not register schematics with Image Factory.

## Commands and private output

Bootstrap tools with `mise install` and make the SOPS Age key available using
`SOPS_AGE_KEY_FILE` (default `~/.config/sops/age/keys.txt`). The recipes use
mise-managed Python and tools explicitly.

```sh
just talos versions
just talos check
just talos genconfig
just talos validate
just talos diff talos-03
just talos apply talos-03
```

Generation is offline. Temporary outputs live in private ignored
`.local/topf/` directories and are removed on success/failure. Only a complete,
strictly validated generation is published to `talos/clusterconfig/`, with mode
0700 directories and 0600 machine/client configs. Diff and apply use their own
fresh private generation, not cached machine configs. Generation/application
locks fail immediately on contention; help, version checks and independent
dry-runs do not wait for them.

Configuration-bearing tool diagnostics are withheld with the operation context
and exit status; ordinary readiness diagnostics remain available. Do not enable
shell tracing, paste machine configs, or upload generated output. CI runs only
secret-free compatibility/regression checks.

Diff is an exact-node server-side dry-run through `talosctl`. It reports changed
document kinds, never raw configuration diffs: TOPF's redactor is not relied on
to hide old live secret values. Each payload is captured in memory, strictly
validated through stdin, then sent unchanged through stdin for the server-side
dry-run and application. TOPF does not rerender during application.

Apply allows no arbitrary flag passthrough, requires exact-hostname confirmation
and forces no-reboot mode. It checks readiness before application and requires
30 continuous seconds of Talos health and Kubernetes Ready afterwards, with a
five-minute deadline. Kubernetes checks use freshly generated private credentials
whose endpoint is verified against `clusterEndpoint`, plus an explicit server
override; the ambient kubeconfig/context is never used. Node readiness alone is
not a workload health check; perform the additional gates below.

`download-iso` deduplicates rendered installer references. `reset-node`,
`reboot-node`, and non-dry-run reprovisioning require the exact hostname as
confirmation and must only be used with explicit authorization. Recovery recipes
live in Just and use existing `TALOSCONFIG` credentials (default
`talos/clusterconfig/talosconfig`), without regenerating machine configs or
requiring all live versions to match during a staged upgrade. If credentials are
missing, `just talos credentials` creates only client credentials from the
existing encrypted bundle. `reset-node <node> no-reboot` preserves the optional
non-reboot reset mode. Cluster reprovisioning adds an upfront all-node warning
and confirmation before the individual confirmations.

Reprovisioning uses the existing Ansible inventory convention; set
`ANSIBLE_INVENTORY` when the private sibling inventory is elsewhere.

Tuppr remains the only Talos/Kubernetes upgrade orchestrator. Do not use TOPF
upgrade or auto-bootstrap for this existing cluster.

## Migration comparison

Before replacing a generator, freeze a final render and the persistent live
machine configs into ignored mode 0700 directories with mode 0600 files. Retain
the existing client credentials and exact source/tool versions privately.
The TOPF migration baseline uses the merged Talhelper encryption guard.

The migration-only comparator and legacy normalization are retained privately,
outside the repository; they are not a permanent recipe or compatibility layer.
The comparison checks every document, including unknown/new documents, all
remaining base fields, volumes, and exact private key/token values. It prints only
node results or mismatching document identities, never values. Native document
identity includes both kind and name; duplicate identities are rejected.

Explicit legacy-to-native mappings cover discovery identity, cluster endpoint,
Kubernetes CAs/service-account issuer, kubelet, installation, NFS/CRI files, udev,
KubePrism, Talos API access, node labels/taints and CoreDNS defaults.
Native kubelet configuration always disables the manifests directory.
The native unattended installer retains disk selection, wipe policy, exact
installer image and the Talos 1.14 UKI installation path.
Sysctl numbers and their live string serialization are compared equivalently.
Any other unmapped field or changed document blocks migration.

Talos v1.14.4 generation introduces defaults absent from this existing cluster.
The patches explicitly preserve `VolumeConfig` EPHEMERAL `mount.secure: false`
and `SecurityProfileConfig` `workloadIsolation: false`, instead of inheriting new
generator defaults. The private comparison treats legacy absence as these false
policies. `mount.secure` controls mount hardening, not disk encryption.
The generated Flannel CNI document is removed because Cilium owns networking.
The encryption document is deleted and replaced to avoid merging provider
arrays; these are native document-patch operations, not live resource deletion.
Explicit virtio DHCP/VIP documents remain control-plane-only; workers retain
their existing automatic networking.

## Sequential rollout and rollback gates

The rollout order is `talos-03`, `talos-01`, `talos-02`, `talos-cp-01`,
`talos-cp-02`, `talos-cp-03`. Obtain explicit approval before **each** live apply.

1. Confirm all nodes Ready, healthy direct/VIP APIs and synchronized etcd.
   Record networking, storage, GPU/runtime and alert baselines.
2. Render twice, compare deterministic canonical output, strictly validate all six
   configs, and compare Talhelper/TOPF/live semantics.
3. Run all six server-side dry-runs. Explain every document representation change;
   no unexplained behavioral difference or reboot requirement is acceptable.
4. Immediately before each approved apply, repeat its focused dry-run and verify
   the same installer, schematic and encryption invariants.
5. Apply only that node. Wait for sustained Talos health and Kubernetes readiness;
   verify relevant workloads before proceeding to another node.
6. On GPU workers verify capacity/allocatable 8/8, healthy Operator operands,
   unchanged R580.178.04 extensions and working Plex/Ollama GPU runtime.
7. On control planes verify direct/VIP readiness, ready kube-apiserver,
   synchronized etcd and no new Secretbox/decryption errors.
8. Finally verify Cilium/BGP/Gateway, CSI/iSCSI/controllers, all node/runtime
   versions and Alertmanager against baseline (initially Watchdog-only).

Stop on unexpected differences, failed readiness, reboot requests, encryption
errors or wider regressions. Do not reset, rebootstrap, rotate secrets, force
restarts or continue to another node. Preserve known-good private configs; any
rollback is a separately approved, one-node configuration application with the
same readiness/API/etcd gates. Retain the private baseline until rollback is no
longer needed and its retirement is explicitly agreed.
