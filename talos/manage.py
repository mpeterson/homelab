#!/usr/bin/env python3
"""Guarded TOPF rendering and single-node operations."""

import argparse
from contextlib import contextmanager, nullcontext
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
import time


ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "talos/topf.yaml"
OUTPUT = ROOT / "talos/clusterconfig"
UPGRADE = ROOT / "kubernetes/infra/tuppr/upgrades/talos.yaml"


class ConfigError(Exception):
    pass


def run(args, *, input=None, sensitive=True, context=None):
    try:
        result = subprocess.run(
            [str(arg) for arg in args], cwd=ROOT, input=input,
            text=True, capture_output=True, check=False,
        )
    except FileNotFoundError as error:
        raise ConfigError(f"Required tool not found: {args[0]}") from error
    if result.returncode:
        detail = ("configuration-bearing diagnostics withheld" if sensitive
                  else (result.stderr or result.stdout).strip())
        raise ConfigError(f"{context or args[0]} failed (exit {result.returncode}); {detail}")
    return result


def yaml_documents(path, *, input=None):
    output = run(["yq", "-o=json", "-I=0", ".", path], input=input).stdout
    try:
        documents = [json.loads(line) for line in output.splitlines() if line]
    except json.JSONDecodeError as error:
        raise ConfigError("Invalid YAML conversion (values withheld)") from error
    if not documents or any(not isinstance(doc, dict) for doc in documents):
        raise ConfigError("Expected YAML mappings (values withheld)")
    return documents


def stable_version(value):
    if not isinstance(value, str):
        raise ConfigError("Version must be a stable semantic-version string")
    match = re.fullmatch(r"v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)", value)
    if not match:
        raise ConfigError("Expected an explicit stable semantic version")
    return tuple(map(int, match.groups()))


def check_versions(config, topf_version, talosctl_version, upgrade_version):
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
    if stable_version(upgrade_version) != target:
        raise ConfigError("Tuppr's Talos upgrade target must match the TOPF configuration contract")
    for node in config["nodes"]:
        version = stable_version(node.get("talosVersion", config["talosVersion"]))
        if version > supported or version[:2] != (1, 14) or version != target:
            raise ConfigError("Unsupported or mixed Talos configuration contract")
    if target > supported or target[:2] != (1, 14):
        raise ConfigError("Configured Talos version exceeds verified TOPF support")


def repository_versions(config):
    upgrade, = yaml_documents(UPGRADE)
    if upgrade.get("kind") != "TalosUpgrade":
        raise ConfigError("Expected the Tuppr TalosUpgrade configuration")
    check_versions(config, run(["topf", "--version"], sensitive=False).stdout,
                   run(["talosctl", "version", "--client"], sensitive=False).stdout,
                   upgrade["spec"]["talos"]["version"])


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
    payloads = {}
    for node in config["nodes"]:
        path = directory / (node["host"] + ".yaml")
        if path.is_symlink() or path.stat().st_mode & 0o077:
            raise ConfigError("Generated config permissions are not private")
        payload = path.read_text()
        docs = documents_by_id(yaml_documents("-", input=payload))
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
        run(["talosctl", "validate", "--strict", "-m", "metal", "-c", "/dev/stdin"],
            input=payload, context=f"Strict validation for {node['host']}")
        payloads[node["host"]] = payload
    return payloads


def private_directory(parent, prefix):
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if parent.is_symlink() or parent.stat().st_mode & 0o077:
        raise ConfigError("Generated output parent must have mode 0700")
    return Path(tempfile.mkdtemp(prefix=prefix, dir=parent))


@contextmanager
def generation(config):
    repository_versions(config)
    secrets = preflight(config)
    staging = private_directory(ROOT / ".local/topf", "render-")
    try:
        run(topf("render", "--output", staging))
        payloads = validate_render(config, staging, secrets)
        credentials = run(topf("talosconfig")).stdout
        (staging / "talosconfig").write_text(credentials)
        (staging / "talosconfig").chmod(0o600)
        yield staging, payloads
    finally:
        shutil.rmtree(staging)


def generate(config):
    with generation(config) as (staging, payloads):
        if OUTPUT.exists():
            if OUTPUT.is_symlink():
                raise ConfigError("Refusing a symlink output directory")
            OUTPUT.chmod(0o700)
        else:
            OUTPUT.mkdir(mode=0o700)
        for name, payload in payloads.items():
            (staging / (name + ".yaml")).write_text(payload)
        for path in staging.iterdir():
            os.replace(path, OUTPUT / path.name)


