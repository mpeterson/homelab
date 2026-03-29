set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

repo_root := source_directory() / "../../.."

# renovate: datasource=docker depName=dagandersen/argocd-diff-preview
_argocd_diff_preview_version := "v0.2.2"
# renovate: datasource=helm registryUrl=https://argoproj.github.io/argo-helm depName=argo-cd
_argocd_chart_version := "9.4.17"

[private]
default:
    @just --unstable --list argocd

[private]
_require *tools:
    #!/usr/bin/env bash
    for tool in {{tools}}; do
      if ! command -v "$tool" &>/dev/null; then
        echo "Error: '$tool' is required but not installed." >&2
        exit 1
      fi
    done

[doc('Pause ArgoCD reconciliation for an application')]
pause app: (_require "kubectl")
    kubectl annotate application {{app}} -n argocd \
      argocd.argoproj.io/skip-reconcile="true" --overwrite
    @echo "ArgoCD reconciliation paused for '{{app}}'"

[doc('Resume ArgoCD reconciliation for an application')]
resume app: (_require "kubectl")
    kubectl annotate application {{app}} -n argocd \
      argocd.argoproj.io/skip-reconcile-
    @echo "ArgoCD reconciliation resumed for '{{app}}'"

[doc('Sync ArgoCD with pruning to remove orphaned resources')]
prune app="argocd": (_require "kubectl" "argocd")
    #!/usr/bin/env bash
    set -euo pipefail

    KCTX=$(kubectl config current-context)

    echo "==> Checking for orphaned resources..."

    ORPHANS=$(argocd app resources {{app}} --orphaned --core \
      --kube-context "$KCTX" 2>/dev/null \
      | tail -n +2) || {
      echo "ERROR: Cannot query ArgoCD."
      echo "  Ensure your kubeconfig context namespace is 'argocd':"
      echo "    kubectl config set-context --current --namespace=argocd"
      exit 1
    }

    if [ -z "$ORPHANS" ]; then
      echo "No orphaned resources found."
      exit 0
    fi

    echo "$ORPHANS"
    echo ""
    read -rp "Sync with pruning to remove these resources? [y/N] " REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi

    echo ""
    argocd app sync {{app}} --prune --core --kube-context "$KCTX"

[doc('Preview rendered manifest diff (ArgoCD) against base branch')]
diff base_branch="main": (_require "docker" "git")
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ repo_root }}"

    target_branch="${TARGET_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
    repo="${REPO:-$(git remote get-url origin | sed 's|.*github.com[:/]||;s|\.git$||')}"
    config_dir=".just"
    output_dir=".local/argocd-diff/$(date +%Y%m%d-%H%M%S)"

    base_dir=$(mktemp -d)
    target_dir=$(mktemp -d)
    argocd_config_dir=$(mktemp -d)
    trap 'rm -rf "$base_dir" "$target_dir" "$argocd_config_dir"' EXIT

    mkdir -p "$output_dir"

    echo "==> Preparing branches..."
    git archive "{{ base_branch }}" | tar -x -C "$base_dir"
    git archive HEAD | tar -x -C "$target_dir"
    cp "$config_dir/argocd-diff-preview-values.yaml" "$argocd_config_dir/values.yaml"

    echo "==> Running ArgoCD diff preview..."
    echo "    repo:           $repo"
    echo "    base branch:    {{ base_branch }}"
    echo "    target branch:  $target_branch"
    echo "    chart version:  {{ _argocd_chart_version }}"
    echo "    output:         $output_dir/"
    echo ""

    docker run --rm \
      --network=host \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$base_dir:/base-branch" \
      -v "$target_dir:/target-branch" \
      -v "$(pwd)/$output_dir:/output" \
      -v "$argocd_config_dir:/argocd-config" \
      -e TARGET_BRANCH="$target_branch" \
      -e REPO="$repo" \
      -e ARGOCD_CHART_NAME=argo-cd \
      -e ARGOCD_CHART_VERSION="{{ _argocd_chart_version }}" \
      "dagandersen/argocd-diff-preview:{{ _argocd_diff_preview_version }}"

    if [ -f "$output_dir/diff.md" ]; then
      echo ""
      echo "==> Diff written to $output_dir/diff.md"
    fi
