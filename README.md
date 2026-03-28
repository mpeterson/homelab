# 🏠 Homelab

[![CI](https://img.shields.io/github/actions/workflow/status/mpeterson/homelab/ci.yaml?branch=main&style=flat-square&logo=github&label=CI)](https://github.com/mpeterson/homelab/actions/workflows/ci.yaml)
[![License](https://img.shields.io/github/license/mpeterson/homelab?style=flat-square)](LICENSE)
[![Last Commit](https://img.shields.io/github/last-commit/mpeterson/homelab?style=flat-square)](https://github.com/mpeterson/homelab/commits/main)
[![Stars](https://img.shields.io/github/stars/mpeterson/homelab?style=flat-square)](https://github.com/mpeterson/homelab/stargazers)

Kubernetes-based homelab running on bare-metal, managed entirely through GitOps. Infrastructure is declarative, reproducible, and version-controlled.

## Tech Stack

| Component | Technology |
|-----------|-----------|
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

```
📂 ansible/          # Ansible playbooks and roles for node provisioning
📂 docs/             # Documentation
📂 hack/             # Ad-hoc manifests and utilities
📂 kubernetes/
├── 📂 apps/         # Application workloads
├── 📂 bootstrap/    # Cluster bootstrap (ArgoCD)
└── 📂 infra/        # Infrastructure services
```

## Getting Started

List all available commands:

```sh
just --list
```

## License

This project is licensed under the [MIT License](LICENSE).
