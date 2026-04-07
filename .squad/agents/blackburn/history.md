# Project Context

- **Owner:** Michel Peterson
- **Project:** GitOps-managed Kubernetes homelab on Talos Linux (Proxmox VMs). ArgoCD reconciles from this repo. Three-tier hierarchy: bootstrap (ArgoCD self-management), infra (Cilium, democratic-csi, cert-manager, Velero, Prometheus, etc.), apps (media stack, Paperless, Kopia, Ollama, n8n, etc.). Ansible handles Proxmox provisioning. Managed with mise, just, Renovate, SOPS/KSOPS, GitHub Actions.
- **Stack:** Kubernetes, Talos Linux, ArgoCD, Helm, Kustomize, Cilium, SOPS/KSOPS, Ansible, GitHub Actions, Renovate, just, mise
- **Created:** 2026-04-07

## Critical Safety Context

Michel has experienced AI agents accidentally leaking SOPS secrets (reading decrypted files, committing plaintext) and performing destructive operations without approval. This role exists to prevent both categories of incident.

## Learnings

<!-- Append new learnings below. Each entry is something lasting about the project. -->
