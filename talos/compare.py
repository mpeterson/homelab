#!/usr/bin/env python3
"""Exhaustive, secret-safe comparison with the frozen Talhelper/live baseline."""

import argparse
import base64
import copy
from pathlib import Path
import sys

from manage import ConfigError, documents_by_id, inventory, yaml_documents


def require(value, expected, context):
    if value != expected:
        raise ConfigError(f"Unexpected representation: {context} (values withheld)")


def pem(value):
    try:
        return base64.b64decode(value, validate=True).decode()
    except (ValueError, UnicodeError) as error:
        raise ConfigError("Invalid legacy certificate/key encoding") from error


def normalize(documents):
    docs = documents_by_id(copy.deepcopy(documents))
    base = docs[("MachineConfig", "")]
    base.pop("kind", None)
    machine = base["machine"]
    cluster = base["cluster"]
    role = machine["type"]

    def add(kind, fields, name=""):
        identity = (kind, name)
        if identity in docs:
            raise ConfigError(f"Conflicting legacy and native {kind}")
        doc = {"apiVersion": "v1alpha1", "kind": kind, **fields}
        if name:
            doc["name"] = name
        docs[identity] = doc

    if "id" in cluster:
        add("DiscoveryIdentityConfig", {
            "clusterID": cluster.pop("id"), "clusterSecret": cluster.pop("secret"),
        })
    if "controlPlane" in cluster:
        endpoint = cluster.pop("controlPlane")
        require(set(endpoint), {"endpoint"}, "control-plane endpoint fields")
        add("KubeClusterConfig", {
            "clusterName": cluster.pop("clusterName"), "endpoint": endpoint["endpoint"],
        })
    endpoint = docs[("KubeClusterConfig", "")]["endpoint"]
    if "ca" in cluster:
        ca = cluster.pop("ca")
        require(set(ca), {"crt", "key"}, "Kubernetes CA fields")
        if role == "controlplane":
            fields = {"issuingCA": {"cert": pem(ca["crt"]), "key": pem(ca["key"])}}
        else:
            require(ca["key"], "", "worker must not have Kubernetes CA key")
            fields = {"acceptedCAs": [pem(ca["crt"])]}
        add("KubeAPIServerCAConfig", fields)
    if "aggregatorCA" in cluster:
        ca = cluster.pop("aggregatorCA")
        require(set(ca), {"crt", "key"}, "aggregator CA fields")
        add("KubeAggregatorCAConfig", {
            "issuingCA": {"cert": pem(ca["crt"]), "key": pem(ca["key"])},
        })
    if "serviceAccount" in cluster:
        account = cluster.pop("serviceAccount")
        require(set(account), {"key"}, "service-account fields")
        add("KubeServiceAccountConfig", {
            "issuer": {"privateKey": pem(account["key"]), "issuerURL": endpoint},
        })
    if "kubelet" in machine:
        kubelet = machine.pop("kubelet")
        # Native Talos 1.14 always disables the kubelet manifests directory.
        require(kubelet.pop("disableManifestsDirectory"), True, "kubelet manifests")
        add("KubeletConfig", {"config": {}, **kubelet})
    if "install" in machine:
        install = machine.pop("install")
        disk = install.pop("disk")
        image = install.pop("image")
        wipe = install.pop("wipe")
        # Unattended installation uses Talos 1.14's UKI boot path.
        require(install.pop("grubUseUKICmdline"), True, "legacy UKI boot setting")
        require(install, {}, "unmapped installation options")
        add("UnattendedInstallConfig", {
            "installer": {"image": image},
            "provisioning": {
                "diskSelector": {"match": f'disk.dev_path == "{disk}"'}, "wipe": wipe,
            },
        })
    if "files" in machine:
        for file in machine.pop("files"):
            path = file.pop("path")
            content = file.pop("content")
            mode = file.pop("permissions")
            operation = file.pop("op")
            require(file, {}, "unmapped file options")
            if path == "/etc/nfsmount.conf":
                require(operation, "overwrite", "NFS file operation")
                add("EtcFileConfig", {"mode": mode, "contents": content}, "nfsmount.conf")
            elif path == "/etc/cri/conf.d/20-customization.part":
                require((operation, mode), ("create", 0), "CRI file operation")
                add("CRICustomizationConfig", {"content": content}, "20-customization")
            else:
                raise ConfigError("Unmapped legacy machine file")
    if "udev" in machine:
        add("UdevRulesConfig", machine.pop("udev"))
    features = machine["features"]
    if "kubePrism" in features:
        prism = features.pop("kubePrism")
        require(prism.pop("enabled"), True, "KubePrism enablement")
        add("KubePrismConfig", prism)
    if "kubernetesTalosAPIAccess" in features:
        access = features.pop("kubernetesTalosAPIAccess")
        require(access.pop("enabled"), True, "Talos API access enablement")
        add("KubeTalosAPIAccessConfig", access)
    if ("KubeNodeConfig", "") not in docs:
        node = {"nodeIP": {}}
        labels = machine.pop("nodeLabels", {})
        if role == "controlplane":
            node["labels"] = {"node-role.kubernetes.io/control-plane": "", **labels}
            node["taints"] = {"node-role.kubernetes.io/control-plane": "NoSchedule"}
        else:
            require(labels, {}, "worker node labels")
        add("KubeNodeConfig", node)
    if role == "controlplane" and ("KubeCoreDNSConfig", "") not in docs:
        add("KubeCoreDNSConfig", {"enabled": True})
    # Talos resource serialization stores sysctls as strings.
    if "sysctls" in machine:
        machine["sysctls"] = {key: str(value) for key, value in machine["sysctls"].items()}
    return docs


def compare(left, right, label):
    left_docs = normalize(left)
    right_docs = normalize(right)
    if left_docs.keys() != right_docs.keys():
        changed = sorted(left_docs.keys() ^ right_docs.keys())
        raise ConfigError(f"{label}: unmatched document identities: {changed}")
    different = [identity for identity in left_docs if left_docs[identity] != right_docs[identity]]
    if different:
        raise ConfigError(f"{label}: unequal documents: {sorted(different)} (values withheld)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--live", type=Path)
    args = parser.parse_args()
    try:
        for node in inventory()["nodes"]:
            name = node["host"]
            baseline = yaml_documents(args.baseline / f"talos-proxmox-cluster-{name}.yaml")
            candidate = yaml_documents(args.candidate / f"{name}.yaml")
            compare(baseline, candidate, name + " baseline/TOPF")
            if args.live:
                compare(yaml_documents(args.live / f"{name}.yaml"), candidate, name + " live/TOPF")
            print(f"{name}: all documents and private identity material equivalent")
    except (ConfigError, OSError, KeyError, ValueError) as error:
        message = str(error) if isinstance(error, ConfigError) else type(error).__name__
        print(f"ERROR: {message}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
