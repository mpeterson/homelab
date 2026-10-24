#!/usr/bin/env python3
"""Guarded TOPF rendering and single-node operations."""

import argparse
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "talos/topf.yaml"
OUTPUT = ROOT / "talos/clusterconfig"


class ConfigError(Exception):
    pass


def run(args, *, accepted=(0,), input=None):
    try:
        result = subprocess.run(
            [str(arg) for arg in args], cwd=ROOT, input=input,
            text=True, capture_output=True, check=False,
        )
    except FileNotFoundError as error:
        raise ConfigError(f"Required tool not found: {args[0]}") from error
    if result.returncode not in accepted:
        # Tool diagnostics can contain decrypted YAML or template values.
        raise ConfigError(
            f"{args[0]} failed (exit {result.returncode}); "
            "configuration-bearing diagnostics were withheld"
        )
    return result


def yaml_documents(path):
    output = run(["yq", "-o=json", "-I=0", ".", path]).stdout
    try:
        documents = [json.loads(line) for line in output.splitlines() if line]
    except json.JSONDecodeError as error:
        raise ConfigError(f"Invalid YAML conversion: {path.name}") from error
    if not documents or any(not isinstance(doc, dict) for doc in documents):
        raise ConfigError(f"Expected YAML mappings: {path.name}")
    return documents


def stable_version(value):
    if not isinstance(value, str):
        raise ConfigError("Version must be a stable semantic-version string")
    match = re.fullmatch(r"v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", value)
    if not match:
        raise ConfigError("Expected an explicit stable semantic version")
    return tuple(map(int, match.groups()))


def check_versions(config, topf_version, talosctl_version):
    match = re.fullmatch(
        r"topf version (v?\d+\.\d+\.\d+) \(Talos (v?\d+\.\d+\.\d+)\)\s*",
        topf_version,
    )
    if not match:
        raise ConfigError("Cannot establish released TOPF/embedded Talos versions")
    stable_version(match[1])
    supported = stable_version(match[2])
    client = re.search(r"^\s*Tag:\s+(v?\d+\.\d+\.\d+)\s*$", talosctl_version, re.M)
    if not client:
        raise ConfigError("Cannot establish talosctl client version")
    target = stable_version(config["talosVersion"])
    if stable_version(client[1]) != target:
        raise ConfigError("talosctl must exactly match the configured Talos version")
    for node in config["nodes"]:
        version = stable_version(node.get("talosVersion", config["talosVersion"]))
        if version > supported or version[:2] != (1, 14) or version != target:
            raise ConfigError("Unsupported or mixed Talos configuration contract")
    if target > supported or target[:2] != (1, 14):
        raise ConfigError("Configured Talos version exceeds verified TOPF support")


def inventory():
    config, = yaml_documents(CONFIG)
    required = ("clusterName", "clusterEndpoint", "talosVersion",
                "kubernetesVersion", "secretsPath", "nodes")
    if any(not config.get(key) for key in required):
        raise ConfigError("Incomplete TOPF inventory")
    if not isinstance(config["nodes"], list):
        raise ConfigError("Inventory nodes must be a list")
    stable_version(config["kubernetesVersion"])
    hosts = set()
    addresses = set()
    for node in config["nodes"]:
        if not isinstance(node, dict):
            raise ConfigError("Each inventory node must be a mapping")
        host = node.get("host", "")
        if not isinstance(host, str) or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", host) or host in hosts:
            raise ConfigError("Invalid or duplicate inventory hostname")
        address = node.get("ip")
        if not isinstance(address, str) or address in addresses:
            raise ConfigError("Missing or duplicate inventory address")
        try:
            ipaddress.ip_address(address)
        except ValueError as error:
            raise ConfigError("Inventory node address must be an IP address") from error
        if node.get("role") not in ("control-plane", "worker"):
            raise ConfigError("Invalid node role")
        hosts.add(host)
        addresses.add(node["ip"])
    if not any(node["role"] == "control-plane" for node in config["nodes"]):
        raise ConfigError("Inventory has no control-plane endpoint")
    return config


