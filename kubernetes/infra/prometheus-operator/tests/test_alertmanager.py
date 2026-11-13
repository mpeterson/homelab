import json
import os
import subprocess
import unittest
from datetime import datetime
from zoneinfo import ZoneInfo


WEEKDAYS = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]


class AlertmanagerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.path = os.environ["ALERTMANAGER_CONFIG"]
        cls.config = json.loads(subprocess.check_output(["yq", "-o=json", cls.path], text=True))

    def route(self, expected, *labels):
        result = subprocess.run(
            ["amtool", "config", "routes", "test", f"--config.file={self.path}", f"--verify.receivers=monitoring/alertmanager/{expected}", "--tree", *labels],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def test_existing_unclassified_alerts_keep_anytime_delivery(self):
        for severity in ("critical", "warning", "info"):
            with self.subTest(severity=severity):
                output = self.route("pushover", "alertname=ExistingAlert", "namespace=media", f"severity={severity}")
                self.assertNotIn("incident_severity", output)

    def test_opt_in_incident_severity_is_independent_of_prometheus_severity(self):
        for incident in ("sev1", "sev2", "sev3", "sev4", "sev10"):
            with self.subTest(incident=incident):
                output = self.route("pushover", "alertname=KometaRunFailed", "namespace=media", "severity=critical", f"incident_severity={incident}")
                self.assertIn("incident_severity", output)

    def test_only_lower_incident_severities_have_an_active_interval(self):
        routes = self.config["route"]["routes"]
        anytime = next(route for route in routes if 'incident_severity=~"sev[12]"' in route.get("matchers", []))
        scheduled = next(route for route in routes if 'incident_severity=~"sev([3-9]|[1-9][0-9]+)"' in route.get("matchers", []))
        self.assertNotIn("active_time_intervals", anytime)
        self.assertEqual(scheduled["active_time_intervals"], ["business-hours"])
        self.assertFalse(scheduled.get("continue", False))
        self.assertNotIn("active_time_intervals", self.config["route"])

    def test_watchdog_keeps_its_receiver_and_cadence(self):
        self.route("healthcheck-canary", "alertname=Watchdog", "severity=none")
        route = next(route for route in self.config["route"]["routes"] if route["receiver"] == "monitoring/alertmanager/healthcheck-canary")
        self.assertEqual((route["repeat_interval"], route["group_interval"]), ("5m", "1m"))

    def test_only_duplicate_kometa_and_velero_maintenance_job_alerts_are_suppressed(self):
        self.route("null", "alertname=KubeJobFailed", "namespace=velero", "job_name=infra-cloud-kopia-maintain-job-123")
        for alert in ("KubeJobFailed", "KubeJobNotCompleted"):
            with self.subTest(alert=alert):
                self.route("null", f"alertname={alert}", "namespace=media", "job_name=kometa-123")
                self.route("pushover", f"alertname={alert}", "namespace=media", "job_name=other-123")
                self.route("pushover", f"alertname={alert}", "namespace=other", "job_name=kometa-123")
        self.route("pushover", "alertname=KubeJobFailed", "namespace=velero", "job_name=velero-backup-123")

    def is_business_time(self, timestamp):
        interval = next(interval for interval in self.config["time_intervals"] if interval["name"] == "business-hours")
        utc_time = datetime.fromisoformat(timestamp)
        for entry in interval["time_intervals"]:
            local = utc_time.astimezone(ZoneInfo(entry["location"]))
            weekday = (local.weekday() + 1) % 7
            weekdays = []
            for value in entry["weekdays"]:
                bounds = value.split(":")
                weekdays.extend(range(WEEKDAYS.index(bounds[0]), WEEKDAYS.index(bounds[-1]) + 1))
            minutes = local.hour * 60 + local.minute
            for times in entry["times"]:
                start = sum(int(value) * scale for value, scale in zip(times["start_time"].split(":"), (60, 1)))
                end = sum(int(value) * scale for value, scale in zip(times["end_time"].split(":"), (60, 1)))
                if weekday in weekdays and start <= minutes < end:
                    return True
        return False

    def test_local_window_boundaries_in_standard_and_daylight_time(self):
        cases = {
            "2026-11-15T06:59:00+00:00": False,
            "2026-11-15T07:00:00+00:00": True,
            "2026-11-15T19:59:00+00:00": True,
            "2026-11-15T20:00:00+00:00": False,
            "2026-11-13T07:59:00+00:00": False,
            "2026-11-13T08:00:00+00:00": True,
            "2026-11-14T07:59:00+00:00": False,
            "2026-11-14T08:00:00+00:00": True,
            "2026-07-05T05:59:00+00:00": False,
            "2026-07-05T06:00:00+00:00": True,
            "2026-07-05T18:59:00+00:00": True,
            "2026-07-05T19:00:00+00:00": False,
            "2026-07-03T06:59:00+00:00": False,
            "2026-07-03T07:00:00+00:00": True,
            "2026-07-04T06:59:00+00:00": False,
            "2026-07-04T07:00:00+00:00": True,
        }
        for timestamp, expected in cases.items():
            with self.subTest(timestamp=timestamp):
                self.assertEqual(self.is_business_time(timestamp), expected)


if __name__ == "__main__":
    unittest.main()
