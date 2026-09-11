set quiet := true
set shell := ['bash', '-euo', 'pipefail', '-c']

ansible_dir := source_directory()
default_inventory := ansible_dir / "../../homelab-private/ansible/inventories"
inventory := env("ANSIBLE_INVENTORY", default_inventory)

[private]
default:
    @just --unstable --list ansible

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
_inventory:
    #!/usr/bin/env bash
    if [[ ! -e "{{ inventory }}" ]]; then
      echo "Error: Ansible inventory not found at '{{ inventory }}'." >&2
      echo "Set ANSIBLE_INVENTORY to override the default location." >&2
      exit 1
    fi

[doc('Install required Ansible collections')]
install: (_require "ansible-galaxy")
    cd "{{ ansible_dir }}" && ansible-galaxy collection install -r requirements.yml

[doc('Display the resolved inventory graph')]
inventory: (_require "ansible-inventory") _inventory
    cd "{{ ansible_dir }}" && ansible-inventory -i "{{ inventory }}" --graph

[doc('Run a playbook by path relative to ansible/playbooks')]
playbook name *args: (_require "ansible-playbook") _inventory
    cd "{{ ansible_dir }}" && ansible-playbook -i "{{ inventory }}" "playbooks/{{ name }}" {{ args }}

[doc('Configure the NAS nodes')]
nas *args: (_require "ansible-playbook") _inventory
    cd "{{ ansible_dir }}" && ansible-playbook -i "{{ inventory }}" playbooks/setup_nas.yaml {{ args }}

[doc('Configure the Bind9 DNS servers')]
dns *args: (_require "ansible-playbook") _inventory
    cd "{{ ansible_dir }}" && ansible-playbook -i "{{ inventory }}" playbooks/bind9/setup.yaml {{ args }}
