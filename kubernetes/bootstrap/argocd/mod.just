set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

[doc('Identify and delete orphaned ArgoCD resources left behind by upgrades')]
prune:
    #!/usr/bin/env bash
    set -euo pipefail

    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    echo "==> Scanning for orphaned resources..."

    # Managed resources (authoritative: the ArgoCD self-managing Application)
    if ! argocd app resources argocd -o json --core \
         --kube-context "$(kubectl config current-context)" \
         > "$TMPDIR/managed.json" 2>/dev/null; then
      echo "ERROR: Cannot query ArgoCD."
      echo "  Ensure your kubeconfig context namespace is 'argocd':"
      echo "    kubectl config set-context --current --namespace=argocd"
      exit 1
    fi

    jq -r '.[] | "\(.kind)\t\(.name)\t\(.namespace // "")"' \
      "$TMPDIR/managed.json" | sort -u > "$TMPDIR/managed.txt"

    # Live namespaced resources (types likely to have orphans after upgrades)
    kubectl get \
      deploy,sts,ds,svc,cm,secret,sa,role,rolebinding,networkpolicy,hpa,pdb \
      -n argocd --no-headers \
      -o custom-columns='KIND:.kind,NAME:.metadata.name' 2>/dev/null \
      | awk '{printf "%s\t%s\targocd\n", $1, $2}' \
      | sort -u > "$TMPDIR/live.txt"

    # Live cluster-scoped ArgoCD resources
    for resource_type in clusterrole clusterrolebinding; do
      kubectl get "$resource_type" --no-headers \
        -o custom-columns='KIND:.kind,NAME:.metadata.name' 2>/dev/null \
        | grep -i argocd \
        | awk '{printf "%s\t%s\t\n", $1, $2}' \
        || true
    done | sort -u >> "$TMPDIR/live.txt"

    sort -u -o "$TMPDIR/live.txt" "$TMPDIR/live.txt"

    # Diff: live but not managed = orphaned
    ORPHANS=$(comm -23 "$TMPDIR/live.txt" "$TMPDIR/managed.txt" || true)

    # Filter out resources that are expected to be unmanaged
    ORPHANS=$(echo "$ORPHANS" \
      | grep -vE '^Secret\tsops-age\t' \
      | grep -vE '^Secret\targocd-redis\t' \
      | grep -v '^$' \
      || true)

    if [ -z "$ORPHANS" ]; then
      echo "No orphaned resources found."
      exit 0
    fi

    N=$(echo "$ORPHANS" | wc -l | tr -d ' ')
    echo ""
    echo "Found $N orphaned resource(s):"
    echo ""
    echo "$ORPHANS" | awk -F'\t' '{
      if ($3 != "") printf "  %s/%s (namespace: %s)\n", $1, $2, $3
      else printf "  %s/%s (cluster-scoped)\n", $1, $2
    }'
    echo ""
    read -rp "Delete these resources? [y/N] " REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 0
    fi

    echo ""
    echo "$ORPHANS" | while IFS=$'\t' read -r kind name ns; do
      if [ -n "$ns" ]; then
        echo "  Deleting $kind/$name in $ns..."
        kubectl delete "$kind" "$name" -n "$ns" --ignore-not-found
      else
        echo "  Deleting $kind/$name (cluster-scoped)..."
        kubectl delete "$kind" "$name" --ignore-not-found
      fi
    done
    echo ""
    echo "Done!"
