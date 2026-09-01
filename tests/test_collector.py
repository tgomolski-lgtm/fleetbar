#!/usr/bin/env python3
"""Unit tests for fleetbar-collector. Run: python3 tests/test_collector.py"""

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
COLLECTOR = os.path.join(HERE, "..", "fleetbar-collector")

spec = importlib.util.spec_from_loader(
    "collector", importlib.machinery.SourceFileLoader("collector", COLLECTOR))
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


TS_FIXTURE = {
    "Self": {"DNSName": "omarchy.tail.ts.net.", "HostName": "omarchy",
             "TailscaleIPs": ["100.76.60.123", "fd7a::1"], "OS": "linux",
             "Online": True},
    "Peer": {
        "k1": {"DNSName": "mini.tail.ts.net.", "HostName": "Tommys Mac mini",
               "TailscaleIPs": ["100.104.232.64"], "OS": "macOS",
               "Online": True, "LastSeen": "2026-08-31T00:00:00Z"},
        "k2": {"DNSName": "nas.tail.ts.net.", "HostName": "gomo-nas",
               "TailscaleIPs": ["100.119.249.104"], "OS": "linux",
               "Online": False, "LastSeen": "2026-08-30T00:00:00Z"},
        "k3": {"DNSName": "phone.tail.ts.net.", "HostName": "localhost",
               "TailscaleIPs": ["100.92.58.91"], "OS": "iOS", "Online": True},
    },
}


def ts_proc(payload, returncode=0, stderr=""):
    proc = mock.Mock()
    proc.returncode = returncode
    proc.stdout = json.dumps(payload) if isinstance(payload, dict) else payload
    proc.stderr = stderr
    return proc


class TailscaleTests(unittest.TestCase):
    def collect(self, cfg, payload=TS_FIXTURE, **kwargs):
        with mock.patch.object(collector.subprocess, "run",
                               return_value=ts_proc(payload, **kwargs)):
            return collector.collect_tailscale(cfg)

    def test_normalizes_and_sorts_self_first(self):
        out = self.collect({})
        self.assertTrue(out["ok"])
        self.assertEqual(out["peers"][0]["name"], "omarchy")
        self.assertTrue(out["peers"][0]["self"])
        self.assertEqual(out["total"], 4)
        self.assertEqual(out["online"], 3)

    def test_hide_os_and_patterns(self):
        out = self.collect({"hideOS": ["iOS"]})
        self.assertEqual(out["total"], 3)
        out = self.collect({"hidePatterns": ["^nas$"]})
        self.assertNotIn("nas", [p["name"] for p in out["peers"]])

    def test_expected_offline_raises_severity(self):
        out = self.collect({"expect": ["nas"]})
        self.assertEqual(out["severity"], "warn")
        self.assertEqual(out["offlineExpected"], ["nas"])

    def test_unlisted_offline_is_informational(self):
        out = self.collect({"expect": ["mini"]})
        self.assertEqual(out["severity"], "ok")

    def test_offline_severity_configurable(self):
        out = self.collect({"expect": ["nas"], "offlineSeverity": "crit"})
        self.assertEqual(out["severity"], "crit")

    def test_cli_failure_is_unknown_not_ok(self):
        out = self.collect({}, payload="", returncode=1, stderr="boom")
        self.assertFalse(out["ok"])
        self.assertEqual(out["severity"], "unknown")
        self.assertIn("boom", out["error"])

    def test_bad_json_is_unknown(self):
        out = self.collect({}, payload="not json{")
        self.assertEqual(out["severity"], "unknown")

    def test_disabled_skips_cleanly(self):
        out = collector.collect_tailscale({"enabled": False})
        self.assertTrue(out["ok"])
        self.assertEqual(out["total"], 0)

    def test_ipv6_only_peer_gets_empty_ip(self):
        payload = {"Self": {"DNSName": "a.x.", "HostName": "a",
                            "TailscaleIPs": ["fd7a::2"], "OS": "linux",
                            "Online": True}}
        out = self.collect({}, payload=payload)
        self.assertEqual(out["peers"][0]["ip"], "")


def vector(*items):
    return [{"metric": m, "value": [0, str(v)]} for m, v in items]


