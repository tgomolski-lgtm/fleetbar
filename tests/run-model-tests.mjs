// Model.js tests. Run: node tests/run-model-tests.mjs
// Model.js is a Qt ".pragma library" file of pure functions; stripping the
// pragma makes it plain JavaScript.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import assert from "node:assert/strict";

const here = dirname(fileURLToPath(import.meta.url));
const source = readFileSync(join(here, "..", "Model.js"), "utf8")
  .replace(/^\.pragma library$/m, "");
const Model = new Function(`${source};
  return { severityRank, worstSeverity, barLabel, summaryLine, reportErrors,
           relTime, osIcon, peerState, isStale, issueSummary, checkHeadline, checkDetail, peerDetail };`)();

let passed = 0;
function test(name, fn) {
  fn();
  passed += 1;
  console.log("ok - " + name);
}

test("worstSeverity ranks crit > warn > unknown > ok", () => {
  assert.equal(Model.worstSeverity(["ok", "unknown", "warn"]), "warn");
  assert.equal(Model.worstSeverity(["warn", "crit"]), "crit");
  assert.equal(Model.worstSeverity(["ok"]), "ok");
  assert.equal(Model.worstSeverity([]), "ok");
  assert.equal(Model.worstSeverity(["bogus"]), "unknown");
});

test("barLabel shows peers and issue marker", () => {
  assert.equal(Model.barLabel({ peersOnline: 7, peersTotal: 8, issues: 0 }, true), "7/8");
  assert.equal(Model.barLabel({ peersOnline: 7, peersTotal: 8, issues: 2 }, true), "7/8 !2");
  assert.equal(Model.barLabel({ peersOnline: 0, peersTotal: 0, issues: 1 }, true), "!1");
  assert.equal(Model.barLabel({ peersOnline: 7, peersTotal: 8, issues: 2 }, false), "");
  assert.equal(Model.barLabel(null, true), "");
});

test("summaryLine reads naturally in each state", () => {
  assert.equal(
    Model.summaryLine({ peersOnline: 8, peersTotal: 8, crit: 0, warn: 0, unknown: 0 }),
    "8/8 nodes online · all checks passing");
  assert.equal(
    Model.summaryLine({ peersOnline: 7, peersTotal: 8, crit: 1, warn: 2, unknown: 0 }),
    "7/8 nodes online · 1 critical · 2 warnings");
  assert.equal(Model.summaryLine(null), "no data yet");
});

test("reportErrors surfaces every failed source, nothing else", () => {
  assert.deepEqual(Model.reportErrors(null), []);
  assert.deepEqual(Model.reportErrors({
    configError: null,
    tailscale: { enabled: true, ok: true, error: null },
    vm: { enabled: true, ok: true, error: null },
  }), []);
  assert.deepEqual(Model.reportErrors({
    configError: "config not found: x",
    tailscale: { enabled: true, ok: false, error: "timed out" },
    vm: { enabled: true, ok: false, error: "unreachable" },
  }), ["config: config not found: x", "tailscale: timed out", "metrics: unreachable"]);
  // A disabled source never reports an error.
  assert.deepEqual(Model.reportErrors({
    configError: null,
    tailscale: { enabled: false, ok: false, error: "x" },
    vm: { enabled: true, ok: true, error: null },
  }), []);
});

test("relTime buckets", () => {
  const now = 1_000_000_000 * 1000;
  assert.equal(Model.relTime(0, now), "never");
  assert.equal(Model.relTime(1_000_000_000 - 5, now), "5s ago");
  assert.equal(Model.relTime(1_000_000_000 - 120, now), "2m ago");
  assert.equal(Model.relTime(1_000_000_000 - 7200, now), "2.0h ago");
});

test("peerState distinguishes expected-offline", () => {
  assert.equal(Model.peerState({ online: true, expected: true }), "online");
  assert.equal(Model.peerState({ online: false, expected: true }), "offline-expected");
  assert.equal(Model.peerState({ online: false, expected: false }), "offline");
  assert.equal(Model.peerState(null), "offline");
});

test("isStale respects the 2.5x + grace horizon", () => {
  const now = 1_000_000 * 1000;
  assert.equal(Model.isStale(1_000_000 - 100, now, 60), false);  // 100s < 160s
  assert.equal(Model.isStale(1_000_000 - 200, now, 60), true);   // 200s > 160s
  assert.equal(Model.isStale(0, now, 60), false);                 // no report yet
});

test("osIcon maps known systems and falls back", () => {
  assert.notEqual(Model.osIcon("linux"), Model.osIcon("macOS"));
  assert.equal(Model.osIcon("weirdOS"), Model.osIcon(""));
});

test("issueSummary names offenders, skips healthy, caps length", () => {
  const report = {
    checks: [
      { name: "Gateways", severity: "crit", error: null, series: [
        { label: "studio2", display: "DOWN", severity: "crit" },
        { label: "mini", display: "up", severity: "ok" }] },
      { name: "Disk", severity: "ok", error: null, series: [
        { label: "droplet", display: "26%", severity: "ok" }] },
      { name: "Cron", severity: "unknown", error: "no data", series: [] },
    ],
    tailscale: { enabled: true, ok: true, error: null, offlineExpected: ["nas"] },
    vm: { enabled: true, ok: true, error: null },
    configError: null,
  };
  assert.equal(Model.issueSummary(report, 180),
    "Gateways: studio2 DOWN · Cron: no data · offline: nas");
  const capped = Model.issueSummary(report, 20);
  assert.equal(capped.length, 20);
  assert.ok(capped.endsWith("…"));
  assert.equal(Model.issueSummary(null, 180), "");
});


test("checkHeadline: healthy updown collapses, failures lead", () => {
  const up = (l) => ({ label: l, display: "up", severity: "ok" });
  assert.equal(Model.checkHeadline({ format: "updown", severity: "ok", error: null,
    series: [up("a"), up("b"), up("c")] }), "3 up");
  assert.equal(Model.checkHeadline({ format: "updown", severity: "crit", error: null,
    series: [{ label: "s2", display: "DOWN", severity: "crit" },
             { label: "s3", display: "DOWN", severity: "crit" }, up("a")] }), "s2 DOWN +1");
  assert.equal(Model.checkHeadline({ format: "percent", severity: "warn", error: null,
    series: [{ label: "omarchy", display: "86%", severity: "warn" },
             { label: "droplet", display: "26%", severity: "ok" }] }), "omarchy 86%");
  assert.equal(Model.checkHeadline({ format: "percent", severity: "ok", error: null,
    series: [{ label: "a", display: "26%", severity: "ok" }] }), "26%");
  assert.equal(Model.checkHeadline({ severity: "unknown", error: "no data", series: [] }), "?");
  assert.equal(Model.checkHeadline(null), "—");
});

test("checkDetail and peerDetail read naturally", () => {
  assert.equal(Model.checkDetail({ error: null, series: [
    { label: "droplet", display: "26.2%" }, { label: "omarchy", display: "45.3%" }] }),
    "droplet 26.2% · omarchy 45.3%");
  assert.equal(Model.checkDetail({ error: "unreachable", series: [] }), "unreachable");
  assert.equal(Model.peerDetail({ ip: "100.1.2.3", self: true, online: true }),
    "100.1.2.3 · this machine");
  assert.equal(Model.peerDetail({ ip: "100.1.2.4", self: false, online: false, expected: true }),
    "100.1.2.4 · offline — expected online");
  assert.equal(Model.peerDetail({ ip: "", self: false, online: true }), "online");
});

console.log(`\n${passed} tests passed`);
