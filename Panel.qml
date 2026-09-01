import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Fleetbar panel: owns the collector process and all fleet state (the
// first-party weather plugin's pattern — the bar widget is a thin host).
Panel {
  id: root
  moduleName: "stratoforce.fleetbar"
  ipcTarget: "stratoforce.fleetbar"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar identifies panels by the widget mounted in its slot (BarWidget
  // .qml), not this nested panel — popout coordination and switchPanelFrom
  // both compare against slot.activeItem.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Data state -------------------------------------------------------

  // Last parsed collector report. Kept on failure so stale data stays
  // visible under an explicit error banner instead of vanishing.
  property var report: null
  property string collectorError: ""
  property double nowMs: Date.now()

  readonly property var summary: report ? report.summary : null
  readonly property var peers: (report && report.tailscale) ? report.tailscale.peers : []
  readonly property var checks: report ? report.checks : []
  readonly property var reportErrors: Model.reportErrors(report)
  readonly property string fleetName: (report && report.fleetName) ? report.fleetName : "Fleet"
  readonly property string dashboardUrl: (report && report.dashboardUrl) ? report.dashboardUrl : ""

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 60, 15, 3600)
  readonly property bool showLabel: setting("showLabel", true) === true
  readonly property bool notifyOnChange: setting("notifyOnChange", true) === true
  readonly property bool stale: Model.isStale(report ? report.generatedAt : 0, nowMs, refreshIntervalSec)

  readonly property string severity: {
    if (collectorError !== "" && !report) return "unknown"
    if (!summary) return "unknown"
    if (collectorError !== "") return Model.worstSeverity([summary.severity, "unknown"])
    return summary.severity
  }

  // ---- Bar face ---------------------------------------------------------

  readonly property string barGlyph: ""
  readonly property string barLabel: {
    if (!report && collectorError !== "") return "!"
    return Model.barLabel(summary, showLabel)
  }

  // Severity is a foreground blend, never opacity: ok rides the bar's own
  // foreground, crit is the theme's urgent, warn sits between, unknown and
  // stale drift toward muted so degradation is visible but calm.
  readonly property color barColor: {
    var base = root.bar ? root.bar.barForeground : Color.foreground
    var c = base
    if (severity === "crit") c = Color.urgent
    else if (severity === "warn") c = mix(base, Color.urgent, 0.55)
    else if (severity === "unknown") c = mix(base, Color.muted, 0.7)
    if (stale) c = mix(c, Color.muted, 0.5)
    return c
  }

  function severityColor(sev, base) {
    if (sev === "crit") return Color.urgent
    if (sev === "warn") return mix(base, Color.urgent, 0.55)
    if (sev === "unknown") return Color.muted
    return base
  }

  function mix(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t,
                   a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)
  }

  function tinted(base, alpha) {
    return Qt.rgba(base.r, base.g, base.b, alpha)
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.min(max, Math.max(min, n))
  }

  // ---- Actions ----------------------------------------------------------

  // The collector travels with the plugin clone; Qt.resolvedUrl is relative
  // to this file. Decoded per segment (mirror of the file-url encoding).
  readonly property string collectorPath: urlToPath(Qt.resolvedUrl("fleetbar-collector"))

  function urlToPath(u) {
    var s = String(u)
    if (s.indexOf("file://") !== 0) return ""
    try { return s.substring(7).split("/").map(decodeURIComponent).join("/") }
    catch (e) { return "" }
  }

  function refresh() {
    if (!collectorProc.running) collectorProc.running = true
  }

  function openDashboard() {
    if (dashboardUrl !== "") Quickshell.execDetached(["xdg-open", dashboardUrl])
  }

  function copyPeerIp(peer) {
    if (peer && peer.ip) Quickshell.execDetached(["wl-copy", String(peer.ip)])
  }

  // ---- Sentinel: desktop notification on severity transitions ------------

  // "" = no report seen yet: the first report sets the baseline silently, so
  // a shell restart during an ongoing incident doesn't re-announce it.
  property string lastNotifiedSeverity: ""
  property double lastNotifyMs: 0

  function maybeNotify() {
    if (!summary) return
    var sev = summary.severity
    if (lastNotifiedSeverity === "") { lastNotifiedSeverity = sev; return }
    if (sev === lastNotifiedSeverity) return
    var previous = lastNotifiedSeverity
    lastNotifiedSeverity = sev
    if (!notifyOnChange) return
    // Flap guard: state always tracks truth above, but at most one ping per
    // five minutes — a bouncing check can't spam the desktop.
    var now = Date.now()
    if (now - lastNotifyMs < 300000) return
    lastNotifyMs = now
    var urgency = sev === "crit" ? "critical" : sev === "ok" ? "low" : "normal"
    var headline = sev === "ok"
      ? fleetName + ": recovered"
      : fleetName + ": " + sev.toUpperCase()
    var body = sev === "ok"
      ? "all checks passing (was " + previous + ")"
      : Model.issueSummary(report, 180)
    Quickshell.execDetached(["omarchy-notification-send", "-u", urgency,
                             "-g", barGlyph, headline, body])
  }

  // ---- Panel plumbing (weather-pattern popout contract) -----------------

  function open() {
    openedFromHotkey = false
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.openFromHotkey()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Processes / timers ----------------------------------------------

  Process {
    id: collectorProc
    command: ["python3", root.collectorPath]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "") {
          root.collectorError = "collector produced no output"
          return
        }
        try {
          var doc = JSON.parse(raw)
          if (!doc || doc.version !== 1) {
            root.collectorError = "unexpected collector output"
            return
          }
          root.report = doc
          root.collectorError = ""
          root.nowMs = Date.now()
          root.maybeNotify()
        } catch (e) {
          root.collectorError = "collector output unparsable"
        }
      }
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Relative-time / staleness ticker. Cheap enough to run always: the bar
  // color depends on staleness even while the panel is closed.
  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // Hand-edits to the fleet config take effect on the next tick of this
  // watch instead of the next scheduled refresh.
  FileView {
    path: Quickshell.env("HOME") + "/.config/fleetbar/config.json"
    watchChanges: true
    printErrors: false
    onFileChanged: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.openFromHotkey() }
    function close(): void { root.close() }
    function show(): void { root.openFromHotkey() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  // ---- View -------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(fleetColumn.implicitHeight + Style.space(28))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: fleetScroll
        anchors.fill: parent
        anchors.margins: Style.space(14)
        contentWidth: width
        contentHeight: fleetColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: fleetColumn
          width: fleetScroll.width
          spacing: Style.space(12)

          // ---- Hero: glyph + fleet name + summary; dashboard shortcut.
          Item {
            width: parent.width
            height: heroRow.implicitHeight

            Row {
              id: heroRow
              spacing: Style.space(10)

              Text {
                text: root.barGlyph
                color: root.severityColor(root.severity, Color.popups.text)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.display
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                spacing: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  text: root.fleetName
                  color: Color.popups.text
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  text: Model.summaryLine(root.summary)
                  color: root.severity === "ok" ? Color.muted
                    : root.severityColor(root.severity, Color.popups.text)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Text {
              visible: root.dashboardUrl !== ""
              text: ""
              color: dashboardMouse.containsMouse ? Color.accent : Color.muted
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.body
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              MouseArea {
                id: dashboardMouse
                anchors.fill: parent
                anchors.margins: -Style.space(6)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openDashboard()
              }
            }
          }

          // ---- Gaps first: every source failure renders before any data.
          Rectangle {
            visible: root.reportErrors.length > 0 || root.collectorError !== ""
            width: parent.width
            implicitHeight: errorColumn.implicitHeight + Style.space(12)
            radius: Style.space(6)
            color: root.tinted(Color.urgent, 0.12)
            border.color: root.tinted(Color.urgent, 0.5)
            border.width: 1

            Column {
              id: errorColumn
              anchors.centerIn: parent
              width: parent.width - Style.space(16)
              spacing: Style.space(2)

              Repeater {
                model: (root.collectorError !== "" ? [ "collector: " + root.collectorError ] : [])
                  .concat(root.reportErrors)

                Text {
                  required property var modelData
                  text: modelData
                  color: Color.urgent
                  width: parent.width
                  wrapMode: Text.WrapAnywhere
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // ---- Nodes ----
          PanelSectionHeader {
            visible: root.peers.length > 0
            text: "NODES"
          }

          Flow {
            visible: root.peers.length > 0
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.peers

              Rectangle {
                required property var modelData
                readonly property string state: Model.peerState(modelData)
                readonly property color dotColor: state === "online" ? Color.accent
                  : state === "offline-expected" ? Color.urgent : Color.muted

                radius: Style.space(6)
                color: peerMouse.containsMouse
                  ? root.tinted(Color.popups.text, 0.12)
                  : root.tinted(Color.popups.text, 0.06)
                implicitWidth: peerRow.implicitWidth + Style.space(16)
                implicitHeight: peerRow.implicitHeight + Style.space(10)

                Row {
                  id: peerRow
                  anchors.centerIn: parent
                  spacing: Style.space(6)

                  Rectangle {
                    width: Style.space(7)
                    height: width
                    radius: width / 2
                    color: dotColor
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: Model.osIcon(modelData.os)
                    color: Color.muted
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    text: modelData.name + (modelData.self ? " (this)" : "")
                    color: modelData.online ? Color.popups.text : Color.muted
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                MouseArea {
                  id: peerMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: modelData.ip ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.copyPeerIp(modelData)
                }

                PanelToolTip {
                  visible: peerMouse.containsMouse
                  text: (modelData.ip ? modelData.ip + " — click to copy" : "no IPv4")
                    + (modelData.online ? "" : " · offline")
                }
              }
            }
          }

          // ---- Checks ----
          PanelSectionHeader {
            visible: root.checks.length > 0
            text: "CHECKS"
          }

          Column {
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: root.checks

              Column {
                required property var modelData
                width: parent.width
                spacing: Style.space(4)

                Item {
                  width: parent.width
                  height: checkName.implicitHeight

                  Row {
                    spacing: Style.space(6)

                    Rectangle {
                      width: Style.space(7)
                      height: width
                      radius: width / 2
                      color: root.severityColor(modelData.severity, Color.accent)
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      id: checkName
                      text: modelData.name
                      color: Color.popups.text
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  Text {
                    id: checkStatus
                    text: modelData.error ? modelData.error
                      : (modelData.severity === "ok" ? "ok" : modelData.severity)
                    color: root.severityColor(modelData.severity, Color.muted)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  // Worst-direction trend over the configured history span.
                  Canvas {
                    id: spark
                    visible: (modelData.history || []).length >= 2
                    width: Style.space(56)
                    height: Style.space(12)
                    anchors.right: checkStatus.left
                    anchors.rightMargin: Style.space(10)
                    anchors.verticalCenter: parent.verticalCenter

                    antialiasing: true

                    readonly property var trace: modelData.history || []
                    readonly property color lineColor: root.tinted(
                      root.severityColor(modelData.severity, Color.popups.text),
                      modelData.severity === "ok" ? 0.55 : 0.9)

                    // A Canvas that is created hidden (or before its backing
                    // store exists) drops requestPaint silently — every
                    // trigger that can make it drawable must re-request.
                    onTraceChanged: requestPaint()
                    onLineColorChanged: requestPaint()
                    onVisibleChanged: if (visible) requestPaint()
                    onAvailableChanged: if (available) requestPaint()
                    onWidthChanged: requestPaint()
                    onHeightChanged: requestPaint()

                    onPaint: {
                      var ctx = getContext("2d")
                      ctx.clearRect(0, 0, width, height)
                      var data = trace
                      if (data.length < 2) return
                      var lo = Infinity, hi = -Infinity
                      for (var i = 0; i < data.length; i++) {
                        if (data[i] === null) continue
                        if (data[i] < lo) lo = data[i]
                        if (data[i] > hi) hi = data[i]
                      }
                      if (lo === Infinity) return
                      // A flat trace still draws: pad the range so the line
                      // sits mid-height instead of dividing by zero.
                      if (hi - lo < 1e-9) { hi += 1; lo -= 1 }
                      var pad = 1.5
                      ctx.strokeStyle = lineColor
                      ctx.lineWidth = 1.2
                      ctx.lineJoin = "round"
                      ctx.beginPath()
                      var started = false
                      for (var j = 0; j < data.length; j++) {
                        if (data[j] === null) { started = false; continue }
                        var x = data.length === 1 ? 0
                          : j / (data.length - 1) * (width - 1)
                        var y = pad + (1 - (data[j] - lo) / (hi - lo))
                          * (height - pad * 2)
                        if (!started) { ctx.moveTo(x, y); started = true }
                        else ctx.lineTo(x, y)
                      }
                      ctx.stroke()
                    }
                  }
                }

                Flow {
                  width: parent.width
                  spacing: Style.space(4)
                  visible: modelData.series.length > 0

                  Repeater {
                    model: modelData.series

                    Rectangle {
                      required property var modelData
                      radius: Style.space(4)
                      color: modelData.severity === "ok"
                        ? root.tinted(Color.popups.text, 0.05)
                        : root.tinted(root.severityColor(modelData.severity, Color.popups.text), 0.15)
                      implicitWidth: seriesText.implicitWidth + Style.space(12)
                      implicitHeight: seriesText.implicitHeight + Style.space(6)

                      Text {
                        id: seriesText
                        anchors.centerIn: parent
                        text: modelData.label + " " + modelData.display
                        color: modelData.severity === "ok" ? Color.muted
                          : root.severityColor(modelData.severity, Color.popups.text)
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }
            }
          }

          PanelSeparator { width: parent.width }

          // ---- Footer: freshness + collection cost, honestly stated.
          Text {
            width: parent.width
            text: {
              if (!root.report) return root.collectorError !== ""
                ? "collector failed — no data" : "collecting…"
              var bits = ["updated " + Model.relTime(root.report.generatedAt, root.nowMs)]
              if (root.stale) bits.push("STALE")
              bits.push("collector " + root.report.durationMs + "ms")
              if (root.report.vm && root.report.vm.latencyMs !== null)
                bits.push("metrics " + root.report.vm.latencyMs + "ms")
              return bits.join(" · ")
            }
            color: root.stale ? Color.urgent : Color.muted
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
