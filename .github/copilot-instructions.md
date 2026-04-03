# Copilot Instructions

> **Keep this file up to date.** When a PR changes conventions, structure, commands, or
> patterns described here, update this file as part of the same PR.

## Workflow

**Never perform destructive operations without explicit approval.** This includes
`kubectl delete`, `talos reset`, `helm uninstall`, force-pushes, deleting files/resources,
or anything that could cause data loss or downtime. Always ask first.

All changes go through a PR. **Before making any changes**, create a feature branch from
latest `origin/main`. Make all changes on that branch. Push and open a PR (with `gh pr create`)
before marking the task complete. Before pushing, run locally:

```sh
just lint                   # Lint YAML, JSON, Actions, Markdown, Renovate config
just validate               # Build Kustomize overlays, template Helm charts, verify images
```

This catches most CI failures before they hit the PR. Run `just` to list all available commands and submodules.

Use `gh` for all GitHub operations (PRs, issues, labels, etc.).

### Creating issues

Always apply relevant labels. Use `gh label list` to see current labels. The repo uses:

- **Area labels** (`area/kubernetes`, `area/talos`, `area/ansible`, `area/ci`, `area/docs`)
- **Priority labels** (`priority/high`, `priority/medium`, `priority/low`)
- Common types: `bug`, `enhancement`, `documentation`

Every issue should have at least one area and one priority label.

### Pull requests

Keep PR descriptions up to date as the PR evolves. The description should only describe
**what the PR changes and why** — not the conversation, task context, or decisions that
led to it. Update the description whenever commits are added or the scope shifts.

### Code comments

Keep comments minimal and factual. Explain *what* non-obvious code does, not the
decision process behind it. Do not include rationale from conversations or planning.

## Commands

All tooling is managed by [mise](https://mise.jdx.dev/) (`.mise.toml`) — run `mise install` to bootstrap. Tasks use [just](https://just.systems/). Run `just` to discover all available recipes including submodules for Talos, ArgoCD, bootstrap, linting, and validation.

### Talos node operations

When applying config to Talos nodes with `just talos apply <node>`, **wait for the node to return to `Ready` status** before proceeding to the next node. Verify with:

```sh
kubectl get nodes -w
```

See `talos/mod.just` for all Talos recipes (`genconfig`, `diff`, `apply`, `reset-node`, etc.).

## Architecture

This is a GitOps-managed Kubernetes homelab running on Talos Linux VMs (Proxmox). ArgoCD watches this repo and reconciles cluster state automatically.

### Deployment pipeline

1. Changes committed → GitHub Actions lint/validate on PR
2. ArgoCD diff preview posted as PR comment
3. PR merged → ArgoCD detects change → reconciles cluster

### Three-tier ArgoCD hierarchy

- **`kubernetes/bootstrap/`** — ArgoCD self-management + root Applications
- **`kubernetes/infra/`** — Infrastructure services (CNI, storage, monitoring, etc.)
- **`kubernetes/apps/`** — Application workloads

Each tier's `kustomization.yaml` lists all `app.yaml` files as resources. Browse the directories to see current apps and infra components.

### Talos cluster management

Source of truth: `talos/talconfig.yaml` (processed by [talhelper](https://github.com/budimanjojo/talhelper)). Check that file for current node topology, schematics, and extensions.

Secrets in `talos/talsecret.sops.yaml` and `talos/talenv.sops.yaml`. Upgrades managed by Tuppr operator (`kubernetes/infra/tuppr/upgrades/`).

### Ansible

`ansible/` handles Proxmox VM provisioning and DNS (bind9 submodule). Not used for in-cluster config.

## Conventions

### Kubernetes app structure

Every app follows the **single-app Kustomize+Helm pattern**:

```text
kubernetes/{apps,infra}/{name}/
├── app.yaml                # ArgoCD Application (single, git source)
├── kustomization.yaml      # helmCharts + configMapGenerator + KSOPS generators
├── values.yaml             # Helm values (extracted from app.yaml)
├── secret-generator.yaml   # KSOPS generator (if secrets needed)
├── secret.sops.yaml        # SOPS-encrypted Secret (if secrets needed)
└── config/                 # App-specific config files (if any)
```

When adding a new app, follow an existing app in the same tier as a template. Look at a few `app.yaml` and `kustomization.yaml` files to see the current conventions.

**Key patterns:**

- Each app has ONE ArgoCD Application pointing to its git directory
- `kustomization.yaml` renders the Helm chart via `helmCharts:` directive AND generates ConfigMaps/Secrets
- Helm values live in `values.yaml` (not inline in app.yaml)
- `namespace: &ns <namespace>` at the top of `kustomization.yaml` with `namespace: *ns` in helmCharts (required for Kustomize nameReference rewriting)
- `disableNameSuffixHash` is NOT used — hash suffixes enable automatic rolling updates on config changes
- `spec.info` in app.yaml shows Chart and Image versions with `# renovate:` comments for automatic tracking
- Routing uses Gateway API `HTTPRoute` (Cilium), not Ingress
- Container images are pinned with digest: `repository/image:tag@sha256:...`
- New apps must be added to the tier's root `kustomization.yaml`
- Most apps use the bjw-s `app-template` chart; some infra apps use dedicated charts

### Secrets (SOPS + KSOPS)

- Encrypted with Age. Key at `~/.config/sops/age/keys.txt`
- `.sops.yaml` defines which fields stay unencrypted (check that file for the current list)
- KSOPS generator in each app's `kustomization.yaml` decrypts at ArgoCD sync time
- **Never commit unencrypted secrets** — CI gate validates SOPS integrity on every PR
- Add `kustomize.config.k8s.io/needs-hash: "true"` annotation to Secret manifests inside SOPS files for hash-based rolling updates
- **Do NOT use `needs-hash`** on secrets referenced by CRDs or by OTHER ArgoCD Applications (cross-app refs) — Kustomize can only rewrite references within the same kustomization

### Renovate automation

Configured in `renovate.json5` + `.renovate/` modules. Check those files for current:

- **Version groups** (`.renovate/groups.json5`): Which components must update together
- **Automerge tiers** (`.renovate/autoMerge.json5`): Which apps automerge vs. require manual review
- **Custom managers** (`.renovate/customManagers.json5`): Version tracking in non-standard locations (including `spec.info` image/chart versions in `app.yaml` files)
- **Commit messages** (`.renovate/commitMessage.json5`): Conventional commit format by update type

### YAML style

- 2-space indentation, UTF-8, LF line endings
- Document start marker (`---`) required
- Line length: unlimited (long lines common in K8s manifests)
- Config: `.yamllint.yaml`, `.yamlfmt.yaml`, `.editorconfig`

### Just recipes

- Modular: `.justfile` imports submodules — check `mod` declarations in `.justfile` for the full list
- All recipes use `set shell := ['bash', '-euo', 'pipefail', '-c']`
- Recipes detect `GITHUB_ACTIONS` env var to switch output formatting
