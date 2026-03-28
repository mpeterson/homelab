set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

repo_root := source_directory() / ".."

[doc('Run all linters')]
[private]
default:
    @echo "==> Linting YAML..."
    @just lint yaml
    @echo ""
    @echo "==> Linting JSON..."
    @just lint json
    @echo ""
    @echo "==> Linting Actions..."
    @just lint actions
    @echo ""
    @echo "==> Linting Markdown..."
    @just lint markdown
    @echo ""
    @echo "==> Validating Renovate config..."
    @just lint renovate

[doc('Lint YAML files with yamllint')]
yaml:
    #!/usr/bin/env bash
    set -euo pipefail
    mise install --quiet
    cd "{{ repo_root }}"

    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      mise x -- yamllint --strict --format github -c .yamllint.yaml .
    else
      mise x -- yamllint --strict -c .yamllint.yaml .
    fi

[doc('Validate JSON and JSON5 files')]
json:
    #!/usr/bin/env bash
    set -euo pipefail
    mise install --quiet
    cd "{{ repo_root }}"
    status=0

    while IFS= read -r file; do
      if ! mise x -- json5 -v "$file" > /dev/null 2>&1; then
        if [ -n "${GITHUB_ACTIONS:-}" ]; then
          echo "::error file=${file}::Invalid JSON/JSON5"
        else
          echo -e "\033[1;31mERROR:\033[0m Invalid JSON/JSON5 (\033[33m${file}\033[0m)"
        fi
        status=1
      fi
    done < <(find . \( -name '*.json' -o -name '*.json5' \) -not -path './.git/*')
    exit "$status"

[doc('Lint GitHub Actions workflows with actionlint')]
actions:
    #!/usr/bin/env bash
    set -euo pipefail
    mise install --quiet
    cd "{{ repo_root }}"
    mise x -- actionlint -color

[doc('Lint Markdown files with markdownlint')]
markdown:
    #!/usr/bin/env bash
    set -euo pipefail
    mise install --quiet
    cd "{{ repo_root }}"
    mise x -- markdownlint-cli2 "**/*.md"

[doc('Validate Renovate configuration')]
renovate:
    #!/usr/bin/env bash
    set -euo pipefail
    mise install --quiet
    cd "{{ repo_root }}"
    mise x -- renovate-config-validator --strict