def node_operation(config, command, name):
    node = select_node(config, name)
    with generation(config) as (directory, payloads):
        payload = payloads[name]
        connection = ["talosctl", "--talosconfig", directory / "talosconfig",
                      "-e", node["ip"], "-n", node["ip"]]
        current = json.loads(run([*connection, "get", "machineconfig", "persistent", "-o", "json"]).stdout)
        before = documents_by_id(yaml_documents("-", input=current["spec"]))
        after = documents_by_id(yaml_documents("-", input=payload))
        changed = sorted({kind for kind, key in before.keys() | after.keys()
                          if before.get((kind, key)) != after.get((kind, key))})
        apply = [*connection, "apply-config", "--mode=no-reboot", "--file", "/dev/stdin"]
        result = run([*apply, "--dry-run"], input=payload, context=f"Server-side dry-run for {name}")
        if not re.search(r"^Applied configuration without a reboot \(skipped in dry-run\)\.?\s*$",
                         result.stdout + "\n" + result.stderr, re.M):
            raise ConfigError("Dry-run did not confirm a no-reboot application; output withheld")
        print(f"{name}: server-side dry-run accepted without a reboot")
        print("Changed document kinds: " + (", ".join(changed) if changed else "none") + " (values withheld)")
        if command == "diff":
            return
        kubeconfig = directory / "kubeconfig"
        kubeconfig.write_text(run(topf("kubeconfig")).stdout)
        kubeconfig.chmod(0o600)
        kube, = yaml_documents(kubeconfig)
        if [cluster["cluster"]["server"] for cluster in kube["clusters"]] != [config["clusterEndpoint"]]:
            raise ConfigError("Generated Kubernetes credentials target an unexpected endpoint")
        kubectl = ["kubectl", "--kubeconfig", kubeconfig, "--server", config["clusterEndpoint"]]
        if input(f"Apply to {name} ({node['ip']})? Type the exact hostname to confirm: ") != name:
            raise ConfigError("Application not confirmed")
        run([*kubectl, "wait", "--for=condition=Ready", "node/" + name, "--timeout=120s"],
            sensitive=False, context=f"Kubernetes readiness before applying {name}")
        status = json.loads(run([*connection, "get", "machinestatus", "-o", "json"], sensitive=False).stdout)["spec"]
        if status["stage"] != "running" or not status["status"]["ready"]:
            raise ConfigError(f"{name}: Talos is not ready; refusing application")
        run(apply, input=payload, context=f"Configuration application for {name}")
        wait_ready(connection, kubectl, name)
        print(f"{name}: applied the validated payload; Talos and Kubernetes healthy for 30 seconds")


def wait_ready(connection, kubectl, name):
    deadline = time.monotonic() + 300
    stable_since = None
    while time.monotonic() < deadline:
        status = json.loads(run([*connection, "get", "machinestatus", "-o", "json"], sensitive=False).stdout)["spec"]
        node = json.loads(run([*kubectl, "get", "node", name, "-o", "json"], sensitive=False).stdout)
        ready = (status["stage"] == "running" and status["status"]["ready"]
                 and any(condition["type"] == "Ready" and condition["status"] == "True"
                         for condition in node["status"]["conditions"]))
        if not ready:
            stable_since = None
        elif stable_since is None:
            stable_since = time.monotonic()
        elif time.monotonic() - stable_since >= 30:
            return
        time.sleep(2)
    raise ConfigError(f"{name}: sustained Talos/Kubernetes readiness timed out after 300 seconds")


@contextmanager
def operation_lock():
    parent = ROOT / ".local/topf"
    parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if parent.is_symlink() or parent.stat().st_mode & 0o077:
        raise ConfigError("Operation lock directory must have mode 0700")
    with (parent / "operation.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ConfigError("Another generation/application is active; retry after it finishes") from error
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=(
        "versions", "check", "genconfig", "validate", "diff", "apply", "credentials",
    ))
    parser.add_argument("node", nargs="?")
    args = parser.parse_args()
    if (args.command in ("diff", "apply")) != (args.node is not None):
        parser.error("diff/apply require one exact hostname; other commands take no hostname")
    try:
        config = inventory()
        locked = args.command in ("genconfig", "validate", "apply", "credentials")
        with operation_lock() if locked else nullcontext():
            if args.command == "versions":
                repository_versions(config)
                print("TOPF supports the configured Talos version; talosctl and Tuppr targets match")
            elif args.command in ("diff", "apply"):
                node_operation(config, args.command, args.node)
            elif args.command == "check":
                repository_versions(config)
                preflight(config)
            elif args.command == "credentials":
                preflight(config)
                OUTPUT.mkdir(mode=0o700, exist_ok=True)
                if OUTPUT.is_symlink() or OUTPUT.stat().st_mode & 0o077:
                    raise ConfigError("Client configuration directory must have mode 0700")
                with tempfile.NamedTemporaryFile(dir=OUTPUT, mode="w", delete=False) as file:
                    path = Path(file.name)
                    try:
                        file.write(run(topf("talosconfig")).stdout)
                        file.close()
                        os.replace(path, OUTPUT / "talosconfig")
                    finally:
                        path.unlink(missing_ok=True)
            else:
                generate(config)
                print(f"Generated and strictly validated {len(config['nodes'])} node configs")
    except (ConfigError, OSError, KeyError, ValueError) as error:
        # Never include values from YAML decoding exceptions.
        if isinstance(error, ConfigError):
            message = str(error)
        elif isinstance(error, OSError):
            message = f"Private configuration I/O failed: {error.strerror}"
        else:
            message = f"Invalid configuration structure ({type(error).__name__}; values withheld)"
        print(f"ERROR: {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
