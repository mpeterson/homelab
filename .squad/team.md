# Squad Team

> GitOps-managed Kubernetes homelab on Talos Linux (Proxmox)

## Coordinator

| Name | Role | Notes |
|------|------|-------|
| Squad | Coordinator | Routes work, enforces handoffs and reviewer gates. |

## Members

| Name | Role | Charter | Status |
|------|------|---------|--------|
| Hayes | Lead | `.squad/agents/hayes/charter.md` | 🏗️ Active |
| Sonny | Infra Engineer | `.squad/agents/sonny/charter.md` | ⚙️ Active |
| Clay | Apps Engineer | `.squad/agents/clay/charter.md` | 🔧 Active |
| Ray | Ops Engineer | `.squad/agents/ray/charter.md` | 🔄 Active |
| Scribe | Scribe | `.squad/agents/scribe/charter.md` | 📋 Active |
| Ralph | Work Monitor | `.squad/agents/ralph/charter.md` | 🔄 Monitor |

## Project Context

- **Owner:** Michel Peterson
- **Project:** GitOps-managed Kubernetes homelab on Talos Linux VMs (Proxmox). ArgoCD reconciles cluster state from this repo. Three-tier hierarchy: bootstrap → infra → apps. Ansible for Proxmox provisioning. Toolchain: mise, just, Renovate, SOPS/KSOPS, GitHub Actions.
- **Stack:** Kubernetes, Talos Linux, ArgoCD, Helm, Kustomize, Cilium, SOPS/KSOPS, Ansible, GitHub Actions, Renovate, just, mise
- **Created:** 2026-04-07
- **Universe:** SEAL Team
