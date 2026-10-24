import copy
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import manage
from compare import compare, normalize


CONFIG = {
    "talosVersion": "v1.14.4",
    "nodes": [{"host": "worker-01", "ip": "10.0.0.1", "role": "worker"}],
}
TOPF_VERSION = "topf version 0.6.2 (Talos v1.14.4)\n"
CLIENT_VERSION = "Client:\n\tTag: v1.14.4\n"


class VersionTests(unittest.TestCase):
    def test_supported(self):
        manage.check_versions(CONFIG, TOPF_VERSION, CLIENT_VERSION)

    def test_newer_global_contract_rejected(self):
        config = copy.deepcopy(CONFIG)
        config["talosVersion"] = "v1.14.5"
        with self.assertRaises(manage.ConfigError):
            manage.check_versions(config, TOPF_VERSION, "Tag: v1.14.5")

    def test_newer_node_contract_rejected(self):
        config = copy.deepcopy(CONFIG)
        config["nodes"][0]["talosVersion"] = "v1.15.0"
        with self.assertRaises(manage.ConfigError):
            manage.check_versions(config, TOPF_VERSION, CLIENT_VERSION)

    def test_unknown_release_metadata_rejected(self):
        for value in ("topf version dev", "topf version 0.6.2", "0.6.2 (Talos unknown)"):
            with self.subTest(value=value), self.assertRaises(manage.ConfigError):
                manage.check_versions(CONFIG, value, CLIENT_VERSION)

    def test_client_mismatch_rejected(self):
        with self.assertRaises(manage.ConfigError):
            manage.check_versions(CONFIG, TOPF_VERSION, "Tag: v1.13.12")

    def test_nonstable_or_ambiguous_versions_rejected(self):
        for value in ("v1.14", "1.14.5-rc.1", "1.14.4+build", "", "01.14.4", "latest"):
            with self.subTest(value=value), self.assertRaises(manage.ConfigError):
                manage.stable_version(value)

    def test_unverified_older_schema_rejected(self):
        config = copy.deepcopy(CONFIG)
        config["talosVersion"] = "v1.13.12"
        with self.assertRaises(manage.ConfigError):
            manage.check_versions(config, TOPF_VERSION, "Tag: v1.13.12")


class TargetingTests(unittest.TestCase):
    def test_apply_cannot_ignore_a_requested_dry_run(self):
        with patch.object(sys, "argv", ["manage.py", "apply", "worker-01", "--dry-run=true"]):
            with patch.object(sys, "stderr", io.StringIO()):
                with patch.object(manage, "inventory") as inventory:
                    with self.assertRaises(SystemExit) as context:
                        manage.main()
                    self.assertEqual(context.exception.code, 2)
                    inventory.assert_not_called()

    def test_only_exact_node_is_selected(self):
        self.assertEqual(manage.select_node(CONFIG, "worker-01"), CONFIG["nodes"][0])
        for name in ("", None, "worker", ".*", "^worker-01$", "worker-01|control-plane"):
            with self.subTest(name=name), self.assertRaises(manage.ConfigError):
                manage.select_node(CONFIG, name)

    def test_unknown_node_cannot_generate_or_apply(self):
        with patch.object(manage, "generate") as generate:
            with self.assertRaises(manage.ConfigError):
                manage.node_operation(CONFIG, "apply", ".*")
            generate.assert_not_called()

    def test_failed_generation_cannot_reach_live_node(self):
        with patch.object(manage, "generate", side_effect=manage.ConfigError("failed")):
            with patch.object(manage, "run") as run:
                with self.assertRaises(manage.ConfigError):
                    manage.node_operation(CONFIG, "apply", "worker-01")
                run.assert_not_called()


