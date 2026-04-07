# Work Routing

How to decide who handles what.

## Routing Table

| Work Type | Route To | Examples |
|-----------|----------|----------|
| Kubernetes apps | Clay | Add/modify apps in kubernetes/apps/, Helm values, app configs, HTTPRoutes |
| Kubernetes infra | Sonny | Cilium, democratic-csi, cert-manager, Velero, Prometheus, storage, networking |
| Talos cluster | Sonny | talconfig.yaml, node management, upgrades, schematics |
| CI/CD & pipelines | Ray | GitHub Actions, linting, validation workflows |
| Renovate config | Ray | Version groups, automerge, custom managers, commit messages |
| SOPS/secrets setup | Ray | .sops.yaml, secret-generator patterns, Age key management |
| Ansible/Proxmox | Ray | Playbooks, VM provisioning, DNS (bind9) |
| Toolchain | Ray | mise, just, editorconfig, yamllint, yamlfmt |
| ArgoCD bootstrap | Ray | Bootstrap applications, ArgoCD self-management |
| Secret safety | Blackburn | SOPS integrity, secret leakage review, `.decrypted~*` checks |
| Destructive actions | Blackburn | Review any `kubectl delete`, `talos reset`, `helm uninstall`, force-push |
| Security review | Blackburn | RBAC, network policies, operational safety gates |
| Architecture | Hayes | Cross-cutting decisions, system design, upgrade coordination |
| Code review | Hayes | Review PRs, check quality, enforce patterns |
| Scope & priorities | Hayes | What to build next, trade-offs, triage |
| Session logging | Scribe | Automatic — never needs routing |

## Issue Routing

| Label | Action | Who |
|-------|--------|-----|
| `squad` | Triage: analyze issue, assign `squad:{member}` label | Lead |
| `squad:{name}` | Pick up issue and complete the work | Named member |

### How Issue Assignment Works

1. When a GitHub issue gets the `squad` label, the **Lead** triages it — analyzing content, assigning the right `squad:{member}` label, and commenting with triage notes.
2. When a `squad:{member}` label is applied, that member picks up the issue in their next session.
3. Members can reassign by removing their label and adding another member's label.
4. The `squad` label is the "inbox" — untriaged issues waiting for Lead review.

## Rules

1. **Eager by default** — spawn all agents who could usefully start work, including anticipatory downstream work.
2. **Scribe always runs** after substantial work, always as `mode: "background"`. Never blocks.
3. **Quick facts → coordinator answers directly.** Don't spawn an agent for "what port does the server run on?"
4. **When two agents could handle it**, pick the one whose domain is the primary concern.
5. **"Team, ..." → fan-out.** Spawn all relevant agents in parallel as `mode: "background"`.
6. **Anticipate downstream work.** If a feature is being built, spawn the tester to write test cases from requirements simultaneously.
7. **Issue-labeled work** — when a `squad:{member}` label is applied to an issue, route to that member. The Lead handles all `squad` (base label) triage.
