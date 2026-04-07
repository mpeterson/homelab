# Squad Decisions

## Active Decisions

### 2026-04-07T09:27:47Z: User directive — Operational safety
**By:** Michel Peterson (via Copilot)
**What:** Never perform destructive operations (kubectl delete, talos reset, helm uninstall, git push --force, argocd app delete, etc.) without explicit user approval. AI agents have previously gone too autonomous and performed destructive actions against the cluster and VMs. All agents must ask before any action that could cause data loss or downtime.
**Why:** User request — critical safety rule based on past incidents

### 2026-04-07T09:27:47Z: User directive — SOPS secret protection
**By:** Michel Peterson (via Copilot)
**What:** Never read, output, log, or commit SOPS-encrypted secret contents in plaintext. Never stage .decrypted~*.sops.yaml files. Never use git add -A. AI agents have previously leaked secrets by reading decrypted SOPS files or accidentally committing them in plain text.
**Why:** User request — critical security rule based on past incidents

### 2026-04-07T11:29:00Z: Lint Exclusions for Squad Framework Files
**By:** Ray (Ops Engineer)
**What:** Upstream Squad framework files are excluded from linting:
- **yamllint:** `.squad/templates/**` added to `.yamllint.yaml` ignore list
- **markdownlint:** `.squad/templates/**/*.md`, `.copilot/skills/**/*.md`, `.github/agents/**/*.md` excluded via `.markdownlint-cli2.yaml`
- **MD060 (table column style):** Disabled repo-wide in `.markdownlint.yaml` — compact pipe tables are standard here
**Why:** Squad framework files are generated/maintained upstream, not this repo. Linting them creates noise we can't fix upstream. Active workflows in `.github/workflows/` remain fully linted.
**Impact:** If Squad upgrades introduce new template files, they'll automatically be excluded. Squad config files in `.squad/` root (team.md, routing.md, etc.) are still linted.

## Governance

- All meaningful changes require team consensus
- Document architectural decisions here
- Keep history focused on work, decisions focused on direction
