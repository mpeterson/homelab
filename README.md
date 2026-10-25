# 🏠 Homelab

[![Talos](https://img.shields.io/endpoint?url=https%3A%2F%2Fstats-k8s.peterson.com.ar%2Ftalos_version&style=for-the-badge&logo=talos&logoColor=white&color=orange&label=talos)](https://talos.dev)
[![Kubernetes](https://img.shields.io/endpoint?url=https%3A%2F%2Fstats-k8s.peterson.com.ar%2Fkubernetes_version&style=for-the-badge&logo=kubernetes&logoColor=white&color=blue&label=k8s)](https://kubernetes.io)

[![Age](https://stats-k8s.peterson.com.ar/cluster_age_days?format=badge)](https://github.com/kashalls/kromgo/)
[![Nodes](https://stats-k8s.peterson.com.ar/cluster_node_count?format=badge)](https://github.com/kashalls/kromgo/)
[![Pods](https://stats-k8s.peterson.com.ar/cluster_pod_count?format=badge)](https://github.com/kashalls/kromgo/)
[![CPU](https://stats-k8s.peterson.com.ar/cluster_cpu_usage?format=badge)](https://github.com/kashalls/kromgo/)
[![Memory](https://stats-k8s.peterson.com.ar/cluster_memory_usage?format=badge)](https://github.com/kashalls/kromgo/)
[![Alerts](https://stats-k8s.peterson.com.ar/cluster_alert_count?format=badge)](https://github.com/kashalls/kromgo/)

---

[![License](https://img.shields.io/github/license/mpeterson/homelab?style=flat-square)](LICENSE)
[![Last Commit](https://img.shields.io/github/last-commit/mpeterson/homelab?style=flat-square)](https://github.com/mpeterson/homelab/commits/main)
[![Stars](https://img.shields.io/github/stars/mpeterson/homelab?style=flat-square)](https://github.com/mpeterson/homelab/stargazers)

Kubernetes-based homelab running on bare-metal, managed entirely through GitOps. Infrastructure is declarative, reproducible, and version-controlled.

## Tech Stack

| Component | Technology |
| --- | --- |
| OS | [Talos Linux](https://www.talos.dev/) |
| GitOps | [ArgoCD](https://argo-cd.readthedocs.io/) |
| CNI | [Cilium](https://cilium.io/) (BGP, Gateway API) |
| Storage | [democratic-csi](https://github.com/democratic-csi/democratic-csi) (NFS, iSCSI, ZFS) |
| Secrets | [SOPS](https://github.com/getsops/sops) + [Age](https://github.com/FiloSottile/age) ([KSOPS](https://github.com/viaduct-ai/kustomize-sops)) |
| Backup | [Velero](https://velero.io/) (Backblaze B2) |
| Monitoring | [Prometheus](https://prometheus.io/) + [Alertmanager](https://prometheus.io/docs/alerting/latest/alertmanager/) |
| TLS | [cert-manager](https://cert-manager.io/) |
| VPN | [Tailscale](https://tailscale.com/) |
| Automation | [Ansible](https://www.ansible.com/) + [Just](https://just.systems/) + [GitHub Actions](https://github.com/features/actions) + [Renovate](https://www.mend.io/renovate/) |
| GPU | NVIDIA (device plugin + RuntimeClass) |

## Repository Structure

```text
📂 ansible/          # Ansible playbooks and roles for node provisioning
📂 docs/             # Documentation
📂 kubernetes/
├── 📂 apps/         # Application workloads
├── 📂 bootstrap/    # Cluster bootstrap (ArgoCD)
└── 📂 infra/        # Infrastructure services
```

## Getting Started

List all available commands:

```sh
just
```

### Talos configuration

[TOPF](https://github.com/postfinance/topf) renders the six-node inventory in
`talos/topf.yaml` using compact native Talos patches and the existing SOPS-encrypted
cluster identity in `talos/secrets.yaml`. Tuppr remains responsible for Talos and
Kubernetes upgrades.

```sh
just talos genconfig
just talos diff talos-03
```

`just talos versions` checks TOPF support for the inventory and Tuppr upgrade
target without decrypting secrets. This runs on every PR and feeds the required
`All validations passed` status. New Talos minor contracts require compatibility
review.

Generated machine configs and client credentials stay private in ignored
`talos/output/`. Any pre-migration `talos/clusterconfig/` remains ignored.
`just talos apply <node>` requires exact-hostname
confirmation, sends the same strictly validated payload used by its no-reboot
dry-run, and gates application on native Talos/Kubernetes health checks against
the configured cluster. Dry-runs never display raw configuration values.
Apply one node at a time and verify workload health before proceeding.

Reset/reboot use existing `TALOSCONFIG` credentials without machine generation.
VM reprovisioning delegates to the Ansible commands below and accepts any
inventory through `ANSIBLE_INVENTORY`; no private repository checkout is required.

### Ansible inventory

Operational inventories are intentionally excluded from this public repository.
Use `ansible/sample_inventory/` as a template, or keep the real inventory in a
private sibling repository. The Ansible Just recipes default to
`../homelab-private/ansible/inventories`:

```sh
just ansible install
just ansible inventory
just ansible nas
just ansible dns
```

Pass Ansible options after the recipe, or override the inventory path when
needed:

```sh
just ansible nas --check --diff
just ansible dns --check --diff
ANSIBLE_INVENTORY=/path/to/inventory just ansible nas
just ansible playbook bind9/setup.yaml
```

Keep credentials encrypted with SOPS even when the inventory repository is
private. The Age private key must remain outside Git.

## License

This project is licensed under the [MIT License](LICENSE).
