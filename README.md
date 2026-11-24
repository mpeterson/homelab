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

### Home Assistant and Music Assistant external access

The public HTTPRoutes in `kubernetes/infra/cilium/` expose Home Assistant at
`https://hass.peterson.com.ar` and its Music Assistant add-on at
`https://music-assistant.peterson.com.ar` through the existing HTTPS gateway.
ExternalDNS manages their DNS records, and the gateway terminates TLS with the
existing wildcard certificate. Backend Services and endpoint configuration live
in `external-backends.sops.yaml`, encrypted with SOPS and rendered by KSOPS, so
their private addresses are not published in plaintext.

Home Assistant's existing Service, Endpoints, and HTTPRoute are adopted unchanged
into GitOps. Its legacy Endpoints resource is retained to avoid disrupting the
existing mirrored EndpointSlice; new external backends use explicit EndpointSlices.
Only these two application endpoints are exposed, not HA Supervisor or other
infrastructure interfaces. Encryption conceals backend configuration in Git;
authentication and network segmentation must still enforce access at runtime.

In Music Assistant's **Settings > System > Webserver**, enable advanced settings
and set **External URL** to `https://music-assistant.peterson.com.ar`. Keep its
listening port at `8095` and backend TLS disabled; the gateway provides HTTPS.
Use the HTTPS URL as the server address in the Music Assistant app.
Direct access uses Music Assistant authentication, not Home Assistant Ingress
authentication; configure an MA login before exposing the endpoint. If signing
in through Home Assistant, use its public URL (`https://hass.peterson.com.ar`)
in MA's Home Assistant connection settings so remote clients can complete login.

The route supports WebSockets and disables the HTTP request timeout for
long-lived connections. No Nabu Casa subscription or separate public port is
needed. Leave the streamserver's published IP and port at their LAN settings for
local speakers; do not replace its published IP with the public hostname.
CI's keyless manifest validation and diff preview omit KSOPS-generated resources;
changes to encrypted backends also need a local decrypted build and validation.

## License

This project is licensed under the [MIT License](LICENSE).
