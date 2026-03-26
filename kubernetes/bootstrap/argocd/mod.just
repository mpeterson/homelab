set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

[doc('Sync ArgoCD with pruning to remove orphaned resources left behind by upgrades')]
prune:
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
