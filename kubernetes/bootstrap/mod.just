set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

bootstrap_dir := source_directory()

# renovate: datasource=helm registryUrl=https://helm.cilium.io depName=cilium
_cilium_chart_version := "1.17.3"

# renovate: datasource=github-releases depName=kubernetes-sigs/gateway-api
_gateway_api_version := "v1.3.0"

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
default: cilium argocd apps

[doc('Install Cilium CNI via Helm (required before ArgoCD — nodes need CNI to become Ready)')]
[private]
cilium: (_require "helm" "kubectl")
    @echo "Installing Gateway API CRDs..."
    kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/{{ _gateway_api_version }}/standard-install.yaml
    kubectl apply --server-side -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/{{ _gateway_api_version }}/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml
    helm repo add cilium https://helm.cilium.io --force-update
    helm install cilium cilium/cilium \
      --version {{ _cilium_chart_version }} \
      --namespace kube-system \
      --wait --timeout 5m \
      --values {{ bootstrap_dir }}/../infra/cilium/values.yaml
    @echo "Waiting for Cilium agents to be ready..."
    kubectl wait --for=condition=ready pod \
      -l app.kubernetes.io/name=cilium-agent \
      -n kube-system --timeout=300s

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
