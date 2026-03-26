# Self-Managing ArgoCD Migration Plan

## Problem Statement

ArgoCD was installed manually via `kubectl apply -k hack/talos/test/` using raw upstream
HA manifests (v2.14.9) with kustomize patches. It manages everything else (infra + apps)
but **not itself**, meaning it never gets updated. The root Applications (`infra.yaml`,
`apps.yaml`) also live in `hack/talos/test/` and were manually applied.

This is the classic GitOps chicken-and-egg problem: the tool that enforces desired state
has no desired state defined for itself.

## Goal

Make ArgoCD self-managing so that:
1. ArgoCD manages its own installation via an ArgoCD Application
2. Renovate can propose version bumps via PR
3. Merging a version bump PR causes ArgoCD to upgrade itself automatically
4. A single justfile recipe can bootstrap a fresh cluster from scratch

## Approach

Following the [official ArgoCD self-management pattern](https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#manage-argo-cd-using-argo-cd)
and the [argoproj-deployments](https://github.com/argoproj/argoproj-deployments/tree/master/argocd)
reference implementation:

- **Keep kustomize-based manifests** — use the upstream ArgoCD HA manifests as a
  remote kustomize base with `?ref=` version pinning, applying patches on top.
  This is a natural evolution of the current `hack/talos/test/` setup.
- **Create a self-managing ArgoCD Application** with a **git source** pointing at
  the kustomize directory in this repo. ArgoCD watches git for changes and syncs
  itself — no parent Application or extra indirection needed.
- **Move bootstrap manifests** from `hack/talos/test/` into `kubernetes/bootstrap/argocd/`
- **Add a justfile bootstrap recipe** using `kubectl apply -k` (single source of truth)
- **Renovate detects `?ref=`** in kustomization.yaml remote resources and creates PRs

### Why Kustomize Instead of Helm

The original plan proposed switching to the argo-cd Helm chart. A multi-model review
(Opus 4.6, Sonnet 4.6, GPT-5.4) identified several critical issues with that approach:

1. **Broken update flow** — A Helm-sourced Application watches the Helm registry, not
   git. Renovate bumps `targetRevision` in `app.yaml`, but nothing applies that change
   to the cluster. A parent "meta-Application" would be needed as extra indirection.
2. **Live migration failure** — `helm upgrade --install` cannot adopt existing resources
   without Helm ownership metadata. SSA only helps ArgoCD's syncs, not the initial Helm
   install.
3. **Redis-ha password rotation loop** — ArgoCD renders Helm charts via `helm template`
   (no `lookup()`), so redis-ha generates a new random password on every sync, causing
   continuous restarts with `selfHeal: true`.

The kustomize-based approach eliminates all three issues:
- ArgoCD watches **git** directly — changes to `kustomization.yaml` trigger syncs
- Migration is **kustomize → kustomize** — SSA with `--force-conflicts` handles adoption
- No Helm templating — no `lookup()` / `randAlphaNum` password issues

## ArgoCD v2.14.9 → v3.3.4 Migration Assessment

The current installation runs ArgoCD v2.14.9. The latest stable release is v3.3.4.

Below is a per-version assessment of all breaking changes across the full upgrade path.

Sources:
- https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/2.14-3.0/
- https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/3.0-3.1/
- https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/3.1-3.2/
- https://argo-cd.readthedocs.io/en/stable/operator-manual/upgrading/3.2-3.3/

### v2.14 → v3.0

| Change | Impact | Details |
|--------|--------|---------|
| Fine-Grained RBAC | 🟢 None | Sub-resource permissions now required for update/delete. Single-admin homelab with `admin.enabled: true` — not affected. |
| Logs RBAC enforcement | 🟢 None | Explicit `logs, get` permission now required. Admin user has full access. |
| Legacy configManagementPlugins removed | 🟢 None | Our KSOPS uses init container + exec plugin, not the legacy CMP method. |
| Resource tracking default → annotation | 🟢 None | Already set to `annotation+label` explicitly. |
| Legacy repo credentials removed | 🟢 None | We use `repoURL` in Application specs, no repo secrets. |
| Dex SSO RBAC changes | 🟢 None | No Dex SSO configured. |
| ApplicationSet `applyNestedSelectors` | 🟢 None | No ApplicationSets used. |
| Metrics removed (`argocd_app_sync_status`, etc.) | 🟡 Low | If Prometheus dashboards monitor ArgoCD, update queries to use `argocd_app_info` labels instead. |
| **Default `resource.exclusions` expanded** | 🟡 Check | v3 ships a large `resource.exclusions` block in the upstream `argocd-cm` ConfigMap (Endpoints, EndpointSlice, Cilium, cert-manager, Kyverno, auth resources, etc.). The code-level `coreExcludedResources` only covers `events.k8s.io`, `metrics.k8s.io`, core `Event`, and `Lease`. Our `argocd-cm` patch must carry forward the full upstream exclusion list — kustomize replaces at the key level, not list level — and append the Velero exclusion. |
| **Helm 3.17.1 null values behavior** | ⚠️ **Confirmed breaking** | `null` values are now preserved instead of removed during Helm values merging. **democratic-csi apps use `null` extensively** for unused secrets (`provisioner-secret: null`, etc.) and zvol settings (`zvolCompression: null`, etc.). With the new Helm version bundled in ArgoCD v3.3.4 (Helm 3.19.4), these `null` keys produce: (1) **new empty Secret objects**, (2) **new `csi.storage.k8s.io/*-secret-*` parameters in StorageClasses** — but StorageClass `parameters` are **immutable in Kubernetes**, so ArgoCD will **fail to sync** democratic-csi apps. (3) Literal `null` values in driver config YAML. **Pre-migration fix required:** remove all `null` keys from `app-nfs.sops.yaml` and `app-iscsi.sops.yaml` — omit unused secret keys entirely (or use `secrets: {}`) and remove `zvolCompression`, `zvolDedup`, `zvolBlocksize` keys. This must be done **before** the ArgoCD upgrade while still on v2.14.9, so the rendered output is identical across both Helm versions. Validated by rendering democratic-csi chart 0.15.1 with Helm 3.17.3: the diff shows 6 new empty Secrets, 10 new StorageClass parameters, and 3 null driver config entries. |
| `resource.customizations.ignoreResourceUpdates` defaults | 🟢 Beneficial | v3 ignores `/status` changes on all resources by default, reducing unnecessary syncs. |

### v3.0 → v3.1

| Change | Impact | Details |
|--------|--------|---------|
| Symlink protection in `--staticassets` | 🟢 None | No custom static assets. |
| v1 Actions API deprecated | 🟢 None | No API automation. |
| PKCE flow handled by server | 🟢 None | No OIDC/PKCE configured. |
| Helm 3.18.4 | 🟢 None | No breaking changes per release notes. |
| Kustomize 5.7.0 | 🟢 None | No breaking changes per release notes. |

### v3.1 → v3.2

| Change | Impact | Details |
|--------|--------|---------|
| Source Hydrator paths must be non-root | 🟢 None | Source Hydrator not used. |
| Kustomize version in `.argocd-source.yaml` | 🟢 None | Informational — new feature. |
| CronJob health check added | 🟡 Low | If any apps deploy CronJobs, they may show `Degraded` if last job failed. Not blocking. |
| ApplicationSet status limited to 5000 | 🟢 None | No ApplicationSets. |

### v3.2 → v3.3

| Change | Impact | Details |
|--------|--------|---------|
| **ApplicationSet CRD exceeds client-side apply limit** | ⚠️ Critical | Self-managing ArgoCD **MUST** use `ServerSideApply=true` sync option, and bootstrap must use `kubectl apply --server-side`. Without it, `kubectl apply` fails with annotation size error. |
| Source Hydrator git notes | 🟢 None | Not used. |
| Application path cleaning removal | 🟢 None | Not used. |
| Cluster version format → `vMajor.Minor.Patch` | 🟢 None | No ApplicationSet cluster generators. |
| Anonymous Settings API fewer fields | 🟢 None | No anonymous API access. |
| **Kustomize 5.8.1 — shlex replacement for exec plugins** | 🟡 Check | Kustomize 5.7.1 replaced the `shlex` library for parsing exec plugin arguments. Could affect KSOPS exec plugin invocation. Low risk since KSOPS uses simple commands, but validate after migration. See [5.7.1 release notes](https://github.com/kubernetes-sigs/kustomize/releases/tag/kustomize%2Fv5.7.1). |
| Helm 3.19.4 — cluster version format | 🟢 None | Related to cluster version change above. |

### KSOPS Compatibility

The KSOPS setup (init container copying the `ksops` binary into the repo-server, with age
keys mounted from a `sops-age` secret) is **compatible** with ArgoCD v3.

**Important change from current setup:** The init container now copies only the `ksops`
binary, NOT kustomize. ArgoCD's bundled kustomize (5.8.1 in v3.3.4) is preserved. The
current setup replaces kustomize with whatever version ships in the `viaductoss/ksops`
image, which risks version mismatches. Verify after migration:

```bash
kubectl exec deploy/argocd-repo-server -n argocd -- kustomize version
# Should show v5.8.1
```

### Migration Risk Assessment

**Overall: Low**
- All RBAC/API/SSO breaking changes are non-applicable (single-admin homelab)
- The critical v3.3 ApplicationSet CRD issue is handled by `ServerSideApply=true`
- Migration is kustomize → kustomize (same tooling, updated remote base) — much
  lower risk than a kustomize → Helm migration
- SSA with `--force-conflicts` cleanly adopts existing resources
- The Kustomize shlex change is theoretical — KSOPS exec plugin is invoked as a simple
  binary with no complex arguments. All 15 SOPS generators in the repo use the standard
  `apiVersion: viaduct.ai/v1` / `kind: ksops` format with no special argument parsing.

### Post-Migration Validation

After the migration, verify KSOPS still works by forcing a sync on an app with SOPS secrets:

```bash
# Pick any app with a secret-generator.yaml (e.g., mosquitto)
argocd app sync mosquitto-configs --force
# Verify the secret was created
kubectl get secret -n mosquitto
```

If the secret is created correctly, KSOPS decryption is working. If it fails, the
kustomize 5.7.1 shlex change is the likely cause — check the repo-server logs and
refer to the [5.7.1 release notes](https://github.com/kubernetes-sigs/kustomize/releases/tag/kustomize%2Fv5.7.1).

### Recommendation

Go directly to v3.3.4 upstream manifests. Using an intermediate version would trigger
an immediate Renovate PR to upgrade anyway.
Validate KSOPS decryption works after migration before considering it done.

## New Directory Structure

```
kubernetes/bootstrap/
├── argocd/
│   ├── app.yaml                    # Self-managing ArgoCD Application (git source)
│   ├── kustomization.yaml          # Remote base + patches (the actual ArgoCD install)
│   ├── mod.just                    # Operational recipes (prune orphaned resources)
│   ├── namespace.yaml              # argocd namespace with pod-security label
│   └── patches/
│       ├── argocd-cm.yaml          # resource.exclusions, kustomize.buildOptions
│       ├── argocd-cmd-params-cm.yaml  # server.insecure
│       └── argocd-repo-server-ksops.yaml  # KSOPS init container + volumes
├── infra.yaml                      # Root infra Application (moved from hack/talos/test/)
├── apps.yaml                       # Root apps Application (moved from hack/talos/test/)
└── mod.just                        # Bootstrap recipes (module loaded from root justfile)
```

## Kustomization Design

The kustomization (`kubernetes/bootstrap/argocd/kustomization.yaml`) uses the upstream
ArgoCD HA cluster-install manifests as a remote base, pinned to a specific version via
`?ref=`. Patches are applied on top — a direct evolution of the current `hack/talos/test/`
setup.

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: argocd

resources:
  - namespace.yaml
  - https://github.com/argoproj/argo-cd//manifests/ha/cluster-install?ref=v3.3.4

patches:
  - path: patches/argocd-cm.yaml
    target:
      kind: ConfigMap
      name: argocd-cm
  - path: patches/argocd-cmd-params-cm.yaml
    target:
      kind: ConfigMap
      name: argocd-cmd-params-cm
  - path: patches/argocd-repo-server-ksops.yaml
    target:
      kind: Deployment
      name: argocd-repo-server
```

### namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
  labels:
    pod-security.kubernetes.io/enforce: privileged
```

### patches/argocd-cm.yaml

The `resource.exclusions` ConfigMap key is a **full replacement** — kustomize
strategic merge patches replace at the key level, not list level. The upstream
`argocd-cm` ships with a substantial `resource.exclusions` block covering
Endpoints, CiliumIdentity, cert-manager CertificateRequest, Kyverno, etc.
The code-level `coreExcludedResources` in `resources_filter.go` only covers
`events.k8s.io`, `metrics.k8s.io`, core `Event`, and `coordination.k8s.io/Lease`
— everything else is ConfigMap-only. Our patch must carry forward the full
upstream exclusion list and append Velero.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
data:
  application.resourceTrackingMethod: annotation+label
  kustomize.buildOptions: "--enable-alpha-plugins --enable-exec"
  resource.exclusions: |
    ### Network resources created by the Kubernetes control plane and excluded to reduce the number of watched events and UI clutter
    - apiGroups:
      - ''
      - discovery.k8s.io
      kinds:
      - Endpoints
      - EndpointSlice
    ### Internal Kubernetes resources excluded reduce the number of watched events
    - apiGroups:
      - coordination.k8s.io
      kinds:
      - Lease
    ### Internal Kubernetes Authz/Authn resources excluded reduce the number of watched events
    - apiGroups:
      - authentication.k8s.io
      - authorization.k8s.io
      kinds:
      - SelfSubjectReview
      - TokenReview
      - LocalSubjectAccessReview
      - SelfSubjectAccessReview
      - SelfSubjectRulesReview
      - SubjectAccessReview
    ### Intermediate Certificate Request excluded reduce the number of watched events
    - apiGroups:
      - certificates.k8s.io
      kinds:
      - CertificateSigningRequest
    - apiGroups:
      - cert-manager.io
      kinds:
      - CertificateRequest
    ### Cilium internal resources excluded reduce the number of watched events and UI Clutter
    - apiGroups:
      - cilium.io
      kinds:
      - CiliumIdentity
      - CiliumEndpoint
      - CiliumEndpointSlice
    ### Kyverno intermediate and reporting resources excluded reduce the number of watched events and improve performance
    - apiGroups:
      - kyverno.io
      - reports.kyverno.io
      - wgpolicyk8s.io
      kinds:
      - PolicyReport
      - ClusterPolicyReport
      - EphemeralReport
      - ClusterEphemeralReport
      - AdmissionReport
      - ClusterAdmissionReport
      - BackgroundScanReport
      - ClusterBackgroundScanReport
      - UpdateRequest
    ### Velero backup/restore resources excluded to avoid ArgoCD managing transient backup objects
    - apiGroups:
      - velero.io
      kinds:
      - Backup
      - Restore
      clusters:
      - "*"
```

### patches/argocd-cmd-params-cm.yaml

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cmd-params-cm
data:
  server.insecure: "true"
```

### patches/argocd-repo-server-ksops.yaml

Only the `ksops` binary is copied — ArgoCD's bundled kustomize (5.8.1 in v3.3.4) is
preserved. The current setup copies both kustomize and ksops from the `viaductoss/ksops`
image, which risks version mismatches.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: argocd-repo-server
spec:
  template:
    spec:
      volumes:
        - name: custom-tools
          emptyDir: {}
        - name: sops-age
          secret:
            secretName: sops-age
      initContainers:
        - name: install-ksops
          image: viaductoss/ksops:v4.3.3
          command: ["/bin/sh", "-c"]
          args:
            - echo "Installing KSOPS...";
              mv ksops /custom-tools/;
              echo "Done.";
          volumeMounts:
            - mountPath: /custom-tools
              name: custom-tools
      containers:
        - name: argocd-repo-server
          volumeMounts:
            - mountPath: /usr/local/bin/ksops
              name: custom-tools
              subPath: ksops
            - mountPath: /.config/sops/age/keys.txt
              name: sops-age
              subPath: keys.txt
          env:
            - name: XDG_CONFIG_HOME
              value: /.config
            - name: SOPS_AGE_KEY_FILE
              value: /.config/sops/age/keys.txt
```

### Notes on Changes From Current Patches

- **ClusterRoleBinding namespace patch removed** — The upstream `ha/cluster-install`
  kustomization sets `namespace: argocd` in its own base, and our top-level
  `namespace: argocd` ensures all namespaced resources are correct. The inline JSON
  patch from `hack/talos/test/` is no longer needed.
- **CiliumIdentity exclusion preserved** — v3's code-level `coreExcludedResources`
  does NOT include Cilium resources. CiliumIdentity, CiliumEndpoint, and
  CiliumEndpointSlice are excluded via the upstream `argocd-cm` ConfigMap's
  `resource.exclusions` block, which our patch carries forward in full along
  with all other upstream exclusions and the Velero addition.
- **KSOPS patch: kustomize copy removed** — Only `ksops` binary is copied. The
  `containers` section explicitly targets `argocd-repo-server` by name for the
  strategic merge patch.

## ArgoCD Application Design

The self-managing Application (`kubernetes/bootstrap/argocd/app.yaml`) uses a **git
source** pointing at the kustomize directory in this repo. ArgoCD watches git for
changes and syncs itself — no parent Application needed.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: argocd
  namespace: argocd
  # NOTE: No finalizer. Prevents accidental cascade-deletion of ArgoCD's
  # own resources if someone runs `kubectl delete application argocd`.
  # Without the finalizer, deleting the Application object orphans the
  # resources (ArgoCD keeps running) rather than tearing everything down.
spec:
  project: default
  source:
    repoURL: https://github.com/mpeterson/homelab
    path: kubernetes/bootstrap/argocd
    targetRevision: main

  destination:
    server: https://kubernetes.default.svc
    namespace: argocd

  # Ignore fields that are auto-generated by controllers/jobs and would
  # cause perpetual OutOfSync drift with selfHeal.
  # NOTE: argocd-redis Secret is auto-created at runtime by the secret-init
  # init container in argocd-redis-ha-haproxy. It is not in the rendered
  # manifests so ArgoCD does not track it — no ignoreDifferences needed.
  ignoreDifferences:
    - group: ""
      kind: Secret
      name: argocd-secret
      jsonPointers:
        - /data

  syncPolicy:
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
    automated:
      selfHeal: true
      prune: false  # Safety: never let ArgoCD prune its own resources
```

### Key Design Decisions

- **No finalizer** — Prevents accidental cascade-deletion. If someone runs
  `kubectl delete application argocd`, the Application object is removed but
  ArgoCD's deployments, services, etc. remain running. Re-apply `app.yaml` to
  restore self-management. This follows the pattern recommended for self-managing
  operators.
- **Git source, not Helm** — The Application watches `kubernetes/bootstrap/argocd`
  in git. When Renovate bumps the `?ref=` version in `kustomization.yaml` and the
  PR is merged, ArgoCD detects the git change and syncs itself. No parent
  Application or extra indirection needed.
- **`prune: false`** — Prevents ArgoCD from accidentally deleting its own resources.
  Trade-off: orphaned resources accumulate across upgrades. A periodic cleanup step
  is documented below.
- **`ServerSideApply=true`** — Required for v3.3 ApplicationSet CRD size limit, and
  allows clean adoption of existing resources during migration.
- **`ignoreDifferences`** — Prevents constant drift on the `argocd-secret`
  Secret (admin password/TLS certs auto-generated by ArgoCD). The upstream
  manifests define it as an empty `type: Opaque` Secret; ArgoCD populates
  `/data` at runtime. Without this entry, `selfHeal: true` would perpetually
  clear the data. The `argocd-redis` Secret is auto-created by the `secret-init`
  init container in the `argocd-redis-ha-haproxy` Deployment — it is not in
  the rendered manifests and not tracked by ArgoCD.
- **`app.yaml` is NOT in `kustomization.yaml`** — ArgoCD does not sync its own
  Application object. Changes to `app.yaml` (e.g., adding `ignoreDifferences`
  entries, changing `repoURL`) require running `just bootstrap apps` to take
  effect. This is intentional — including it would create a circular dependency.

## Bootstrap Flow

A `mod.just` module at `kubernetes/bootstrap/mod.just` provides the bootstrap recipes,
loaded from the root justfile via `mod bootstrap "kubernetes/bootstrap"`.

### Root justfile changes

```justfile
set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

mod bootstrap "kubernetes/bootstrap"

# ... existing recipes unchanged ...
```

### kubernetes/bootstrap/mod.just

```justfile
set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

bootstrap_dir := source_directory()

[private]
default: argocd apps

[doc('Create SOPS age secret for ArgoCD')]
[private]
sops-age-secret:
    cat ~/.config/sops/age/keys.txt \
      | kubectl -n argocd create secret generic sops-age \
          --from-file=keys.txt=/dev/stdin \
          --dry-run=client -o yaml \
      | kubectl apply --server-side -f -

[doc('Install ArgoCD via kustomize using upstream HA manifests')]
argocd:
    kubectl apply --server-side -f {{ bootstrap_dir }}/argocd/namespace.yaml
    just bootstrap sops-age-secret
    kubectl apply -k {{ bootstrap_dir }}/argocd \
      --server-side --force-conflicts
    @echo "Waiting for ArgoCD components..."
    kubectl wait --for=condition=available deployment/argocd-server \
      -n argocd --timeout=300s
    kubectl wait --for=condition=available deployment/argocd-repo-server \
      -n argocd --timeout=300s
    kubectl wait --for=condition=ready pod/argocd-application-controller-0 \
      -n argocd --timeout=300s

[doc('Apply bootstrap Applications')]
apps:
    kubectl apply --server-side -f {{ bootstrap_dir }}/argocd/app.yaml
    kubectl apply --server-side -f {{ bootstrap_dir }}/infra.yaml
    kubectl apply --server-side -f {{ bootstrap_dir }}/apps.yaml
```

Usage: `just bootstrap` runs the full sequence (private default chains
`argocd` → `apps`). Individual steps can be run with `just bootstrap argocd`,
`just bootstrap apps`, etc. All recipes are idempotent — safe to re-run on
partial failure.

### Bootstrap vs Steady-State

- **Bootstrap (fresh cluster):** `just bootstrap` runs `kubectl apply -k` to install
  ArgoCD from the kustomize manifests, then applies `app.yaml` to create the
  self-managing Application. ArgoCD detects the Application, renders the same
  kustomization, and confirms it's in sync.
- **Steady-state (updates):** Renovate bumps `?ref=v3.3.4` → `?ref=v3.4.0` in
  `kustomization.yaml`, PR is merged, ArgoCD detects the git change, re-renders the
  kustomization with the new upstream base, and syncs itself.
- **Re-bootstrap (existing cluster):** `just bootstrap` is idempotent. SSA with
  `--force-conflicts` adopts existing resources cleanly.

## Ongoing Update Flow

```
Renovate detects new ArgoCD release tag (e.g., v3.4.0)
  → Opens PR bumping ?ref= in kubernetes/bootstrap/argocd/kustomization.yaml
  → Renovate also detects new viaductoss/ksops image versions
  → PR reviewed and merged to main
  → ArgoCD detects git change in kubernetes/bootstrap/argocd/ on main branch
  → ArgoCD re-renders the kustomization with new upstream base
  → ArgoCD syncs — applies updated manifests via SSA
  → Rolling update of ArgoCD components
  → ArgoCD is now on the new version ✓
```

## Renovate Coverage

Renovate's `kustomize` manager auto-detects `kustomization.yaml` files and extracts
GitHub references with `?ref=` tags, using the `github-tags` datasource. The existing
`kubernetes` manager file pattern (`^kubernetes/.+\.ya?ml$`) covers the KSOPS init
container image in the patch file.

Add a grouping rule so ArgoCD version and KSOPS image updates come as a single PR
(avoids a window with potentially incompatible versions):

```json
{
  "description": "Group ArgoCD and KSOPS into a single PR",
  "matchFileNames": ["kubernetes/bootstrap/argocd/**"],
  "groupName": "argocd"
}
```

## Work Items

1. Create `kubernetes/bootstrap/argocd/kustomization.yaml` — kustomize overlay with
   upstream HA cluster-install as remote base, pinned to `?ref=v3.3.4`
2. Create `kubernetes/bootstrap/argocd/namespace.yaml` — argocd namespace with
   pod-security label
3. Create `kubernetes/bootstrap/argocd/patches/argocd-cm.yaml` — full upstream
   resource exclusions (Endpoints, Cilium, cert-manager, Kyverno, auth, etc.)
   plus Velero addition, resource tracking, kustomize opts
4. Create `kubernetes/bootstrap/argocd/patches/argocd-cmd-params-cm.yaml` —
   server.insecure
5. Create `kubernetes/bootstrap/argocd/patches/argocd-repo-server-ksops.yaml` — KSOPS
   init container (ksops binary only, no kustomize copy)
6. Create `kubernetes/bootstrap/argocd/app.yaml` — self-managing Application with git
   source, no finalizer
7. Move `infra.yaml` and `apps.yaml` from `hack/talos/test/` to `kubernetes/bootstrap/`.
   **Note:** the hack `apps.yaml` has `selfHeal: true` and `prune: true` but the live
   `apps` Application has `automated: {}` (no selfHeal, no prune). Update `apps.yaml`
   to match the live state to avoid changing behavior during migration.
8. Create `kubernetes/bootstrap/mod.just` with bootstrap recipes
9.  Update root `justfile` — add `mod bootstrap`, `set quiet`, `set shell`
10. Add Renovate grouping rule for ArgoCD + KSOPS in `renovate.json`
11. Leave `hack/talos/test/` untouched — it's gitignored and serves as a local
    rollback path at no cost
12. Update README.md with new bootstrap instructions
13. Create `kubernetes/bootstrap/argocd/mod.just` — operational ArgoCD recipes
    (`just argocd prune`) for identifying and cleaning orphaned resources after
    upgrades. Loads as a separate `mod argocd` in the root justfile.

## Execution Phases

The migration is split into two phases to isolate risk.

### Phase 1 — Commit new files (zero cluster risk)

Create a branch, commit work items 1–13, merge to main. **Nothing changes on the
cluster** — ArgoCD doesn't know about `kubernetes/bootstrap/` and won't sync it.

This phase includes:
- All new files under `kubernetes/bootstrap/argocd/`
- Moving `infra.yaml` and `apps.yaml` to `kubernetes/bootstrap/`
- `mod.just`, root justfile changes, Renovate rule, README

After merge, run the Local Validation checks below to confirm `kustomize build`
produces correct output.

### Phase 2 — Apply to cluster (the actual migration)

This is the only moment with real risk (~2 minute window). Run manually:

```bash
just bootstrap
```

This runs: `namespace.yaml` → `sops-age-secret` → `kubectl apply -k` (installs
ArgoCD v3.3.4) → wait for components → apply `app.yaml` + root Applications.

**Immediately after ArgoCD comes up:**

1. Verify the ArgoCD UI is accessible
2. Run the KSOPS validation:
   ```bash
   argocd app sync mosquitto-configs --force
   kubectl get secret -n mosquitto
   ```
3. Check for perpetual OutOfSync:
   ```bash
   argocd app get argocd
   ```

**If anything fails** — roll back immediately:
```bash
kubectl apply -k hack/talos/test/ --server-side --force-conflicts
kubectl delete application argocd -n argocd --ignore-not-found
```

Workloads are **unaffected** during the entire process — ArgoCD being down only
means sync operations pause. No pods are restarted, no storage is touched.

## Local Validation

After creating the files (work items 1–6) and before touching the live cluster,
run `kustomize build` locally to validate the manifests. This catches patch
targeting errors, YAML syntax issues, and merge conflicts without cluster access.

```bash
kustomize build kubernetes/bootstrap/argocd/ > /tmp/argocd-build-output.yaml
```

Then verify key properties of the rendered output:

```bash
# 1. Resource count — expect ~71 resources (may vary slightly across versions)
grep -c '^kind:' /tmp/argocd-build-output.yaml

# 2. argocd-cm patch applied — must show Velero AND upstream exclusions
python3 -c "
import yaml
docs = list(yaml.safe_load_all(open('/tmp/argocd-build-output.yaml')))
for d in docs:
    if d and d.get('kind') == 'ConfigMap' and d['metadata']['name'] == 'argocd-cm':
        data = d.get('data', {})
        excl = yaml.safe_load(data.get('resource.exclusions', '')) or []
        groups = [g for r in excl for g in r.get('apiGroups', [])]
        assert 'velero.io' in groups, 'Velero exclusion missing'
        assert 'cilium.io' in groups, 'Cilium exclusion missing'
        assert 'cert-manager.io' in groups, 'cert-manager exclusion missing'
        assert data.get('kustomize.buildOptions') == '--enable-alpha-plugins --enable-exec'
        # Verify upstream ignoreResourceUpdates keys not clobbered
        assert any('ignoreResourceUpdates' in k for k in data), 'upstream ignoreResourceUpdates keys lost'
        print(f'argocd-cm: {len(excl)} exclusion rules, {len(data)} data keys ✓')
        break
"

# 3. KSOPS patch applied — install-ksops init container + volumes
python3 -c "
import yaml
docs = list(yaml.safe_load_all(open('/tmp/argocd-build-output.yaml')))
for d in docs:
    if d and d.get('kind') == 'Deployment' and d['metadata']['name'] == 'argocd-repo-server':
        spec = d['spec']['template']['spec']
        init_names = [ic['name'] for ic in spec.get('initContainers', [])]
        vol_names = [v['name'] for v in spec.get('volumes', [])]
        assert 'install-ksops' in init_names, 'install-ksops init container missing'
        assert 'custom-tools' in vol_names, 'custom-tools volume missing'
        assert 'sops-age' in vol_names, 'sops-age volume missing'
        for c in spec['containers']:
            if c['name'] == 'argocd-repo-server':
                mounts = {vm['mountPath'] for vm in c.get('volumeMounts', [])}
                assert '/usr/local/bin/ksops' in mounts, 'ksops mount missing'
                assert '/.config/sops/age/keys.txt' in mounts, 'sops-age mount missing'
        print(f'repo-server: {len(init_names)} init containers, {len(vol_names)} volumes ✓')
        break
"

# 4. All namespaced resources have namespace: argocd
python3 -c "
import yaml
CLUSTER_SCOPED = {'Namespace','ClusterRole','ClusterRoleBinding','CustomResourceDefinition'}
docs = list(yaml.safe_load_all(open('/tmp/argocd-build-output.yaml')))
wrong = [f'{d[\"kind\"]}/{d[\"metadata\"][\"name\"]}' for d in docs
         if d and d['kind'] not in CLUSTER_SCOPED and d['metadata'].get('namespace') != 'argocd']
assert not wrong, f'Wrong namespace: {wrong}'
print('All namespaced resources have namespace: argocd ✓')
"

# 5. argocd-secret exists (needed for ignoreDifferences)
python3 -c "
import yaml
docs = list(yaml.safe_load_all(open('/tmp/argocd-build-output.yaml')))
found = any(d and d.get('kind') == 'Secret' and d['metadata']['name'] == 'argocd-secret' for d in docs)
assert found, 'argocd-secret not found — ignoreDifferences will have no target'
print('argocd-secret present ✓')
"

# 6. No duplicate resources
python3 -c "
import yaml
from collections import Counter
docs = list(yaml.safe_load_all(open('/tmp/argocd-build-output.yaml')))
keys = [f'{d[\"kind\"]}/{d[\"metadata\"][\"name\"]}' for d in docs if d]
dupes = [k for k, v in Counter(keys).items() if v > 1]
assert not dupes, f'Duplicate resources: {dupes}'
print(f'{len(keys)} resources, no duplicates ✓')
"

rm /tmp/argocd-build-output.yaml
```

If all checks pass, the kustomization is structurally correct and ready for
`kubectl apply -k --server-side --dry-run=server` against the live cluster.

## Pre-Migration Steps

Before running the migration on the live cluster:

1. **Fix democratic-csi null values** — see [`docs/democratic-csi-null-fix.md`](democratic-csi-null-fix.md)
   for full details. Must be completed and synced on v2.14.9 **before** the
   ArgoCD upgrade. Verify no nulls remain:
   ```bash
   SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops decrypt \
     kubernetes/infra/democratic-csi/app-nfs.sops.yaml | grep -c 'null'
   # Expected: 0
   SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops decrypt \
     kubernetes/infra/democratic-csi/app-iscsi.sops.yaml | grep -c 'null'
   # Expected: 0
   ```

2. **Verify local `hack/talos/test/` manifests exist** — these files are gitignored
   and serve as the rollback path. Confirm they're present before proceeding:
   ```bash
   ls hack/talos/test/kustomization.yaml
   ```
3. **Back up current ArgoCD state:**
   ```bash
   # Full resource backup (all types, not just `kubectl get all`)
   kubectl get deploy,sts,svc,cm,secret,sa,role,rolebinding,clusterrole,\
   clusterrolebinding,networkpolicy,hpa,pdb -n argocd -o yaml \
     > argocd-pre-migration-backup.yaml
   kubectl get crd applications.argoproj.io appprojects.argoproj.io \
     applicationsets.argoproj.io -o yaml > argocd-crds-backup.yaml
   ```
4. **Inventory current resources** (to identify orphans later):
   ```bash
   # Namespaced resources
   kubectl api-resources --verbs=list --namespaced -o name \
     | xargs -I{} kubectl get {} -n argocd -o name 2>/dev/null \
     | sort > argocd-resources-before.txt
   # Cluster-scoped resources (ClusterRoles, ClusterRoleBindings, CRDs)
   kubectl get clusterrole,clusterrolebinding -o name \
     | grep argocd | sort >> argocd-resources-before.txt
   kubectl get crd -o name \
     | grep argoproj | sort >> argocd-resources-before.txt
   ```

## Post-Migration Steps

After the migration:

1. **Verify KSOPS decryption:**
   ```bash
   argocd app sync mosquitto-configs --force
   kubectl get secret -n mosquitto
   ```
2. **Verify kustomize version:**
   ```bash
   kubectl exec deploy/argocd-repo-server -n argocd -- kustomize version
   ```
3. **Identify orphaned resources** from the old raw-manifest HA install. Resource
   names may differ between v2 and v3 manifests. Compare with pre-migration inventory:
   ```bash
   # Namespaced resources
   kubectl api-resources --verbs=list --namespaced -o name \
     | xargs -I{} kubectl get {} -n argocd -o name 2>/dev/null \
     | sort > argocd-resources-after.txt
   # Cluster-scoped resources
   kubectl get clusterrole,clusterrolebinding -o name \
     | grep argocd | sort >> argocd-resources-after.txt
   kubectl get crd -o name \
     | grep argoproj | sort >> argocd-resources-after.txt
   diff argocd-resources-before.txt argocd-resources-after.txt
   ```
   Delete orphans that are no longer managed. Review each before deleting:
   ```bash
   # Example — actual orphans will depend on the diff output
   kubectl delete deployment argocd-redis -n argocd --ignore-not-found
   kubectl delete service argocd-redis -n argocd --ignore-not-found
   ```
4. **Verify ArgoCD Application is not perpetually OutOfSync** — check the ArgoCD
   UI or `argocd app get argocd` for drift. If `ignoreDifferences` needs tuning,
   add entries for the drifting fields.

## Periodic Maintenance

Since the self-managing Application uses `prune: false`, orphaned resources may
accumulate across upgrades. Use `just argocd prune` to find and clean them:

```bash
just argocd prune
```

This compares live resources in the `argocd` namespace (and cluster-scoped
ArgoCD resources) against what the ArgoCD Application manages. Orphaned
resources are displayed and deletion requires explicit confirmation.

Resources that are expected to be unmanaged (e.g., the `sops-age` Secret,
the `argocd-redis` Secret) are automatically excluded.

## Rollback Procedure

If the migration fails and ArgoCD is non-functional:

1. **Re-apply the old kustomize manifests** (still in gitignored `hack/talos/test/`):
   ```bash
   kubectl apply -k hack/talos/test/ --server-side --force-conflicts
   ```
2. **Restore CRDs if needed** (v2→v3 CRD backward compatibility is not guaranteed):
   ```bash
   kubectl apply --server-side --force-conflicts -f argocd-crds-backup.yaml
   ```
3. **Re-create SOPS secret:**
   ```bash
   cat ~/.config/sops/age/keys.txt \
     | kubectl -n argocd create secret generic sops-age \
         --from-file=keys.txt=/dev/stdin --dry-run=client -o yaml \
     | kubectl apply --server-side -f -
   ```
4. **Clean up the self-managing Application** (if it was created):
   ```bash
   kubectl delete application argocd -n argocd --ignore-not-found
   ```
5. **Remove v3-only orphaned resources** — SSA re-applies v2 manifests but does NOT
   delete resources absent from them. Diff the pre-migration inventory against the
   rolled-back state and delete v3-only resources:
   ```bash
   # Namespaced resources
   kubectl api-resources --verbs=list --namespaced -o name \
     | xargs -I{} kubectl get {} -n argocd -o name 2>/dev/null \
     | sort > argocd-resources-rollback.txt
   # Cluster-scoped resources
   kubectl get clusterrole,clusterrolebinding -o name \
     | grep argocd | sort >> argocd-resources-rollback.txt
   kubectl get crd -o name \
     | grep argoproj | sort >> argocd-resources-rollback.txt
   # Resources in rollback but not in pre-migration are v3-only leftovers
   comm -13 argocd-resources-before.txt argocd-resources-rollback.txt
   # Review each and delete as appropriate
   ```

> **Note:** CRD backward compatibility across v2→v3 is not guaranteed. Test the
> rollback procedure on a disposable cluster first.

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| ArgoCD restarts during v2→v3 upgrade (~1-2 min) | No workloads affected; only sync operations pause briefly |
| Resource adoption conflicts during migration | SSA with `--force-conflicts` handles field manager conflicts |
| ArgoCD accidentally prunes itself | `prune: false` on self-management Application |
| Accidental cascade-deletion via `kubectl delete application argocd` | No finalizer on self-managing Application — deletion orphans resources instead of tearing down ArgoCD |
| Orphaned resources from old HA manifests | Pre/post migration inventory + manual cleanup |
| Constant drift on auto-generated fields | `ignoreDifferences` for `argocd-secret` `/data` (admin password/TLS certs populated at runtime). `argocd-redis` Secret is auto-created by the `secret-init` init container in the upstream HA manifests |
| GitHub outage blocks remote kustomize base renders | ArgoCD continues running; only sync-compare operations fail. Repo-server caches last successful render. Acceptable for homelab |
| `app.yaml` changes in git have no automatic effect | `app.yaml` is excluded from `kustomization.yaml` by design; changes require `just bootstrap apps` |
| CRD backward incompatibility on rollback | Pre-migration CRD backup + git tag; test rollback on disposable cluster |
| KSOPS decryption failure after upgrade | Post-migration validation step; only `ksops` binary copied (ArgoCD's kustomize preserved) |
| `prune: false` accumulates orphaned resources | Periodic maintenance procedure documented |
| ArgoCD + KSOPS version mismatch via Renovate | Renovate grouping rule bundles both into single PR |
| Helm 3.17.1+ null-value change breaks democratic-csi StorageClasses | Pre-migration fix: remove all `null` keys from democratic-csi SOPS values (see `docs/democratic-csi-null-fix.md`) |
