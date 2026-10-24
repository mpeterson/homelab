import copy
import io
import json
import os
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import manage


CONFIG = {
    "talosVersion": "v1.14.4",
    "clusterEndpoint": "https://10.0.0.10:6443",
    "nodes": [{"host": "worker-01", "ip": "10.0.0.1", "role": "worker"}],
}
TOPF_VERSION = "topf version 0.6.2 (Talos v1.14.4)\n"
CLIENT_VERSION = "Client:\n\tTag: v1.14.4\n"


class VersionTests(unittest.TestCase):
    def test_supported(self):
        manage.check_versions(CONFIG, TOPF_VERSION, CLIENT_VERSION, "v1.14.4")

    def test_newer_global_contract_rejected(self):
        config = copy.deepcopy(CONFIG)
        config["talosVersion"] = "v1.14.5"
        with self.assertRaises(manage.ConfigError):
            manage.check_versions(config, TOPF_VERSION, "Tag: v1.14.5", "v1.14.5")

    def test_newer_node_contract_rejected(self):
        config = copy.deepcopy(CONFIG)
        config["nodes"][0]["talosVersion"] = "v1.15.0"
        with self.assertRaises(manage.ConfigError):
            manage.check_versions(config, TOPF_VERSION, CLIENT_VERSION, "v1.14.4")

    def test_unknown_release_metadata_rejected(self):
        for value in ("topf version dev", "topf version 0.6.2", "0.6.2 (Talos unknown)"):
            with self.subTest(value=value), self.assertRaises(manage.ConfigError):
                manage.check_versions(CONFIG, value, CLIENT_VERSION, "v1.14.4")

    def test_client_mismatch_rejected(self):
        with self.assertRaises(manage.ConfigError):
            manage.check_versions(CONFIG, TOPF_VERSION, "Tag: v1.13.12", "v1.14.4")

    def test_nonstable_or_ambiguous_versions_rejected(self):
        for value in ("v1.14", "1.14.5-rc.1", "1.14.4+build", "", "01.14.4", "latest"):
            with self.subTest(value=value), self.assertRaises(manage.ConfigError):
                manage.stable_version(value)

    def test_unverified_older_schema_rejected(self):
        config = copy.deepcopy(CONFIG)
        config["talosVersion"] = "v1.13.12"
        with self.assertRaises(manage.ConfigError):
            manage.check_versions(config, TOPF_VERSION, "Tag: v1.13.12", "v1.13.12")

    def test_tuppr_only_upgrade_cannot_bypass_compatibility(self):
        for target in ("v1.14.5", "v1.15.0", "v1.14.5-rc.1"):
            with self.subTest(target=target), self.assertRaises(manage.ConfigError):
                manage.check_versions(CONFIG, TOPF_VERSION, CLIENT_VERSION, target)

    def test_repository_check_reads_the_actual_upgrade_target(self):
        upgrade = {"kind": "TalosUpgrade", "spec": {"talos": {"version": "v1.15.0"}}}
        with patch.object(manage, "yaml_documents", return_value=[upgrade]) as read:
            with patch.object(manage, "run", side_effect=[
                subprocess.CompletedProcess([], 0, TOPF_VERSION, ""),
                subprocess.CompletedProcess([], 0, CLIENT_VERSION, ""),
            ]), self.assertRaises(manage.ConfigError):
                manage.repository_versions(CONFIG)
        read.assert_called_once_with(manage.UPGRADE)


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
        with patch.object(manage, "generation") as generate:
            with self.assertRaises(manage.ConfigError):
                manage.node_operation(CONFIG, "apply", ".*")
            generate.assert_not_called()

    def test_failed_generation_cannot_reach_live_node(self):
        with patch.object(manage, "generation", side_effect=manage.ConfigError("failed")):
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
            path.write_text("independently captured private payload")
            path.chmod(0o600)
            with patch.object(manage, "yaml_documents", return_value=documents):
                with patch.object(manage, "run", side_effect=manage.ConfigError("strict validation failed")) as run:
                    with self.assertRaisesRegex(manage.ConfigError, "strict validation failed"):
                        manage.validate_render(CONFIG, Path(directory), secrets)
                    self.assertIn("--strict", run.call_args.args[0])
                    self.assertEqual(run.call_args.kwargs["input"], "independently captured private payload")
                    self.assertIn("/dev/stdin", run.call_args.args[0])

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

    def test_tool_timeout_withholds_captured_private_output(self):
        error = subprocess.TimeoutExpired(["talosctl"], 10, output="synthetic-private-value",
                                          stderr="synthetic-private-diagnostic")
        with patch("subprocess.run", side_effect=error):
            with self.assertRaisesRegex(manage.ConfigError, "readiness timed out") as context:
                manage.run(["talosctl"], timeout=10, context="Talos readiness")
        self.assertNotIn("synthetic-private", str(context.exception))

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
                with patch.object(manage, "preflight", return_value={}), patch.object(manage, "repository_versions"):
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
            with self.assertRaisesRegex(manage.ConfigError, "bundle is missing"):
                manage.preflight(config)
            run.assert_not_called()

    def test_native_encryption_fixture_and_identity_are_checked_without_legacy_mapping(self):
        secrets = {
            "certs": {"os": {"crt": "synthetic-ca", "key": "synthetic-key"}},
            "trustdinfo": {"token": "synthetic-talos-token"},
            "secrets": {"bootstraptoken": "synthetic-bootstrap", "secretboxencryptionsecret": "synthetic-secretbox"},
            "cluster": {"id": "synthetic-cluster", "secret": "synthetic-discovery"},
        }
        config = {**CONFIG, "nodes": [{"host": "cp-01", "role": "control-plane"}]}
        documents = [
            {"version": "v1alpha1", "machine": {"ca": {"crt": "synthetic-ca", "key": "synthetic-key"},
                                              "token": "synthetic-talos-token"},
             "cluster": {"token": "synthetic-bootstrap"}},
            {"kind": "HostnameConfig", "hostname": "cp-01"},
            {"kind": "DiscoveryIdentityConfig", "clusterID": "synthetic-cluster",
             "clusterSecret": "synthetic-discovery"},
            {"kind": "ExtensionServiceConfig", "name": "tailscale", "environment": ["TS_AUTHKEY=synthetic-auth"]},
            {"apiVersion": "v1alpha1", "kind": "KubeEtcdEncryptionConfig", "config": {"resources": [{
                "resources": ["secrets"], "providers": [
                    {"secretbox": {"keys": [{"name": "key2", "secret": "synthetic-secretbox"}]}},
                    {"identity": {}},
                ],
            }]}},
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cp-01.yaml"
            path.write_text("synthetic native payload")
            path.chmod(0o600)
            with patch.object(manage, "yaml_documents", return_value=documents), patch.object(manage, "run"):
                self.assertEqual(manage.validate_render(config, Path(directory), secrets),
                                 {"cp-01": "synthetic native payload"})
            for mutation in ("key-name", "key-bytes", "provider-order", "identity"):
                changed = copy.deepcopy(documents)
                providers = changed[-1]["config"]["resources"][0]["providers"]
                if mutation == "key-name":
                    providers[0]["secretbox"]["keys"][0]["name"] = "key1"
                elif mutation == "key-bytes":
                    providers[0]["secretbox"]["keys"][0]["secret"] = "rotated-private-key"
                elif mutation == "provider-order":
                    providers.reverse()
                else:
                    changed[0]["machine"]["token"] = "rotated-private-token"
                with self.subTest(mutation=mutation), patch.object(manage, "yaml_documents", return_value=changed):
                    with self.assertRaises(manage.ConfigError) as context:
                        manage.validate_render(config, Path(directory), secrets)
                    self.assertNotIn("rotated-private", str(context.exception))


class ApplicationTests(unittest.TestCase):
    def operation(self, command="apply", *, confirm="worker-01", endpoint=None,
                  dry_run="Applied configuration without a reboot (skipped in dry-run).",
                  failed_command=None):
        calls = []
        payloads = {"worker-01": "validated immutable payload"}
        before = [{"kind": "ExtensionServiceConfig", "name": "tailscale",
                   "environment": ["TS_AUTHKEY=old-private-auth-value"]}]
        after = [{"kind": "ExtensionServiceConfig", "name": "tailscale",
                  "environment": ["TS_AUTHKEY=new-private-auth-value"]}]
        kube = {"clusters": [{"cluster": {"server": endpoint or CONFIG["clusterEndpoint"]}}]}

        def invoke(args, **kwargs):
            calls.append((args, kwargs))
            if failed_command and failed_command in args:
                raise manage.ConfigError("synthetic command failed")
            if "machineconfig" in args:
                output = json.dumps({"spec": "old private configuration"})
            elif "--dry-run" in args:
                return subprocess.CompletedProcess(args, 0, "old-private-auth-value\nnew-private-auth-value\n",
                                                   dry_run + "\nprivate tool stderr")
            elif "machinestatus" in args:
                output = '{"spec":{"stage":"running","status":{"ready":true}}}'
            else:
                output = "private tool output"
            return subprocess.CompletedProcess(args, 0, output, "private tool stderr")

        def confirmation(prompt):
            payloads["worker-01"] = "subsequent unvalidated render"
            return confirm

        with tempfile.TemporaryDirectory() as directory:
            with patch.object(manage, "generation") as generation:
                generation.return_value.__enter__.return_value = (Path(directory), payloads)
                with patch.object(manage, "run", side_effect=invoke):
                    with patch.object(manage, "yaml_documents", side_effect=[before, after, [kube]]):
                        with patch("builtins.input", side_effect=confirmation) as prompt:
                            with patch.object(manage, "wait_ready") as wait:
                                manage.node_operation(CONFIG, command, "worker-01")
                                generation.assert_called_once_with(CONFIG)
        return calls, prompt, wait

    def test_dry_run_and_apply_receive_identical_validated_bytes(self):
        with patch("sys.stdout", io.StringIO()):
            calls, _, wait = self.operation()
        applied = [(args, kwargs) for args, kwargs in calls if "apply-config" in args]
        self.assertEqual(len(applied), 2)
        self.assertIn("--dry-run", applied[0][0])
        self.assertNotIn("--dry-run", applied[1][0])
        for args, kwargs in applied:
            self.assertIn("--mode=no-reboot", args)
            self.assertIn("/dev/stdin", args)
            self.assertEqual(kwargs["input"], "validated immutable payload")
        wait.assert_called_once()
        self.assertFalse(any(args[0] == "topf" and "apply" in args for args, _ in calls))

    def test_preview_never_prints_old_or_new_private_values(self):
        with patch("sys.stdout", io.StringIO()) as stdout, patch("sys.stderr", io.StringIO()) as stderr:
            calls, prompt, wait = self.operation(command="diff")
        self.assertIn("ExtensionServiceConfig", stdout.getvalue())
        for value in ("old-private-auth-value", "new-private-auth-value", "private tool stderr"):
            self.assertNotIn(value, stdout.getvalue() + stderr.getvalue())
        prompt.assert_not_called()
        wait.assert_not_called()
        self.assertEqual(sum("apply-config" in args for args, _ in calls), 1)
        self.assertFalse(any(args[0] == "kubectl" for args, _ in calls))

    def test_every_kubernetes_call_uses_private_cluster_credentials_and_endpoint(self):
        with patch("sys.stdout", io.StringIO()):
            calls, _, wait = self.operation()
        kubectl = [args for args, _ in calls if args[0] == "kubectl"]
        kubectl.append(wait.call_args.args[1])
        self.assertTrue(kubectl)
        for args in kubectl:
            self.assertIn("--kubeconfig", args)
            self.assertIn("--server", args)
            self.assertIn(CONFIG["clusterEndpoint"], args)
        talos = [args for args, _ in calls if args[0] == "talosctl"]
        self.assertTrue(all(args[args.index("-e") + 1] == "10.0.0.1" for args in talos))

    def test_unconfirmed_application_is_rejected(self):
        with patch("sys.stdout", io.StringIO()), self.assertRaisesRegex(manage.ConfigError, "not confirmed"):
            self.operation(confirm="yes")

    def test_unknown_or_rebooting_dry_run_is_rejected(self):
        with self.assertRaisesRegex(manage.ConfigError, "no-reboot"):
            self.operation(dry_run="Reboot required")

    def test_wrong_kubernetes_endpoint_is_rejected(self):
        with patch("sys.stdout", io.StringIO()), self.assertRaisesRegex(manage.ConfigError, "unexpected endpoint"):
            self.operation(endpoint="https://wrong-cluster:6443")

    def test_dry_run_and_readiness_failures_stop_application(self):
        for failed_command in ("--dry-run", "wait"):
            with self.subTest(command=failed_command), patch("sys.stdout", io.StringIO()):
                with self.assertRaisesRegex(manage.ConfigError, "synthetic command failed"):
                    self.operation(failed_command=failed_command)


class ReadinessTests(unittest.TestCase):
    def check(self, *, never_ready=False):
        clock = [0]

        def invoke(args, **kwargs):
            self.assertGreater(kwargs["timeout"], 0)
            self.assertLessEqual(kwargs["timeout"], 300 - clock[0])
            if "machinestatus" in args:
                ready = not never_ready and clock[0] != 12
                value = {"spec": {"stage": "running", "status": {"ready": ready}}}
            else:
                value = {"status": {"conditions": [{"type": "Ready", "status": "True"}]}}
            return subprocess.CompletedProcess(args, 0, json.dumps(value), "")

        def sleep(seconds):
            clock[0] += seconds

        with patch.object(manage, "run", side_effect=invoke):
            with patch.object(manage.time, "monotonic", side_effect=lambda: clock[0]):
                with patch.object(manage.time, "sleep", side_effect=sleep):
                    manage.wait_ready(["talosctl"], ["kubectl"], "worker-01")
        return clock[0]

    def test_instability_resets_the_full_thirty_second_window(self):
        self.assertEqual(self.check(), 44)

    def test_readiness_timeout_is_an_explicit_failure(self):
        with self.assertRaisesRegex(manage.ConfigError, "timed out"):
            self.check(never_ready=True)


class LockTests(unittest.TestCase):
    def test_contention_fails_immediately_and_help_does_not_wait_for_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "talos/manage.py"
            script.parent.mkdir()
            shutil.copyfile(manage.__file__, script)
            with patch.object(manage, "ROOT", Path(directory)):
                with manage.operation_lock():
                    with self.assertRaisesRegex(manage.ConfigError, "Another generation"):
                        with manage.operation_lock():
                            self.fail("Contending lock was admitted")
                    result = subprocess.run([sys.executable, script, "--help"],
                                            capture_output=True, text=True, timeout=5, check=False)
                    self.assertEqual(result.returncode, 0)

    def test_version_checks_never_lock_or_decrypt(self):
        with patch.object(sys, "argv", ["manage.py", "versions"]):
            with patch.object(manage, "inventory", return_value=CONFIG):
                with patch.object(manage, "repository_versions") as versions:
                    with patch.object(manage, "operation_lock") as lock:
                        with patch.object(manage, "preflight") as secrets, patch("sys.stdout", io.StringIO()):
                            self.assertEqual(manage.main(), 0)
        versions.assert_called_once_with(CONFIG)
        lock.assert_not_called()
        secrets.assert_not_called()


class RecoveryRecipeTests(unittest.TestCase):
    def recipe(self, args, *, confirmation="worker-01\n", allow_generation=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "talos").mkdir()
            (root / ".justfile").write_text("set unstable := true\nmod talos\n")
            shutil.copyfile(manage.ROOT / "talos/mod.just", root / "talos/mod.just")
            (root / "talos/topf.yaml").write_text(
                "---\ntalosVersion: v1.99.0\nnodes:\n  - host: worker-01\n    ip: 10.0.0.1\n")
            client = root / "client"
            client.write_text("synthetic client credentials")
            binaries = root / "bin"
            binaries.mkdir()
            stub = binaries / "talosctl"
            stub.write_text('#!/bin/bash\nprintf "%s\\n" "$@" > "$CALLS"\n')
            stub.chmod(0o700)
            mise = binaries / "mise"
            mise.write_text(
                '#!/bin/bash\nset -euo pipefail\n[[ "$1" == exec && "$2" == -- ]]\nshift 2\n'
                'case "$1" in\n'
                'yq|jq) exec "$@" ;;\n'
                'talosctl) shift; exec "$MOCK_TALOSCTL" "$@" ;;\n'
                'python3) [[ "$ALLOW_GENERATION" == true ]] || exit 97 ;;\n'
                '*) exit 98 ;;\nesac\n')
            mise.chmod(0o700)
            calls = root / "calls"
            env = {**os.environ, "PATH": str(binaries) + os.pathsep + os.environ["PATH"],
                   "TALOSCONFIG": str(client), "CALLS": str(calls), "MOCK_TALOSCTL": str(stub),
                   "ALLOW_GENERATION": str(allow_generation).lower()}
            result = subprocess.run([shutil.which("just"), "talos", *args], cwd=root, env=env,
                                    input=confirmation, capture_output=True, text=True, timeout=10, check=False)
            return result, calls.read_text().splitlines() if calls.exists() else []

    def test_reset_preserves_optional_non_reboot_mode_without_generation(self):
        for mode, reboot in (("reboot", True), ("no-reboot", False)):
            with self.subTest(mode=mode):
                result, args = self.recipe(["reset-node", "worker-01", mode])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("reset", args)
                self.assertEqual("--reboot" in args, reboot)
                self.assertIn("--graceful=false", args)

    def test_reboot_does_not_require_generator_compatibility_or_generation(self):
        result, args = self.recipe(["reboot-node", "worker-01"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("reboot", args)
        self.assertIn("powercycle", args)
        self.assertEqual(args[args.index("-e") + 1], "10.0.0.1")

    def test_unknown_node_and_denied_confirmation_never_invoke_talosctl(self):
        for args, confirmation in ((["reset-node", ".*"], ".*\n"),
                                   (["reboot-node", "worker-01"], "yes\n")):
            with self.subTest(args=args):
                result, calls = self.recipe(args, confirmation=confirmation)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [])

    def test_cluster_reprovision_requires_upfront_all_node_confirmation(self):
        result, calls = self.recipe(["reprovision-cluster"], confirmation="no\n", allow_generation=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ALL VM disks will be recreated", result.stdout)
        self.assertIn("worker-01", result.stdout)
        self.assertIn("Reprovisioning not confirmed", result.stderr)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
