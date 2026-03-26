set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

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
prune: (_require "kubectl" "argocd")
    #!/usr/bin/env bash
    set -euo pipefail

    KCTX=$(kubectl config current-context)

    echo "==> Checking for orphaned resources..."

    ORPHANS=$(argocd app resources argocd --orphaned --core \
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
    argocd app sync argocd --prune --core --kube-context "$KCTX"
