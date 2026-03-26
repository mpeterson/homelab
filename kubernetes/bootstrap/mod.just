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
