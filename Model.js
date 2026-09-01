// Pure helpers for fleetbar. No QML/Quickshell imports — everything here is
// deterministic on its inputs so it can be exercised by tests/run-model-tests
// with plain node.
.pragma library

var SEVERITY_RANK = { ok: 0, unknown: 1, warn: 2, crit: 3 };

function severityRank(s) {
  return SEVERITY_RANK[s] !== undefined ? SEVERITY_RANK[s] : 1;
}

function worstSeverity(list) {
  var top = "ok";
  for (var i = 0; i < list.length; i++) {
    // Unrecognized strings normalize to "unknown" instead of leaking through.
    var s = SEVERITY_RANK[list[i]] !== undefined ? list[i] : "unknown";
    if (severityRank(s) > severityRank(top)) top = s;
  }
  return top;
}

// Bar pill text: peers online/total, then a compact issue marker. The marker
// leads with the count of not-ok checks/sources so severity is readable even
// in monochrome themes — color alone is never the only signal.
function barLabel(summary, showLabel) {
  if (!summary) return "";
  if (!showLabel) return "";
  var parts = [];
  if (summary.peersTotal > 0)
    parts.push(summary.peersOnline + "/" + summary.peersTotal);
  if (summary.issues > 0) parts.push("!" + summary.issues);
  return parts.join(" ");
}

// One-line panel summary under the fleet name.
function summaryLine(summary) {
  if (!summary) return "no data yet";
  var bits = [];
  if (summary.peersTotal > 0)
    bits.push(summary.peersOnline + "/" + summary.peersTotal + " nodes online");
  if (summary.crit > 0) bits.push(summary.crit + " critical");
  if (summary.warn > 0) bits.push(summary.warn + " warning" + (summary.warn > 1 ? "s" : ""));
  if (summary.unknown > 0) bits.push(summary.unknown + " unknown");
  if (summary.crit === 0 && summary.warn === 0 && summary.unknown === 0)
    bits.push("all checks passing");
  return bits.join(" · ");
}

// Errors the report carries, one per line, worst-first. This is the "gaps
// first" surface: anything here renders at the TOP of the panel.
function reportErrors(report) {
  if (!report) return [];
  var out = [];
  if (report.configError) out.push("config: " + report.configError);
  if (report.tailscale && report.tailscale.enabled && !report.tailscale.ok && report.tailscale.error)
    out.push("tailscale: " + report.tailscale.error);
  if (report.vm && report.vm.enabled && !report.vm.ok && report.vm.error)
    out.push("metrics: " + report.vm.error);
  return out;
}

function relTime(epochSeconds, nowMs) {
  if (!epochSeconds) return "never";
  var s = Math.max(0, Math.round(nowMs / 1000 - epochSeconds));
  if (s < 60) return s + "s ago";
  if (s < 3600) return Math.round(s / 60) + "m ago";
  if (s < 86400) return (s / 3600).toFixed(1) + "h ago";
  return (s / 86400).toFixed(1) + "d ago";
}

// Nerd-font glyphs keyed on the OS string tailscale reports.
function osIcon(os) {
  var key = String(os || "").toLowerCase();
  if (key.indexOf("linux") !== -1) return "";
  if (key.indexOf("macos") !== -1 || key.indexOf("darwin") !== -1) return "";
  if (key.indexOf("windows") !== -1) return "";
  if (key.indexOf("ios") !== -1) return "";
  if (key.indexOf("android") !== -1) return "";
  return "";
}

// Peer state for rendering: online / offline-expected (a problem) /
// offline-unlisted (informational only).
function peerState(peer) {
  if (!peer) return "offline";
  if (peer.online) return "online";
  return peer.expected ? "offline-expected" : "offline";
}

// True when the report is older than the staleness horizon: 2.5 refresh
// intervals plus a small grace, so one slow collector run never flickers
// the bar into the stale look.
function isStale(generatedAt, nowMs, refreshIntervalSec) {
  if (!generatedAt) return false;
  var age = nowMs / 1000 - generatedAt;
  return age > refreshIntervalSec * 2.5 + 10;
}
