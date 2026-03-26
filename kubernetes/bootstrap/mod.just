set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

bootstrap_dir := source_directory()

[private]
_require *tools:
    #!/usr/bin/env bash
    for tool in {{tools}}; do
      if ! command -v "$tool" &>/dev/null; then
        echo "Error: '$tool' is required but not installed." >&2
        exit 1
      fi
    done

[private]
default: argocd apps

[doc('Create SOPS age secret for ArgoCD')]
[private]
sops-age-secret: (_require "kubectl")
    cat ~/.config/sops/age/keys.txt \
      | kubectl -n argocd create secret generic sops-age \
          --from-file=keys.txt=/dev/stdin \
          --dry-run=client -o yaml \
      | kubectl apply --server-side -f -

[doc('Install ArgoCD via kustomize using upstream HA manifests')]
[private]
argocd: (_require "kubectl")
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
[private]
apps: (_require "kubectl")
    kubectl apply --server-side -f {{ bootstrap_dir }}/argocd/app.yaml
    kubectl apply --server-side -f {{ bootstrap_dir }}/infra.yaml
    kubectl apply --server-side -f {{ bootstrap_dir }}/apps.yaml