class CheckEvalTests(unittest.TestCase):
    def test_crit_beats_warn(self):
        check = {"op": ">=", "warn": 80, "crit": 95, "format": "percent"}
        series, sev, err = collector.evaluate_check(
            check, vector(({"node": "a"}, 96), ({"node": "b"}, 85),
                          ({"node": "c"}, 10)))
        self.assertIsNone(err)
        self.assertEqual(sev, "crit")
        by = {s["label"]: s["severity"] for s in series}
        self.assertEqual(by, {"a": "crit", "b": "warn", "c": "ok"})
        # Worst-first ordering.
        self.assertEqual([s["label"] for s in series], ["a", "b", "c"])

    def test_less_than_op_for_updown(self):
        check = {"op": "<", "crit": 1, "format": "updown"}
        series, sev, _ = collector.evaluate_check(
            check, vector(({"node": "up1"}, 1), ({"node": "down1"}, 0)))
        self.assertEqual(sev, "crit")
        self.assertEqual(series[0]["display"], "DOWN")
        self.assertEqual(series[1]["display"], "up")

    def test_empty_result_is_unknown_with_error(self):
        series, sev, err = collector.evaluate_check({"op": ">="}, [])
        self.assertEqual(sev, "unknown")
        self.assertIn("no data", err)

    def test_no_thresholds_means_informational_ok(self):
        series, sev, err = collector.evaluate_check(
            {}, vector(({"node": "a"}, 123)))
        self.assertEqual(sev, "ok")

    def test_nan_value_is_unknown(self):
        series, sev, _ = collector.evaluate_check(
            {"op": ">=", "warn": 1}, vector(({"node": "a"}, "NaN")))
        self.assertEqual(sev, "unknown")

    def test_label_preference_and_fallback(self):
        self.assertEqual(collector.series_label({"node": "n", "instance": "i"},
                                                None), "n")
        self.assertEqual(collector.series_label({"instance": "i"}, None), "i")
        self.assertEqual(collector.series_label({"foo": "x"}, "foo"), "x")
        self.assertEqual(collector.series_label({}, None), "value")


class FormatTests(unittest.TestCase):
    def test_formats(self):
        f = collector.format_value
        self.assertEqual(f(45.26, "percent", "", 1), "45.3%")
        self.assertEqual(f(1536, "bytes", "", 1), "1.5 KiB")
        self.assertEqual(f(0, "updown", "", 1), "DOWN")
        self.assertEqual(f(45, "seconds", "", 1), "45s")
        self.assertEqual(f(7200, "seconds", "", 1), "2.0h")
        self.assertEqual(f(3, "number", "GB", 1), "3 GB")


class ConfigAndReportTests(unittest.TestCase):
    def test_missing_config_reports_error_but_works(self):
        cfg, err = collector.load_config("/nonexistent/nope.json")
        self.assertIn("not found", err)
        self.assertEqual(cfg["checks"], [])

    def test_bad_json_config(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json",
                                         delete=False) as fh:
            fh.write("{broken")
            path = fh.name
        try:
            cfg, err = collector.load_config(path)
            self.assertIn("unreadable", err)
        finally:
            os.unlink(path)

    def test_report_summary_rolls_up_worst(self):
        with mock.patch.object(collector, "collect_tailscale",
                               return_value={"enabled": True, "ok": True,
                                             "error": None, "self": None,
                                             "peers": [], "online": 0,
                                             "total": 0, "severity": "warn",
                                             "offlineExpected": ["x"]}), \
             mock.patch.object(collector, "collect_checks",
                               return_value=({"enabled": True, "url": "u",
                                              "ok": True, "error": None,
                                              "latencyMs": 1},
                                             [collector._check_shell(
                                                 {"id": "c"}, "crit", None)])), \
             mock.patch.object(collector, "load_config",
                               return_value=(dict(collector.CONFIG_DEFAULTS),
                                             None)):
            report = collector.build_report("/tmp/x.json")
        self.assertEqual(report["summary"]["severity"], "crit")
        self.assertEqual(report["summary"]["crit"], 1)
        self.assertEqual(report["summary"]["warn"], 1)

    def test_end_to_end_subprocess_bad_config_still_exits_zero(self):
        proc = subprocess.run(
            [sys.executable, COLLECTOR, "--config", "/nonexistent/nope.json"],
            capture_output=True, text=True, timeout=30)
        self.assertEqual(proc.returncode, 0)
        doc = json.loads(proc.stdout)
        self.assertEqual(doc["version"], 1)
        self.assertIn("not found", doc["configError"])
        self.assertEqual(doc["summary"]["severity"], "unknown")


class VmErrorTests(unittest.TestCase):
    def test_unreachable_vm_marks_all_checks_unknown(self):
        vm, checks = collector.collect_checks(
            {"url": "http://127.0.0.1:1", "timeoutSec": 1},
            [{"id": "a", "name": "A", "query": "up"},
             {"id": "b", "name": "B", "query": "up"}])
        self.assertFalse(vm["ok"])
        self.assertIsNotNone(vm["error"])
        self.assertTrue(all(c["severity"] == "unknown" for c in checks))

    def test_no_url_with_checks_is_surfaced(self):
        vm, checks = collector.collect_checks(
            {}, [{"id": "a", "name": "A", "query": "up"}])
        self.assertFalse(vm["ok"])
        self.assertEqual(checks[0]["severity"], "unknown")


if __name__ == "__main__":
    unittest.main(verbosity=2)
