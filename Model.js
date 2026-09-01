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

// Compact description of everything currently wrong, for notifications:
// failing check series first, then expected-but-offline nodes, then source
// errors. Capped so a wide outage still fits a notification body.
function issueSummary(report, maxLen) {
  if (!report) return "";
  var bits = [];
  var checks = report.checks || [];
  for (var i = 0; i < checks.length; i++) {
    var c = checks[i];
    if (c.severity === "ok") continue;
    if (c.error) { bits.push(c.name + ": " + c.error); continue; }
    var bad = [];
    for (var j = 0; j < c.series.length; j++) {
      if (c.series[j].severity !== "ok")
        bad.push(c.series[j].label + " " + c.series[j].display);
    }
    if (bad.length > 0) bits.push(c.name + ": " + bad.join(", "));
  }
  var ts = report.tailscale;
  if (ts && ts.offlineExpected && ts.offlineExpected.length > 0)
    bits.push("offline: " + ts.offlineExpected.join(", "));
  var errors = reportErrors(report);
  for (var k = 0; k < errors.length; k++) bits.push(errors[k]);
  var text = bits.join(" · ");
  var cap = maxLen || 180;
  return text.length > cap ? text.substring(0, cap - 1) + "…" : text;
}

// Right-hand headline for a check row: the one value worth reading first.
// Healthy updown checks collapse to "N up"; anything failing leads with the
// worst offender (series arrive sorted worst-first from the collector).
function checkHeadline(check) {
  if (!check) return "—";
  if (check.error) return check.severity === "unknown" ? "?" : check.severity;
  var s = check.series || [];
  if (s.length === 0) return "—";
  var bad = [];
  for (var i = 0; i < s.length; i++)
    if (s[i].severity !== "ok") bad.push(s[i]);
  if (check.format === "updown") {
    if (bad.length === 0) return s.length + " up";
    var text = bad[0].label + " DOWN";
    return bad.length > 1 ? text + " +" + (bad.length - 1) : text;
  }
  var lead = bad.length > 0 ? bad[0] : s[0];
  return s.length > 1 ? lead.label + " " + lead.display : lead.display;
}

// Caption line under a check name: every series value, or the error. A
// fully healthy updown check returns nothing — its headline ("5 up")
// already says everything, and a list of "x up · y up" is pure noise.
function checkDetail(check) {
  if (!check) return "";
  if (check.error) return check.error;
  if (check.format === "updown" && check.severity === "ok") return "";
  var s = check.series || [];
  var parts = [];
  for (var i = 0; i < s.length; i++)
    parts.push(s[i].label + " " + s[i].display);
  return parts.join(" · ");
}

// Caption line under a node name: address plus a plain-words state.
function peerDetail(peer) {
  if (!peer) return "";
  var parts = [];
  if (peer.ip) parts.push(peer.ip);
  if (peer.self) parts.push("this machine");
  else if (peer.online) parts.push("online");
  else parts.push(peer.expected ? "offline — expected online" : "offline");
  return parts.join(" · ");
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