def select_node(config, name):
    matches = [node for node in config["nodes"] if node["host"] == name]
    if len(matches) != 1:
        raise ConfigError("Node must exactly match one inventory hostname")
    return matches[0]


def topf(*args):
    return ["topf", "--topfconfig", CONFIG, "--redact=true",
            "--submit-to-factory=false", *args]


def preflight(config):
    check_versions(config, run(["topf", "--version"]).stdout,
                   run(["talosctl", "version", "--client"]).stdout)
    bundle = CONFIG.parent / config["secretsPath"]
    if not bundle.is_file():
        raise ConfigError("Existing encrypted secrets bundle is missing")
    # Decryption must succeed before TOPF can consider creating a secrets bundle.
    decrypted = run(["sops", "--decrypt", bundle]).stdout
    bundle_json = run(["yq", "-o=json", "-I=0", ".", "-"], input=decrypted).stdout
    secrets = json.loads(bundle_json)
    if not all(secrets.get(key) for key in ("cluster", "secrets", "trustdinfo", "certs")):
        raise ConfigError("Incomplete existing cluster secrets bundle")
    if not secrets["secrets"].get("secretboxencryptionsecret"):
        raise ConfigError("Existing Secretbox key is missing")
    for section, fields in (
        ("cluster", ("id", "secret")), ("secrets", ("bootstraptoken",)),
        ("trustdinfo", ("token",)),
    ):
        if any(not secrets[section].get(field) for field in fields):
            raise ConfigError("Incomplete existing cluster identity")
    for name in ("os", "etcd", "k8s", "k8saggregator", "k8sserviceaccount"):
        fields = ("key",) if name == "k8sserviceaccount" else ("crt", "key")
        if any(not secrets["certs"].get(name, {}).get(field) for field in fields):
            raise ConfigError("Incomplete existing cluster certificate bundle")
    return secrets


def documents_by_id(documents):
    result = {}
    for doc in documents:
        identity = (doc.get("kind", "MachineConfig"), doc.get("name", ""))
        if identity in result:
            raise ConfigError("Duplicate configuration document identity")
        result[identity] = doc
    return result


def validate_render(config, directory, secrets):
    expected = {node["host"] + ".yaml" for node in config["nodes"]}
    if {path.name for path in directory.iterdir()} != expected:
        raise ConfigError("Render is incomplete or contains unexpected output")
    for node in config["nodes"]:
        path = directory / (node["host"] + ".yaml")
        if path.is_symlink() or path.stat().st_mode & 0o077:
            raise ConfigError("Generated config permissions are not private")
        docs = documents_by_id(yaml_documents(path))
        hostname = docs.get(("HostnameConfig", ""), {}).get("hostname")
        if hostname != node["host"]:
            raise ConfigError("Rendered hostname does not match inventory")
        base = docs.get(("MachineConfig", ""), {})
        machine = base.get("machine", {})
        cluster = base.get("cluster", {})
        expected_os = dict(secrets["certs"]["os"])
        if node["role"] == "worker":
            expected_os["key"] = ""
        identity = docs.get(("DiscoveryIdentityConfig", ""), {})
        if (
            machine.get("ca") != expected_os
            or machine.get("token") != secrets["trustdinfo"]["token"]
            or cluster.get("token") != secrets["secrets"]["bootstraptoken"]
            or identity.get("clusterID") != secrets["cluster"]["id"]
            or identity.get("clusterSecret") != secrets["cluster"]["secret"]
        ):
            raise ConfigError("Rendered cluster identity differs from the existing bundle")
        tailscale = docs.get(("ExtensionServiceConfig", "tailscale"), {}).get("environment", [])
        auth = [value for value in tailscale if value.startswith("TS_AUTHKEY=")]
        if len(auth) != 1 or not auth[0].removeprefix("TS_AUTHKEY="):
            raise ConfigError("Tailscale authentication value is missing")
        if node["role"] == "control-plane":
            expected_encryption = {
                "apiVersion": "v1alpha1", "kind": "KubeEtcdEncryptionConfig",
                "config": {"resources": [{
                    "resources": ["secrets"],
                    "providers": [
                        {"secretbox": {"keys": [{
                            "name": "key2",
                            "secret": secrets["secrets"]["secretboxencryptionsecret"],
                        }]}},
                        {"identity": {}},
                    ],
                }]},
            }
            if docs.get(("KubeEtcdEncryptionConfig", "")) != expected_encryption:
                raise ConfigError("Etcd encryption identity/providers do not match existing key2")
        elif ("KubeEtcdEncryptionConfig", "") in docs:
            raise ConfigError("Unexpected worker encryption configuration")
        run(["talosctl", "validate", "--strict", "-m", "metal", "-c", path])


