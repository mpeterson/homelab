# TOPF render-only migration proof

This branch contains a non-mutating migration candidate from Talhelper to
[TOPF](https://github.com/postfinance/topf). Talhelper remains the repository's
source of truth until a TOPF release includes the Talos 1.14.4 dependency update
from [postfinance/topf#177](https://github.com/postfinance/topf/pull/177).

## Scope and safety

- The proof renders all six nodes locally and never contacts the Talos or
  Kubernetes cluster.
- Generated machine configurations and decrypted environment data are created
  under a mode `0700` temporary directory with `umask 077`, then removed.
- The committed comparison contains no decrypted secrets or generated machine
  configurations.
- TOPF must match SHA-256
  `f743f07894f296ae9ca41bde42045df8a62aab53258e855fa753421637693c2d`.
- `go version -m` must report both `github.com/siderolabs/talos` and
  `github.com/siderolabs/talos/pkg/machinery` at exactly `v1.14.4`.

Run the proof with the locally built binary:

```sh
TOPF_BIN=/path/to/topf just talos verify-topf
```

## Redacted comparison

| Node | Role | Talhelper docs | TOPF docs | Schematic class | Result |
| --- | --- | ---: | ---: | --- | --- |
| `talos-cp-01` | control plane | 20 | 36 | control plane (`58e4656b…`) | Pass |
| `talos-cp-02` | control plane | 20 | 36 | control plane (`58e4656b…`) | Pass |
| `talos-cp-03` | control plane | 20 | 36 | control plane (`58e4656b…`) | Pass |
| `talos-01` | GPU worker | 7 | 19 | GPU worker (`4f8ddeb7…`) | Pass |
| `talos-02` | GPU worker | 7 | 19 | GPU worker (`4f8ddeb7…`) | Pass |
| `talos-03` | standard worker | 7 | 19 | standard worker (`58e4656b…`) | Pass |

The control-plane and standard-worker schematic classes intentionally resolve to
the same ID because their extension lists are identical. The GPU-worker class
adds Gasket and the matching NVIDIA R580 LTS extensions.

The proof verifies, node by node:

- exact equality of common non-secret documents after redacting the Tailscale
  auth value;
- hostname, pod and service networks, resolver settings, DHCP link selection,
  and the `10.3.0.30` layer-2 VIP;
- `/dev/sda` installation, identical installer image and schematic ID, and
  Talos `v1.14.4`;
- Kubernetes component images at `v1.35.3`;
- NVIDIA kernel modules only on `talos-01` and `talos-02`;
- empty configured machine and API server SAN additions in both renders;
- equality of the resolved Tailscale environment value without printing it;
- equality of the etcd encryption secret without printing it;
- `KubeEtcdEncryptionConfig` provider order
  `secretbox(key2)`, then `identity`;
- successful `talosctl validate -m metal` for all 12 rendered configurations.

TOPF uses Talos 1.14's dedicated configuration documents, including
`UnattendedInstallConfig`, `KubeletConfig`, `KubeNodeConfig`,
`KubeTalosAPIAccessConfig`, `EtcFileConfig`, `CRICustomizationConfig`,
`UdevRulesConfig`, and the split CA and cluster identity documents.
Talhelper 3.1.17 emits the older representation, including
`machine.install` and `secretbox(key1)` without `identity`. The proof compares
the equivalent values across those representations and explicitly asserts the
required Talos 1.14 encryption-provider order in the TOPF output.

## Residual risks

- The exact tested TOPF build is not available from a released tag or a
  Go-installable revision. Repository-wide adoption must wait for
  postfinance/topf#177 to merge and be released so mise and Renovate can pin it.
- Live node configuration was not queried. Equivalence to the running cluster,
  including its current etcd encryption-provider order and certificate SANs,
  remains unverified.
- TOPF's generated Talos 1.14.4 encryption document omits the `identity`
  fallback. The migration config replaces that document using a vals reference
  to the existing SOPS-encrypted secret.
- The `topf schematic-ids --nodes-filter` command in the tested build returned
  all unique IDs instead of filtering. Per-node schematic assertions therefore
  use each rendered installer image.
