set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

repo_root := source_directory() / ".."

[doc('Run all validation checks')]
default: kustomize helm images

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

    echo "==> Validating apps kustomization..."
    if ! kustomize build kubernetes/apps/ > /dev/null; then
      just validate _error "kubernetes/apps/kustomization.yaml" "kustomize build failed for kubernetes/apps"
      status=1
    fi

    echo "==> Validating infra kustomization..."
    # Work on a copy to avoid modifying the repo
    infra_kust=$(mktemp)
    cp kubernetes/infra/kustomization.yaml "$infra_kust"
    yq -i 'del(.generators)' kubernetes/infra/kustomization.yaml
    if ! kustomize build kubernetes/infra/ > /dev/null; then
      just validate _error "kubernetes/infra/kustomization.yaml" "kustomize build failed for kubernetes/infra"
      status=1
    fi
    cp "$infra_kust" kubernetes/infra/kustomization.yaml
    rm -f "$infra_kust"

    echo "==> Validating sub-directory kustomizations..."
    while IFS= read -r kust_file; do
      dir=$(dirname "$kust_file")

      case "$dir" in
        kubernetes/apps|kubernetes/infra|kubernetes/bootstrap|kubernetes/bootstrap/argocd) continue ;;
      esac

      # Work on a copy
      backup=$(mktemp)
      cp "$kust_file" "$backup"

      if yq -e '.generators' "$kust_file" > /dev/null 2>&1; then
        yq -i 'del(.generators)' "$kust_file"
      fi

      # Skip kustomizations that only had generators
      has_content=$(yq '.resources // [] | length' "$kust_file" 2>/dev/null)
      has_configmaps=$(yq '.configMapGenerator // [] | length' "$kust_file" 2>/dev/null)
      if [ "${has_content:-0}" = "0" ] && [ "${has_configmaps:-0}" = "0" ]; then
        cp "$backup" "$kust_file"
        rm -f "$backup"
        continue
      fi

      echo "  $dir ..."
      if ! kustomize build "$dir" > /dev/null 2>&1; then
        just validate _error "$kust_file" "kustomize build failed for $dir"
        kustomize build "$dir" 2>&1 || true
        status=1
      fi

      cp "$backup" "$kust_file"
      rm -f "$backup"
    done < <(find kubernetes/apps kubernetes/infra -name 'kustomization.yaml' -type f)

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
          yq "explode(.) | select(document_index == $i) | .spec.source.helm.valuesObject" "$file" > "$values_file"
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

    echo "==> Extracting images..."
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
    echo "==> Verifying $count images..."

    parallel_count=0
    pids=()

    while IFS= read -r image; do
      image_ref="${image%%@sha256:*}"

      (
        if crane manifest "$image_ref" > /dev/null 2>&1; then
          echo "  ✓ ${image_ref}"
        else
          if [ -n "${GITHUB_ACTIONS:-}" ]; then
            echo "::error::Image not found: ${image_ref}"
          else
            echo -e "  \033[1;31m✗\033[0m ${image_ref}"
          fi
          exit 1
        fi
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