def private_directory(parent, prefix):
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if parent.is_symlink() or parent.stat().st_mode & 0o077:
        raise ConfigError("Generated output parent must have mode 0700")
    return Path(tempfile.mkdtemp(prefix=prefix, dir=parent))


def generate(config):
    secrets = preflight(config)
    staging = private_directory(ROOT / ".local/topf", "render-")
    try:
        run(topf("render", "--output", staging))
        validate_render(config, staging, secrets)
        credentials = run(topf("talosconfig")).stdout
        (staging / "talosconfig").write_text(credentials)
        (staging / "talosconfig").chmod(0o600)
        # Only complete, validated generations are published.
        if OUTPUT.exists():
            if OUTPUT.is_symlink():
                raise ConfigError("Refusing a symlink output directory")
            OUTPUT.chmod(0o700)
        else:
            OUTPUT.mkdir(mode=0o700)
        for path in staging.iterdir():
            os.replace(path, OUTPUT / path.name)
    finally:
        shutil.rmtree(staging)
    return secrets


def node_operation(config, command, name):
    node = select_node(config, name)
    generate(config)
    endpoint = next(node["ip"] for node in config["nodes"] if node["role"] == "control-plane")
    connection = ["talosctl", "--talosconfig", OUTPUT / "talosconfig",
                  "-e", endpoint, "-n", node["ip"]]
    live = run([*connection, "version"]).stdout
    versions = re.findall(r"^\s*Tag:\s+(v?\d+\.\d+\.\d+)\s*$", live, re.M)
    if len(versions) != 2 or any(
        stable_version(version) != stable_version(config["talosVersion"]) for version in versions
    ):
        raise ConfigError("Live node version must match the reviewed Talos contract")
    if command in ("reset-node", "reboot-node"):
        prompt = f"{command} {name} ({node['ip']})"
        if command == "reset-node":
            prompt += " and wipe STATE + EPHEMERAL"
        if input(prompt + "? Type the exact hostname to confirm: ") != name:
            raise ConfigError("Operation not confirmed")
        operation = (
            ["reset", "--system-labels-to-wipe", "STATE", "--system-labels-to-wipe",
             "EPHEMERAL", "--graceful=false", "--reboot"]
            if command == "reset-node" else ["reboot", "-m", "powercycle"]
        )
        run([*connection, *operation])
        return
    pattern = "^" + re.escape(node["host"]) + "$"
    # Only TOPF sees raw diffs; its redactor covers current and proposed secrets.
    args = topf("--nodes-filter", pattern, "--confirm=true",
                "apply", "--mode=no-reboot", "--auto-bootstrap=false",
                "--skip-problematic-nodes=false", "--skip-post-apply-checks=false",
                "--allow-not-ready=false", "--stabilization-duration=30s")
    if command == "diff":
        result = run([*args, "--dry-run"], accepted=(0, 2))
        summary = "changes detected" if result.returncode == 2 else "no changes"
        print(f"{node['host']}: {summary} (redacted diff follows)")
        print(result.stdout, end="")
        print(result.stderr, end="", file=sys.stderr)
        return
    run(["kubectl", "wait", "--for=condition=Ready", "node/" + name, "--timeout=120s"])
    # Keep TOPF's interactive confirmation and post-apply stabilization checks.
    result = subprocess.run(
        [str(arg) for arg in [*args, "--dry-run=false"]], cwd=ROOT, check=False,
    )
    if result.returncode:
        raise ConfigError(f"TOPF apply failed (exit {result.returncode})")
    run(["kubectl", "wait", "--for=condition=Ready", "node/" + name, "--timeout=300s"])


