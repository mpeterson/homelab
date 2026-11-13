import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from subprocess import CompletedProcess


spec = importlib.util.spec_from_file_location("kometa_run", Path(__file__).parents[1] / "config/run.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


def record(level, message):
    return f"[2026-11-13 14:53:09,000] [kometa.py:497]             [{level}]     | {message} |\n"


SUCCESS = (
    record("INFO", "Finished Movies Library Overlays")
    + record("INFO", "Finished Series Library Overlays")
    + record("INFO", "Finished Run")
)


class RunTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.log = Path(self.directory.name) / "meta.log"

    def execute(self, content, status=0):
        def process(command, check):
            self.log.write_text(content)
            return CompletedProcess(command, status)

        with patch.object(runner.subprocess, "run", side_effect=process):
            return runner.run(["kometa"], self.log, ["Movies", "Series"])

    def test_zero_exit_cache_failure_is_a_failed_run(self):
        self.assertEqual(self.execute(record("CRITICAL", "disk I/O error") + record("INFO", "Finished Run")), 1)

    def test_partial_success_with_an_application_error_fails(self):
        self.assertEqual(self.execute(record("ERROR", "Overlay Error: download failed") + SUCCESS), 1)

    def test_warnings_and_error_words_in_info_are_not_failures(self):
        self.assertEqual(self.execute(record("WARNING", "Config Warning: using default") + record("INFO", "Error count: 0") + SUCCESS), 0)

    def test_process_exit_status_is_preserved(self):
        self.assertEqual(self.execute(SUCCESS, status=7), 7)
        self.assertEqual(self.execute(SUCCESS, status=-15), 143)

    def test_each_configured_library_must_finish_overlays(self):
        self.assertEqual(self.execute(record("INFO", "Finished Movies Library Overlays") + record("INFO", "Finished Run")), 1)

    def test_missing_run_completion_fails(self):
        self.assertEqual(self.execute(record("INFO", "Finished Movies Library Overlays") + record("INFO", "Finished Series Library Overlays")), 1)

    def test_missing_or_unchanged_log_cannot_reuse_old_success(self):
        for existing in (False, True):
            with self.subTest(existing=existing):
                if existing:
                    self.log.write_text(SUCCESS)
                with patch.object(runner.subprocess, "run", return_value=CompletedProcess(["kometa"], 0)):
                    self.assertEqual(runner.run(["kometa"], self.log, ["Movies", "Series"]), 1)

    def test_a_new_successful_run_replaces_historical_errors(self):
        self.log.write_text(record("ERROR", "Historical failure"))
        self.assertEqual(self.execute(SUCCESS), 0)

    def test_unbracketed_log_levels_also_detect_errors(self):
        plain = "[2026-11-13 14:53:09,000] cache.py                    CRITICAL   | disk I/O error |\n"
        self.assertEqual(self.execute(plain + SUCCESS), 1)


if __name__ == "__main__":
    unittest.main()
