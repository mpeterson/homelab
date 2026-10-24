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
just validate               # Build manifests, validate backup policy, verify images
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

All tooling is managed by [mise](https://mise.jdx.dev/) (`.mise.toml`) — run `mise install` to bootstrap. Tasks use [just](https://just.systems/). Run `just` to discover all available recipes including submodules for Ansible, Talos, ArgoCD, bootstrap, linting, and validation.

### Ansible

Operational inventories live in the private sibling `homelab-private` repository. Use
`just ansible` to list the Ansible recipes. They default to the sibling inventory path;
set `ANSIBLE_INVENTORY` to use another file or directory.

```sh
just ansible install
just ansible inventory
just ansible nas
just ansible dns
```

### Talos node operations

When applying config to Talos nodes with `just talos apply <node>`, **wait for the node to return to `Ready` status** before proceeding to the next node. Verify with:

```sh
kubectl get nodes -w
```

See `talos/mod.just` for all Talos recipes (`genconfig`, `diff`, `apply`, `reset-node`, etc.).
Generation is offline and strictly validates every node before publishing private
output. Apply sends the same validated in-memory payload through `talosctl`,
requires exact-hostname confirmation, uses no-reboot mode, and checks sustained
Talos/Kubernetes health using native server-side `talosctl health` with explicit
node addresses and Kubernetes endpoint. Diffs report dry-run acceptance only;
do not expose raw diffs or rely on TOPF redaction.
Recovery recipes stay in Just and use existing client credentials without
machine generation or version gates. Verify workload
health separately before proceeding. Never bypass these gates or apply all nodes.
Run `just talos versions` and `just talos test` for secret-free generator checks.

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

Source of truth: `talos/topf.yaml`, compact native Talos documents/templates under
`talos/patches/`, and extension definitions under `talos/schematics/`, processed by
[TOPF](https://github.com/postfinance/topf). Patches merge global, role, then
per-node; filenames order patches within a layer.

The existing cluster secrets bundle remains `talos/talsecret.sops.yaml`; Tailscale
authentication is in `talos/patches/all/90-tailscale.sops.yaml`. The control-plane
encryption document references the existing Secretbox secret through vals and
must retain `key2` followed by `identity`. Never generate new cluster secrets.
Just recipes and the existing CLI tools enforce embedded TOPF/Talos compatibility
(including the Tuppr upgrade target), private output, and exact-node targeting.
The unconditional Talos CI job feeds the required `All validations passed` check.
Generated configs/client credentials belong only in ignored private directories,
never Git or CI artifacts.

Upgrades remain managed by Tuppr (`kubernetes/infra/tuppr/upgrades/`), not TOPF.
Do not advance Talos beyond TOPF's embedded supported machinery; new minor
contracts require an explicit compatibility review. Migration runbooks and
one-off comparison tools are private operational artifacts, not repository docs.

GPU workers `talos-01` and `talos-02` use NVIDIA Quadro P2000 (Pascal). They require the R580 LTS driver branch because R595+ is unsupported. Keep `siderolabs/nonfree-kmod-nvidia-lts` and `siderolabs/nvidia-container-toolkit-lts` on matching branches, and verify the resolved driver remains R580-compatible before every Talos upgrade.

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
- ExternalDNS annotations use the GA prefix `external-dns.kubernetes.io/` (v0.22+ default)
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