class GenerationTests(unittest.TestCase):
    def test_strict_validation_failure_rejected(self):
        secrets = {
            "certs": {"os": {"crt": "synthetic-certificate", "key": "synthetic-private"}},
            "trustdinfo": {"token": "synthetic-os-token"},
            "secrets": {"bootstraptoken": "synthetic-bootstrap"},
            "cluster": {"id": "synthetic-id", "secret": "synthetic-cluster-secret"},
        }
        documents = [
            {"version": "v1alpha1", "machine": {
                "ca": {"crt": "synthetic-certificate", "key": ""},
                "token": "synthetic-os-token",
            }, "cluster": {"token": "synthetic-bootstrap"}},
            {"kind": "HostnameConfig", "hostname": "worker-01"},
            {"kind": "DiscoveryIdentityConfig", "clusterID": "synthetic-id",
             "clusterSecret": "synthetic-cluster-secret"},
            {"kind": "ExtensionServiceConfig", "name": "tailscale",
             "environment": ["TS_AUTHKEY=synthetic-auth"]},
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "worker-01.yaml"
            path.touch(mode=0o600)
            with patch.object(manage, "yaml_documents", return_value=documents):
                with patch.object(manage, "run", side_effect=manage.ConfigError("strict validation failed")) as run:
                    with self.assertRaisesRegex(manage.ConfigError, "strict validation failed"):
                        manage.validate_render(CONFIG, Path(directory), secrets)
                    self.assertIn("--strict", run.call_args.args[0])

    def test_tool_failures_do_not_print_decrypted_diagnostics(self):
        result = subprocess.CompletedProcess(["topf"], 1, "", "synthetic-private-value")
        with patch("subprocess.run", return_value=result):
            with self.assertRaises(manage.ConfigError) as context:
                manage.run(["topf", "render"])
        self.assertNotIn("synthetic-private-value", str(context.exception))

    def test_missing_tool_is_explicit(self):
        with patch("subprocess.run", side_effect=FileNotFoundError):
            with self.assertRaisesRegex(manage.ConfigError, "Required tool not found"):
                manage.run(["topf"])

    def test_partial_render_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(manage.ConfigError, "incomplete"):
                manage.validate_render(CONFIG, Path(directory), {})

    def test_unexpected_render_file_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "unexpected.yaml").touch()
            with self.assertRaises(manage.ConfigError):
                manage.validate_render(CONFIG, Path(directory), {})

    def test_failed_generation_preserves_published_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "published"
            output.mkdir()
            (output / "worker-01.yaml").write_text("previous private generation")
            with patch.object(manage, "ROOT", root), patch.object(manage, "OUTPUT", output):
                with patch.object(manage, "preflight", return_value={}):
                    with patch.object(manage, "run", side_effect=manage.ConfigError("failed")):
                        with self.assertRaises(manage.ConfigError):
                            manage.generate(CONFIG)
            self.assertEqual((output / "worker-01.yaml").read_text(), "previous private generation")
            self.assertEqual(list((root / ".local/topf").iterdir()), [])

    def test_duplicate_documents_rejected(self):
        with self.assertRaises(manage.ConfigError):
            manage.documents_by_id([{"kind": "HostnameConfig"}, {"kind": "HostnameConfig"}])

    def test_missing_existing_bundle_rejected_before_render(self):
        config = {**CONFIG, "secretsPath": "does-not-exist.sops.yaml"}
        with patch.object(manage, "run") as run:
            run.side_effect = [
                subprocess.CompletedProcess([], 0, TOPF_VERSION, ""),
                subprocess.CompletedProcess([], 0, CLIENT_VERSION, ""),
            ]
            with self.assertRaisesRegex(manage.ConfigError, "bundle is missing"):
                manage.preflight(config)
            self.assertEqual(run.call_count, 2)


def legacy():
    return [
        {
            "version": "v1alpha1", "machine": {
                "type": "worker", "features": {},
                "kubelet": {"image": "kubelet:v1.35.3", "disableManifestsDirectory": True},
                "install": {"disk": "/dev/sda", "image": "installer:v1.14.4",
                            "wipe": False, "grubUseUKICmdline": True},
            },
            "cluster": {"controlPlane": {"endpoint": "https://10.0.0.1:6443"},
                        "clusterName": "synthetic"},
        },
        {"apiVersion": "v1alpha1", "kind": "VolumeConfig", "name": "DATA",
         "provisioning": {"minSize": "10GiB"}},
        {"apiVersion": "v1alpha1", "kind": "KubeEtcdEncryptionConfig",
         "config": {"resources": [{"resources": ["secrets"], "providers": [
             {"secretbox": {"keys": [{"name": "key2", "secret": "synthetic-key"}]}},
             {"identity": {}},
         ]}]}},
    ]


class ComparisonTests(unittest.TestCase):
    def test_native_mapping_and_determinism(self):
        source = legacy()
        native = list(normalize(source).values())
        compare(source, native, "synthetic")
        compare(source, list(reversed(native)), "document order")
        self.assertEqual(normalize(native), normalize(source))
        self.assertEqual(source, legacy())

    def test_unknown_new_document_rejected(self):
        source = legacy()
        native = list(normalize(source).values()) + [{"kind": "FutureDocument"}]
        with self.assertRaises(manage.ConfigError):
            compare(source, native, "synthetic")

    def test_unmapped_legacy_field_rejected(self):
        source = legacy()
        native = list(normalize(source).values())
        source[0]["machine"]["futureOption"] = True
        with self.assertRaises(manage.ConfigError):
            compare(source, native, "synthetic")

    def test_volume_change_rejected(self):
        source = legacy()
        native = list(normalize(source).values())
        next(doc for doc in native if doc.get("kind") == "VolumeConfig")["provisioning"]["minSize"] = "20GiB"
        with self.assertRaises(manage.ConfigError):
            compare(source, native, "synthetic")

    def test_identity_and_provider_changes_rejected_without_values(self):
        for field, value in (("name", "key1"), ("secret", "different-synthetic-key")):
            source = legacy()
            native = list(normalize(source).values())
            encryption = next(doc for doc in native if doc.get("kind") == "KubeEtcdEncryptionConfig")
            encryption["config"]["resources"][0]["providers"][0]["secretbox"]["keys"][0][field] = value
            with self.assertRaises(manage.ConfigError) as context:
                compare(source, native, "synthetic")
            self.assertNotIn(value, str(context.exception))
        source = legacy()
        native = list(normalize(source).values())
        encryption = next(doc for doc in native if doc.get("kind") == "KubeEtcdEncryptionConfig")
        encryption["config"]["resources"][0]["providers"].reverse()
        with self.assertRaises(manage.ConfigError):
            compare(source, native, "synthetic")


if __name__ == "__main__":
    unittest.main()
