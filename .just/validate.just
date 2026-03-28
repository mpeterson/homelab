set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

repo_root := source_directory() / ".."

[doc('Run all validation checks')]
[private]
default:
    @echo "==> Validating Kustomize overlays..."
    @just validate kustomize
    @echo ""
    @echo "==> Validating Helm charts..."
    @just validate helm
    @echo ""
    @echo "==> Verifying container images..."
    @just validate images

[private]
_error file msg:
    #!/usr/bin/env bash
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "::error file={{file}}::{{msg}}"
    else
      echo -e "\033[1;31mERROR:\033[0m {{msg}} (\033[33m{{file}}\033[0m)"
    fi

[doc('Validate Kustomize overlays and sub-directory builds')]
kustomize:
    #!/usr/bin/env bash
    set -euo pipefail
    mise install --quiet
    cd "{{ repo_root }}"
    status=0

    # Work on a temporary copy to avoid modifying the repo
    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' EXIT
    cp -a kubernetes/ "$workdir/kubernetes/"

    echo "Apps..."
    if ! kustomize build "$workdir/kubernetes/apps/" > /dev/null; then
      just validate _error "kubernetes/apps/kustomization.yaml" "kustomize build failed for kubernetes/apps"
      status=1
    fi

    echo "Infra..."
    yq -i 'del(.generators)' "$workdir/kubernetes/infra/kustomization.yaml"
    if ! kustomize build "$workdir/kubernetes/infra/" > /dev/null; then
      just validate _error "kubernetes/infra/kustomization.yaml" "kustomize build failed for kubernetes/infra"
      status=1
    fi

    echo "Sub-directories..."
    while IFS= read -r kust_file; do
      dir=$(dirname "$kust_file")
      rel_dir="${dir#$workdir/}"

      case "$rel_dir" in
        kubernetes/apps|kubernetes/infra|kubernetes/bootstrap|kubernetes/bootstrap/argocd) continue ;;
      esac

      if yq -e '.generators' "$kust_file" > /dev/null 2>&1; then
        yq -i 'del(.generators)' "$kust_file"
      fi

      # Skip kustomizations that only had generators
      has_content=$(yq '.resources // [] | length' "$kust_file" 2>/dev/null)
      has_configmaps=$(yq '.configMapGenerator // [] | length' "$kust_file" 2>/dev/null)
      if [ "${has_content:-0}" = "0" ] && [ "${has_configmaps:-0}" = "0" ]; then
        continue
      fi

      echo "  $rel_dir ..."
      if ! kustomize build "$dir" > /dev/null 2>&1; then
        just validate _error "$rel_dir/kustomization.yaml" "kustomize build failed for $rel_dir"
        kustomize build "$dir" 2>&1 || true
        status=1
      fi
    done < <(find "$workdir/kubernetes/apps" "$workdir/kubernetes/infra" -name 'kustomization.yaml' -type f)

    exit "$status"

[doc('Validate Helm chart values for all ArgoCD Applications')]
helm:
    #!/usr/bin/env bash
    set -euo pipefail
    mise install --quiet
    cd "{{ repo_root }}"
    status=0

    while IFS= read -r file; do
      doc_count=$(yq 'document_index' "$file" | tail -1)
      doc_count=$((doc_count + 1))

      for ((i=0; i<doc_count; i++)); do
        kind=$(yq "select(document_index == $i) | .kind // \"\"" "$file")
        chart=$(yq "select(document_index == $i) | .spec.source.chart // \"\"" "$file")

        if [ "$kind" != "Application" ] || [ -z "$chart" ] || [ "$chart" = "null" ]; then
          continue
        fi

        app_name=$(yq "select(document_index == $i) | .metadata.name // \"unknown\"" "$file")
        repo_url=$(yq "select(document_index == $i) | .spec.source.repoURL" "$file")
        version=$(yq "select(document_index == $i) | .spec.source.targetRevision" "$file")
        has_values=$(yq "select(document_index == $i) | .spec.source.helm.valuesObject // \"\"" "$file")

        echo "  ${app_name} (${chart}@${version}) ..."

        helm_cmd=(helm template "$app_name" "$chart" --repo "$repo_url" --version "$version")

        values_file=$(mktemp)
        if [ -n "$has_values" ] && [ "$has_values" != "null" ]; then
          yq --yaml-fix-merge-anchor-to-spec "explode(.) | select(document_index == $i) | .spec.source.helm.valuesObject" "$file" > "$values_file"
          helm_cmd+=(-f "$values_file")
        fi

        err_file=$(mktemp)
        if ! "${helm_cmd[@]}" > /dev/null 2>"$err_file"; then
          just validate _error "$file" "Helm template failed for ${app_name} (${chart}@${version})"
          cat "$err_file"
          status=1
        fi

        rm -f "$values_file" "$err_file"
      done
    done < <(find kubernetes/ -name '*.yaml' -not -name '*.sops.yaml' -not -path '*/bootstrap/*' -type f)

    exit "$status"

[doc('Verify all container images exist in their registries')]
images:
    #!/usr/bin/env bash
    set -euo pipefail
    mise install --quiet
    cd "{{ repo_root }}"
    status=0

    echo "Extracting images..."
    images=$(find kubernetes/ -name '*.yaml' -not -name '*.sops.yaml' -type f -exec \
      yq -N '.. | select(has("repository") and has("tag")) | .repository + ":" + (.tag | tostring)' {} + 2>/dev/null \
      | sort -u \
      | grep -v '^:$' \
      | grep -v '^null:' \
      | grep -v '^\*' \
      || true)

    if [ -z "$images" ]; then
      echo "No images found."
      exit 0
    fi

    count=$(echo "$images" | wc -l | tr -d ' ')
    echo "Checking $count images..."

    parallel_count=0
    pids=()

    while IFS= read -r image; do
      image_ref="${image%%@sha256:*}"
      expected_sha="${image#*@}"

      (
        if ! actual_sha=$(crane digest "$image_ref" 2>/dev/null); then
          if [ -n "${GITHUB_ACTIONS:-}" ]; then
            echo "::error::Image not found: ${image_ref}"
          else
            echo -e "  \033[1;31m✗\033[0m ${image_ref} (not found)"
          fi
          exit 1
        fi

        if [ "$expected_sha" != "$image" ] && [ "$actual_sha" != "$expected_sha" ]; then
          if [ -n "${GITHUB_ACTIONS:-}" ]; then
            echo "::error::Digest mismatch for ${image_ref}: expected ${expected_sha}, got ${actual_sha}"
          else
            echo -e "  \033[1;31m✗\033[0m ${image_ref} (digest mismatch: expected ${expected_sha}, got ${actual_sha})"
          fi
          exit 1
        fi

        echo -e "  \033[32m✓\033[0m ${image_ref}"
      ) &
      pids+=($!)
      parallel_count=$((parallel_count + 1))

      if [ "$parallel_count" -ge 4 ]; then
        for pid in "${pids[@]}"; do
          if ! wait "$pid"; then
            status=1
          fi
        done
        pids=()
        parallel_count=0
      fi
    done <<< "$images"

    for pid in "${pids[@]}"; do
      if ! wait "$pid"; then
        status=1
      fi
    done

    exit "$status"
