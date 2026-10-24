set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

talos_dir := source_directory()

export SOPS_AGE_KEY_FILE := env("SOPS_AGE_KEY_FILE", env("HOME") / ".config/sops/age/keys.txt")

[private]
default:
    @just --unstable --list talos

[doc('Check TOPF/Talos compatibility and the existing encrypted secrets bundle')]
check:
    mise exec -- python3 "{{ talos_dir }}/manage.py" check

[doc('Check the configured version contract without decrypting secrets')]
versions:
    mise exec -- python3 "{{ talos_dir }}/manage.py" versions

[doc('Generate and strictly validate all TOPF node configs locally')]
genconfig:
    mise exec -- python3 "{{ talos_dir }}/manage.py" genconfig

[doc('Strictly validate a fresh complete TOPF generation')]
validate:
    mise exec -- python3 "{{ talos_dir }}/manage.py" validate

[doc('Show a redacted, node-specific server-side config dry-run')]
[positional-arguments]
diff node:
    mise exec -- python3 "{{ talos_dir }}/manage.py" diff "$1"

[doc('Apply one exact node with confirmation, no reboot, and readiness gates')]
[positional-arguments]
apply node:
    mise exec -- python3 "{{ talos_dir }}/manage.py" apply "$1"

[doc('Reset one node and wipe STATE + EPHEMERAL (hostname confirmation required)')]
[positional-arguments]
reset-node node:
    mise exec -- python3 "{{ talos_dir }}/manage.py" reset-node "$1"

[doc('Power-cycle one node (hostname confirmation required)')]
[positional-arguments]
reboot-node node:
    mise exec -- python3 "{{ talos_dir }}/manage.py" reboot-node "$1"

[doc('Download the existing factory ISOs for all unique rendered schematics')]
download-iso:
    mise exec -- python3 "{{ talos_dir }}/manage.py" download-iso

[doc('Reprovision one VM using its rendered schematic (destructive unless dry_run=true)')]
[positional-arguments]
reprovision-node node dry_run="false":
    mise exec -- python3 "{{ talos_dir }}/manage.py" reprovision-node "$1" --dry-run="$2"

[doc('Reprovision inventory VMs with per-node confirmation (destructive unless dry_run=true)')]
[positional-arguments]
reprovision-cluster dry_run="false":
    mise exec -- python3 "{{ talos_dir }}/manage.py" reprovision-cluster --dry-run="$1"

[doc('Compare every baseline/TOPF/live document privately; print only pass/fail identities')]
[positional-arguments]
compare baseline candidate live:
    mise exec -- python3 "{{ talos_dir }}/compare.py" "$1" "$2" --live "$3"

[doc('Run secret-free TOPF workflow regression tests')]
test:
    mise exec -- python3 -m unittest discover -s "{{ talos_dir }}/tests" -v
