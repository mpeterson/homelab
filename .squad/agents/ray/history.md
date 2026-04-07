# Project Context

- **Owner:** Michel Peterson
- **Project:** GitOps-managed Kubernetes homelab on Talos Linux (Proxmox VMs). ArgoCD reconciles from this repo. Three-tier hierarchy: bootstrap (ArgoCD self-management), infra (Cilium, democratic-csi, cert-manager, Velero, Prometheus, etc.), apps (media stack, Paperless, Kopia, Ollama, n8n, etc.). Ansible handles Proxmox provisioning. Managed with mise, just, Renovate, SOPS/KSOPS, GitHub Actions.
- **Stack:** Kubernetes, Talos Linux, ArgoCD, Helm, Kustomize, Cilium, SOPS/KSOPS, Ansible, GitHub Actions, Renovate, just, mise
- **Created:** 2026-04-07

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->

- **2026-04-07 — CI lint fix (PR #651):** Squad framework files (`.squad/templates/`, `.copilot/skills/`, `.github/agents/`) are upstream-maintained and excluded from yamllint and markdownlint via `.yamllint.yaml` ignore and `.markdownlint-cli2.yaml` ignores. Active workflows in `.github/workflows/` are always linted — always add `---` doc start and quote shell variables. MD060 (table column style) disabled repo-wide since compact pipe tables are the norm here.