def installer(node):
    path = OUTPUT / (node["host"] + ".yaml")
    docs = documents_by_id(yaml_documents(path))
    image = docs[("UnattendedInstallConfig", "")]["installer"]["image"]
    match = re.fullmatch(
        r"factory\.talos\.dev/metal-installer/([a-f0-9]{64}):(v\d+\.\d+\.\d+)", image,
    )
    if not match:
        raise ConfigError("Unexpected installer reference")
    schematic, version = match.groups()
    return (
        f"talos-{version}-{schematic[:8]}.iso",
        f"https://factory.talos.dev/image/{schematic}/{version}/metal-amd64.iso",
    )


def reprovision(config, name, dry_run):
    node = select_node(config, name)
    image, url = installer(node)
    inventory_path = Path(os.environ.get(
        "ANSIBLE_INVENTORY", ROOT.parent / "homelab-private/ansible/inventories",
    ))
    if not inventory_path.exists():
        raise ConfigError("Ansible inventory is missing; set ANSIBLE_INVENTORY")
    if not dry_run and input(
        f"Recreate {name}'s VM disk? Type the exact hostname to confirm: "
    ) != name:
        raise ConfigError("Reprovisioning not confirmed")
    print(f"{name}: {url} (dry-run={dry_run})")
    result = subprocess.run([
        "ansible-playbook", "playbooks/utilities/reprovision-talos-vm.yaml",
        "-i", str(inventory_path),
        "-e", json.dumps({"target_vms": [name], "iso_file": image,
                         "iso_url": url, "dry_run": dry_run}),
    ], cwd=ROOT / "ansible", check=False)
    if result.returncode:
        raise ConfigError(f"Ansible reprovisioning failed (exit {result.returncode})")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=(
        "versions", "check", "genconfig", "validate", "diff", "apply", "reset-node", "reboot-node",
        "download-iso", "reprovision-node", "reprovision-cluster",
    ))
    parser.add_argument("node", nargs="?")
    parser.add_argument("--dry-run", choices=("true", "false"))
    args = parser.parse_args()
    if args.dry_run is not None and args.command not in ("reprovision-node", "reprovision-cluster"):
        parser.error("--dry-run is only valid for reprovisioning; use diff to preview config changes")
    try:
        config = inventory()
        if args.command == "versions":
            check_versions(config, run(["topf", "--version"]).stdout,
                           run(["talosctl", "version", "--client"]).stdout)
            print("Configured Talos contract is supported by TOPF and matches talosctl")
        elif args.command in ("diff", "apply", "reset-node", "reboot-node"):
            node_operation(config, args.command, args.node)
        elif args.command == "check":
            preflight(config)
        elif args.command in ("download-iso", "reprovision-node", "reprovision-cluster"):
            if args.command == "reprovision-node":
                select_node(config, args.node)
            generate(config)
            if args.command == "download-iso":
                images = {installer(node) for node in config["nodes"]}
                for name, url in sorted(images):
                    run(["curl", "-fL", "--retry", "5", "--retry-delay", "5",
                         "--retry-all-errors", "-o", CONFIG.parent / name, url])
                    print(name)
            else:
                names = ([args.node] if args.command == "reprovision-node"
                         else [node["host"] for node in config["nodes"]])
                for name in names:
                    reprovision(config, name, args.dry_run == "true")
        else:
            generate(config)
            print(f"Generated and strictly validated {len(config['nodes'])} node configs")
    except (ConfigError, OSError, KeyError, ValueError) as error:
        # Never include values from YAML decoding exceptions.
        message = str(error) if isinstance(error, ConfigError) else type(error).__name__
        print(f"ERROR: {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    os.umask(0o077)
    lock_directory = ROOT / ".local/topf"
    lock_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (lock_directory / "operation.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        sys.exit(main())
