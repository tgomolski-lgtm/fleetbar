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


def ts_proc(payload, returncode=0, stderr="", overflow=False, timed_out=False):
    proc = mock.Mock()
    proc.returncode = returncode
    proc.stdout = json.dumps(payload) if isinstance(payload, dict) else payload
    proc.stderr = stderr
    proc.overflow = overflow
    proc.timed_out = timed_out
    return proc


class TailscaleTests(unittest.TestCase):
    def collect(self, cfg, payload=TS_FIXTURE, **kwargs):
        with mock.patch.object(collector, "_run_bounded",
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

    def test_active_fresh_handshake_counts_as_online(self):
        import datetime as dt
        now = dt.datetime.now(dt.timezone.utc)
        fresh = (now - dt.timedelta(seconds=30)).isoformat()
        stale = (now - dt.timedelta(hours=2)).isoformat()
        peers = {"Self": TS_FIXTURE["Self"], "Peer": {
            "a": {"HostName": "nas-live", "TailscaleIPs": ["100.1.1.1"],
                  "OS": "linux", "Online": False, "Active": True,
                  "LastHandshake": fresh},
            "b": {"HostName": "nas-stale", "TailscaleIPs": ["100.1.1.2"],
                  "OS": "linux", "Online": False, "Active": True,
                  "LastHandshake": stale},
            "c": {"HostName": "nas-inactive", "TailscaleIPs": ["100.1.1.3"],
                  "OS": "linux", "Online": False, "Active": False,
                  "LastHandshake": fresh},
        }}
        out = self.collect({"expect": ["nas-"]}, payload=peers)
        by = {p["name"]: p["online"] for p in out["peers"]}
        self.assertTrue(by["nas-live"])
        self.assertFalse(by["nas-stale"])
        self.assertFalse(by["nas-inactive"])

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


class HistoryTests(unittest.TestCase):
    def matrix(self, *series):
        return [{"metric": m, "values": v} for m, v in series]

    def test_max_aggregation_default(self):
        trace = collector.aggregate_history(self.matrix(
            ({"node": "a"}, [[100, "1"], [200, "5"]]),
            ({"node": "b"}, [[100, "3"], [200, "2"]])), ">=", 40)
        self.assertEqual(trace, [3.0, 5.0])

    def test_min_aggregation_for_less_than(self):
        trace = collector.aggregate_history(self.matrix(
            ({"node": "a"}, [[100, "1"], [200, "1"]]),
            ({"node": "b"}, [[100, "0"], [200, "1"]])), "<", 40)
        self.assertEqual(trace, [0.0, 1.0])

    def test_unaligned_timestamps_merge_sorted(self):
        trace = collector.aggregate_history(self.matrix(
            ({"node": "a"}, [[300, "3"]]),
            ({"node": "b"}, [[100, "1"]])), ">=", 40)
        self.assertEqual(trace, [1.0, 3.0])

    def test_points_cap_keeps_newest(self):
        values = [[i, str(i)] for i in range(10)]
        trace = collector.aggregate_history(self.matrix(({}, values)), ">=", 3)
        self.assertEqual(trace, [7.0, 8.0, 9.0])

    def test_garbage_and_empty(self):
        self.assertEqual(collector.aggregate_history(None, ">=", 10), [])
        trace = collector.aggregate_history(self.matrix(
            ({}, [[100, "nope"], [200, "NaN"], [300, "2"]])), ">=", 10)
        self.assertEqual(trace, [2.0])

    def test_check_shell_carries_history(self):
        shell = collector._check_shell({"id": "x"}, "ok", None,
                                       history=[1.0, 2.0])
        self.assertEqual(shell["history"], [1.0, 2.0])
        self.assertEqual(collector._check_shell({"id": "x"}, "ok",
                                                None)["history"], [])


class LatencyAndIdentityTests(unittest.TestCase):
    def test_parse_pong_direct_and_relay(self):
        self.assertEqual(collector.parse_pong(
            "pong from mini (100.1.2.3) via [2600::1]:41641 in 1ms"),
            (1, "direct"))
        self.assertEqual(collector.parse_pong(
            "pong from nas (100.1.2.4) via DERP(mia) in 23ms"),
            (23, "via mia"))
        self.assertEqual(collector.parse_pong("no reply"), (None, None))
        self.assertEqual(collector.parse_pong(""), (None, None))

    def test_humanize_since(self):
        import datetime as dt
        now = dt.datetime.now(dt.timezone.utc)
        iso = lambda delta: (now - delta).isoformat().replace("+00:00", "Z")
        self.assertIsNone(collector.humanize_since("0001-01-01T00:00:00Z"))
        self.assertIsNone(collector.humanize_since(""))
        self.assertIsNone(collector.humanize_since("garbage"))
        self.assertEqual(collector.humanize_since(
            iso(dt.timedelta(minutes=30))), "30m")
        self.assertEqual(collector.humanize_since(
            iso(dt.timedelta(hours=5))), "5h")
        self.assertEqual(collector.humanize_since(
            iso(dt.timedelta(days=18))), "18d")

    def test_identity_line(self):
        self.assertEqual(collector.identity_line(
            {"chip": "Apple M4 Pro", "cores": 12, "memGb": 24}),
            "M4 Pro · 12c · 24G")
        self.assertEqual(collector.identity_line(
            {"chip": "AMD FX-8350"}), "FX-8350")
        self.assertEqual(collector.identity_line(
            {"chip": "Snapdragon X"}), "Snapdragon X")
        self.assertEqual(collector.identity_line({"cores": 8}), "8c")
        self.assertEqual(collector.identity_line({}), "")

    def test_attach_exact_match_only(self):
        peers = [
            {"name": "mac-studio", "host": "Mac Studio", "identity": None},
            {"name": "thomass-mac-studio", "host": "x", "identity": None},
            {"name": "omarchy", "host": "omarchy", "identity": None},
        ]
        info = {
            "Watchdog": {"chip": "M3 Ultra", "cores": 28, "memGb": 96},
            "Omarchy": {"chip": "FX-8350", "cores": 8, "memGb": 16},
            "Unmapped": {"chip": "Ghost"},
        }
        collector.attach_node_info(peers, info, {"Watchdog": "mac-studio"})
        # Alias lands on the exact name; never leaks onto the longer one.
        self.assertEqual(peers[0]["identity"], "M3 Ultra · 28c · 96G")
        self.assertIsNone(peers[1]["identity"])
        # No alias: exact case-insensitive label==name fallback.
        self.assertEqual(peers[2]["identity"], "FX-8350 · 8c · 16G")


class NodeStatsTests(unittest.TestCase):
    def test_rate_stat_thresholds(self):
        self.assertEqual(collector.rate_stat(50, 85, 95), "ok")
        self.assertEqual(collector.rate_stat(86, 85, 95), "warn")
        self.assertEqual(collector.rate_stat(96, 85, 95), "crit")
        self.assertEqual(collector.rate_stat(99, None, None), "ok")

    def test_collect_and_attach_stats(self):
        vec = [{"metric": {"node": "mini"}, "value": [0, "19.4"]},
               {"metric": {"node": "ghost"}, "value": [0, "5"]},
               {"metric": {"node": "bad"}, "value": [0, "NaN"]}]
        with mock.patch.object(collector, "query_instant",
                               return_value=(vec, 3, None)):
            stats = collector.collect_node_stats(
                {"url": "http://x"}, {"cpu": {"query": "q", "warn": 85}})
        self.assertEqual(stats["mini"]["cpu"]["display"], "19%")
        self.assertEqual(stats["mini"]["cpu"]["severity"], "ok")
        self.assertNotIn("bad", stats)
        peers = [{"name": "tommys-mac-mini-1", "stats": None},
                 {"name": "other", "stats": None}]
        collector.attach_node_stats(peers, stats,
                                    {"mini": "tommys-mac-mini-1"})
        self.assertIsNotNone(peers[0]["stats"])
        self.assertIsNone(peers[1]["stats"])

    def test_stats_failure_yields_no_badges(self):
        with mock.patch.object(collector, "query_instant",
                               return_value=(None, None, "boom")):
            stats = collector.collect_node_stats(
                {"url": "http://x"}, {"cpu": {"query": "q"}})
        self.assertEqual(stats, {})
        self.assertEqual(collector.collect_node_stats({}, {"cpu": {"query": "q"}}), {})


class HardeningTests(unittest.TestCase):
    def test_string_caps_and_ip_validation(self):
        payload = {"Self": {"DNSName": ("x" * 500) + ".ts.net.",
                            "HostName": "h" * 500,
                            "TailscaleIPs": ["not-an-ip", "999.1.1.1",
                                             "100.1.2.3", "fd7a::1"],
                            "OS": "linux", "Online": True}}
        with mock.patch.object(collector, "_run_bounded",
                               return_value=ts_proc(payload)):
            out = collector.collect_tailscale({})
        peer = out["peers"][0]
        self.assertLessEqual(len(peer["name"]), 64)
        self.assertEqual(peer["ip"], "100.1.2.3")

    def test_peer_count_cap(self):
        payload = {"Self": {"DNSName": "s.x.", "HostName": "s",
                            "TailscaleIPs": [], "OS": "linux", "Online": True},
                   "Peer": {str(i): {"HostName": "p%d" % i, "Online": True,
                                     "TailscaleIPs": [], "OS": "linux"}
                            for i in range(collector.MAX_PEERS + 50)}}
        with mock.patch.object(collector, "_run_bounded",
                               return_value=ts_proc(payload)):
            out = collector.collect_tailscale({"latency": False})
        self.assertLessEqual(out["total"], collector.MAX_PEERS + 1)

    def test_series_cap(self):
        result = [{"metric": {"node": "n%d" % i}, "value": [0, "1"]}
                  for i in range(collector.MAX_SERIES + 40)]
        series, _, _ = collector.evaluate_check({"op": ">="}, result)
        self.assertEqual(len(series), collector.MAX_SERIES)

    def test_non_http_url_refused(self):
        result, _, error = collector.query_instant("file:///etc", "up", 2)
        self.assertIsNone(result)
        self.assertIn("http(s)", error)

    def test_redirects_refused(self):
        import http.server, threading
        class Redirector(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1:1/steal")
                self.end_headers()
            def log_message(self, *a): pass
        srv = http.server.HTTPServer(("127.0.0.1", 0), Redirector)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        try:
            result, _, error = collector.query_instant(
                "http://127.0.0.1:%d" % srv.server_port, "up", 3)
            self.assertIsNone(result)
            self.assertIsNotNone(error)
        finally:
            srv.shutdown()


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


class Round3HardeningTests(unittest.TestCase):
    """Reviewer blockers (marketplace #4031, round 3): config no-follow /
    type / owner / pre-read size, producer-side child caps, cap+1 HTTP
    rejection with a wall-clock deadline, bounded report, tree cleanup."""

    def test_config_symlink_is_refused(self):
        import tempfile, pathlib
        with tempfile.TemporaryDirectory() as d:
            real = pathlib.Path(d, "real.json"); real.write_text("{}")
            link = pathlib.Path(d, "link.json"); link.symlink_to(real)
            cfg, err = collector.load_config(str(link))
            self.assertIn("symlink", err)
            self.assertEqual(cfg["fleetName"], "Fleet")

    def test_config_over_cap_is_refused_before_read(self):
        import tempfile, pathlib
        with tempfile.TemporaryDirectory() as d:
            big = pathlib.Path(d, "big.json")
            big.write_text('{"fleetName": "' + "x" * (collector.MAX_CONFIG_BYTES + 10) + '"}')
            cfg, err = collector.load_config(str(big))
            self.assertIn("exceeds", err)
            self.assertEqual(cfg["fleetName"], "Fleet")

    def test_config_not_regular_file_is_refused(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            cfg, err = collector.load_config(d)
            self.assertIn("unreadable", err)

    def test_config_wrong_owner_is_refused(self):
        import tempfile, pathlib, os as _os
        with tempfile.TemporaryDirectory() as d:
            f = pathlib.Path(d, "c.json"); f.write_text("{}")
            real = _os.fstat
            def fake(fd):
                st = real(fd)
                return _os.stat_result((st.st_mode, st.st_ino, st.st_dev, st.st_nlink,
                                        st.st_uid + 1, st.st_gid, st.st_size,
                                        st.st_atime, st.st_mtime, st.st_ctime))
            with mock.patch.object(collector.os, "fstat", fake):
                cfg, err = collector.load_config(str(f))
            self.assertIn("owned", err)

    def test_child_stdout_over_cap_is_rejected_not_truncated(self):
        res = collector._run_bounded(
            [sys.executable, "-c", "import sys; sys.stdout.write('x' * 200000)"],
            5, 1000)
        self.assertTrue(res.overflow)
        self.assertEqual(res.stdout, "")

    def test_child_stderr_over_cap_is_rejected(self):
        res = collector._run_bounded(
            [sys.executable, "-c", "import sys; sys.stderr.write('e' * 5000)"],
            5, 100000, max_err=100)
        self.assertTrue(res.overflow)

    def test_child_deadline_kills_process_group(self):
        import time as _t
        started = _t.monotonic()
        res = collector._run_bounded(
            [sys.executable, "-c",
             "import subprocess, time; subprocess.Popen(['sleep', '30']); time.sleep(30)"],
            0.5, 1000)
        self.assertTrue(res.timed_out)
        self.assertLess(_t.monotonic() - started, 5)
        # the grandchild `sleep 30` was in the same session; it must be gone
        _t.sleep(0.3)
        import subprocess as _sp
        out = _sp.run(["pgrep", "-f", "^sleep 30$"], capture_output=True, text=True).stdout
        self.assertEqual(out.strip(), "")

    def test_child_clean_run_returns_output(self):
        res = collector._run_bounded([sys.executable, "-c", "print('ok')"], 5, 1000)
        self.assertFalse(res.overflow or res.timed_out)
        self.assertEqual(res.stdout.strip(), "ok")
        self.assertEqual(res.returncode, 0)

    def test_tailscale_overflow_is_unknown_with_reason(self):
        out = self.collect_ts({}, overflow=True)
        self.assertEqual(out["severity"], "unknown")
        self.assertIn("exceeds", out["error"])

    def collect_ts(self, cfg, **kw):
        with mock.patch.object(collector, "_run_bounded",
                               return_value=ts_proc(TS_FIXTURE, **kw)):
            return collector.collect_tailscale(cfg)

    class _Resp:
        def __init__(self, chunks, length=None, delay=0):
            self.chunks = list(chunks); self.headers = {}
            if length is not None: self.headers["Content-Length"] = str(length)
            self.delay = delay
        def read(self, n):
            import time as _t
            if self.delay: _t.sleep(self.delay)
            return self.chunks.pop(0) if self.chunks else b""
        def __enter__(self): return self
        def __exit__(self, *a): return False

    def test_http_body_over_cap_is_rejected(self):
        resp = self._Resp([b"x" * 70000, b"y" * 70000, b""])
        with mock.patch.object(collector._OPENER, "open", return_value=resp):
            body, err = collector._http_get("http://h/x", 5, 100000)
        self.assertIsNone(body)
        self.assertIn("exceeds", err)

    def test_http_declared_length_over_cap_is_refused_unread(self):
        resp = self._Resp([b"{}"], length=10 ** 9)
        with mock.patch.object(collector._OPENER, "open", return_value=resp):
            body, err = collector._http_get("http://h/x", 5, 1000)
        self.assertIsNone(body)
        self.assertIn("declares", err)
        self.assertEqual(len(resp.chunks), 1)  # never read

    def test_http_wall_clock_deadline(self):
        resp = self._Resp([b"a"] * 50, delay=0.05)
        with mock.patch.object(collector._OPENER, "open", return_value=resp):
            body, err = collector._http_get("http://h/x", 0.2, 10 ** 6)
        self.assertIsNone(body)
        self.assertIn("deadline", err)

    def test_http_within_cap_ok(self):
        resp = self._Resp([b'{"status":"success"}', b""])
        with mock.patch.object(collector._OPENER, "open", return_value=resp):
            body, err = collector._http_get("http://h/x", 5, 1000)
        self.assertIsNone(err)
        self.assertEqual(body, b'{"status":"success"}')

    def test_bound_caps_strings_lists_keys_depth_and_nan(self):
        deep = {"a": "x" * 10000, "l": list(range(5000)),
                "n": float("nan"), "k%d" % 0: 1}
        for i in range(200): deep["key%d" % i] = i
        nest = deep
        for _ in range(20): nest = {"d": nest}
        b = collector._bound(nest)
        cur = b; depth = 0
        while isinstance(cur, dict) and "d" in cur: cur = cur["d"]; depth += 1
        self.assertLessEqual(depth, collector.MAX_DEPTH + 1)
        flat = collector._bound(deep)
        self.assertEqual(len(flat["a"]), collector.MAX_STR)
        self.assertEqual(len(flat["l"]), collector.MAX_LIST)
        self.assertIsNone(flat["n"])
        self.assertLessEqual(len(flat), collector.MAX_KEYS)

    def test_report_is_bounded_end_to_end(self):
        huge = json.loads(json.dumps(TS_FIXTURE))
        huge["Peer"]["k1"]["HostName"] = "h" * 5000
        with mock.patch.object(collector, "_run_bounded", return_value=ts_proc(huge)), \
             mock.patch.object(collector, "load_config",
                               return_value=({"fleetName": "F" * 500, "tailscale": {},
                                              "victoriametrics": {}, "checks": [],
                                              "history": {}, "nodeInfo": {}, "nodeStats": {},
                                              "dashboardUrl": "", "sshCommand": "ssh {name}"}, None)):
            rep = collector.build_report("/nonexistent")
        self.assertLessEqual(len(rep["fleetName"]), 64)
        self.assertTrue(all(len(p["name"]) <= collector.MAX_STR for p in rep["tailscale"]["peers"]))
        json.dumps(rep)  # serializable (no NaN)


if __name__ == "__main__":
    unittest.main(verbosity=2)
