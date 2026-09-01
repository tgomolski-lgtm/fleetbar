# Fleetbar

**Your fleet's heartbeat in the Omarchy bar.**

Fleetbar watches two things and folds them into one status pill: every machine
on your **Tailscale** tailnet (straight from the local daemon — no API key, no
cloud), and any number of threshold **checks** against a Prometheus-compatible
metrics source (VictoriaMetrics, Prometheus, Thanos, Mimir, ...).

![Fleetbar panel](preview.png)

The bar shows `7/8` (nodes online) and appends `!N` when anything needs
attention. Click for the full panel: node chips with online state, OS and
click-to-copy IPs, every check with its per-series values and a **sparkline
trend** (worst-direction fold of the check's history), and an honest footer
with data age and collection latency.

**It's a sentinel, not just a dashboard**: when the fleet's overall severity
changes, Fleetbar sends a desktop notification naming exactly what broke —
`Busta Fleet: WARN — Disk used: omarchy 45.3%` — and one when it recovers.
Notifications are transition-based and flap-guarded (at most one per five
minutes), and a shell restart never re-announces an ongoing incident.
Disable with the `notifyOnChange` setting.

## The honesty contract

Monitoring that fails silently is worse than no monitoring. Fleetbar's
collector treats failure as data:

- A source that can't be reached, a query that errors, or a query that
  returns **no data** renders as `unknown` — never as green.
- Every failure is printed at the **top** of the panel, before any data.
- When the report itself goes stale (collector stopped producing), the bar
  visibly drifts toward the muted shade and the footer says `STALE`.

## Install

```
omarchy plugin add https://github.com/tgomolski-lgtm/fleetbar --enable
```

Then describe your fleet in `~/.config/fleetbar/config.json` (start from
[config.example.json](config.example.json)):

```jsonc
{
  "fleetName": "Homelab",
  "dashboardUrl": "http://grafana.example:3000",   // right-click target
  "tailscale": {
    "hidePatterns": ["^localhost$"],   // regex, matched per node name/host
    "hideOS": ["iOS", "android"],
    "expect": ["server1", "nas"],      // offline+expected = a problem
    "offlineSeverity": "warn"          // or "crit"
  },
  "victoriametrics": { "url": "http://vm.example:8428" },
  "checks": [
    {
      "id": "disk", "name": "Disk used",
      "query": "max by (node) (100 - 100 * node_filesystem_avail_bytes / node_filesystem_size_bytes)",
      "op": ">=", "warn": 85, "crit": 95, "format": "percent"
    }
  ]
}
```

Edits to the config apply live — the panel watches the file.

### Check reference

| Field | Meaning |
|---|---|
| `query` | Any instant-vector PromQL. Multi-series results become one row each. |
| `op` | Breach direction: `>` `>=` `<` `<=` `==` `!=` (default `>=`). |
| `warn` / `crit` | Thresholds; `crit` wins. Omit both for informational checks. |
| `format` | `number`, `percent`, `bytes`, `seconds`, `updown`. |
| `labelKey` | Label naming each series (auto: `node` → `host` → `instance` → `job`). |
| `unit`, `decimals` | Display suffix and precision for `number`. |
| `history` | `false` to skip the sparkline range query for this check. |

Global history tuning (optional, top-level): `"history": {"enabled": true,
"spanSec": 10800, "points": 40}` — the sparkline is a range query over
`spanSec`, folded across series in the check's worst direction (`min` per
timestep for `<`/`<=` checks, `max` otherwise). History is decoration: a
failed range query degrades to no sparkline, never to a failed check.

### Bar interactions

| Action | Effect |
|---|---|
| Click | Toggle the fleet panel |
| Middle click | Force refresh |
| Right click | Open your `dashboardUrl` |

IPC: `qs ipc call stratoforce.fleetbar toggle` (also `open`, `close`, `refresh`).

## Design

- `fleetbar-collector` — a stdlib-only Python 3 script. One run produces one
  JSON report; VM queries run concurrently; every source has its own timeout.
  Exit 0 with in-band errors whenever a report exists at all.
- `Panel.qml` owns the collector process and all state (the first-party
  weather plugin's pattern); `BarWidget.qml` is a thin host; `Model.js` is
  pure functions.
- Theming comes entirely from Omarchy's `Color`/`Style` tokens — severity is
  a blend between your theme's foreground and urgent colors, so it stays
  legible in every theme, and issue counts are always also written as text
  (`!2`), never color alone.

## Tests

```
python3 tests/test_collector.py   # 28 tests: sources, severity, formats, failure paths
node tests/run-model-tests.mjs    # 9 tests: pure view-model helpers
```

## License

MIT
