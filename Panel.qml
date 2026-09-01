import QtQuick
import QtQuick.Layouts
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

  // ---- Palette (first-party panel idiom) --------------------------------

  readonly property color panelFg: Color.popups.text
  readonly property color dim: Qt.darker(panelFg, 1.55)
  readonly property color rowFill: Style.hoverFillFor(panelFg, Color.accent)

  // ---- Bar face ---------------------------------------------------------

  // nf-fa-server, written as an escape so tooling can never eat the PUA char.
  readonly property string barGlyph: "\uf233"
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
    // Only web URLs: xdg-open on an arbitrary scheme is a launcher.
    if (Model.safeDashboardUrl(dashboardUrl))
      Quickshell.execDetached(["xdg-open", dashboardUrl])
  }

  function copyPeerIp(peer) {
    if (peer && peer.ip) Quickshell.execDetached(["wl-copy", String(peer.ip)])
  }

  // Opens the user's default terminal already connected to the node. The
  // template is the user's own config; the peer-derived substitutions are
  // validated host-shaped values (Model.sshArgv) so a peer named like an
  // ssh option can never become one. Whitespace split is documented —
  // quoting inside the template is not supported.
  function sshInto(peer) {
    if (!peer || !peer.online || peer.self) return
    var template = (report && report.sshCommand) ? report.sshCommand : "ssh {name}"
    var parts = Model.sshArgv(template, peer)
    if (parts !== null)
      Quickshell.execDetached(["omarchy-launch-terminal"].concat(parts))
  }

  // ---- Keyboard cursor over the node rows (Omarchy is keyboard-first) ----

  property int cursorIndex: -1

  function moveCursor(delta) {
    if (peers.length === 0) return
    if (cursorIndex < 0) cursorIndex = delta > 0 ? 0 : peers.length - 1
    else cursorIndex = Math.max(0, Math.min(peers.length - 1, cursorIndex + delta))
  }

  function cursorPeer() {
    return (cursorIndex >= 0 && cursorIndex < peers.length) ? peers[cursorIndex] : null
  }

  // ---- Sentinel: desktop notification on severity transitions ------------

  // "" = no report seen yet: the first report sets the baseline silently, so
  // a shell restart during an ongoing incident doesn't re-announce it.
  property string lastNotifiedSeverity: ""
  property string lastFingerprint: ""
  property bool baselineSet: false
  property double lastNotifyMs: 0

  function maybeNotify() {
    if (!summary) return
    var sev = summary.severity
    var fingerprint = Model.issueFingerprint(report)
    if (!baselineSet) {
      baselineSet = true
      lastNotifiedSeverity = sev
      lastFingerprint = fingerprint
      return
    }
    // Notify on a severity change OR on a different set of offenders at the
    // same severity — studio2 going down while disk already warns still
    // deserves a ping.
    if (sev === lastNotifiedSeverity && fingerprint === lastFingerprint) return
    var previous = lastNotifiedSeverity
    lastNotifiedSeverity = sev
    lastFingerprint = fingerprint
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
    cursorIndex = -1
    setCenterHoverRevealSuppressed(false)
    root.controller.show()
    root.refresh()
  }

  function openFromHotkey() {
    openedFromHotkey = true
    cursorIndex = -1
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

  // Watchdog: the collector bounds every source with its own timeout, but a
  // wedged python process would otherwise hold `running` forever and block
  // all future refreshes. 60s is several times the worst honest run.
  Timer {
    interval: 60000
    running: collectorProc.running
    onTriggered: {
      collectorProc.running = false
      root.collectorError = "collector killed after 60s watchdog"
    }
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
    contentWidth: panel.fittedContentWidth(Style.space(490))
    contentHeight: panel.fittedContentHeight(fleetColumn.implicitHeight + Style.space(32))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: root.sshInto(root.cursorPeer())
      onReturnRequested: root.sshInto(root.cursorPeer())
      onTextKey: function(t) {
        if (t === "j") root.moveCursor(1)
        else if (t === "k") root.moveCursor(-1)
        else if (t === "c") root.copyPeerIp(root.cursorPeer())
        else if (t === "s") root.sshInto(root.cursorPeer())
        else if (t === "r") root.refresh()
        else if (t === "g") root.openDashboard()
      }

      Flickable {
        id: fleetScroll
        anchors.fill: parent
        anchors.margins: Style.space(16)
        contentWidth: width
        contentHeight: fleetColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: fleetColumn
          width: fleetScroll.width
          spacing: Style.space(10)

          // ---- Hero: big glyph + live counts on the left, fleet identity
          //      and actions on the right (weather-hero idiom).
          Item {
            width: parent.width
            height: Math.max(heroLeft.implicitHeight, heroRight.implicitHeight) + Style.space(6)

            Row {
              id: heroLeft
              anchors.left: parent.left
              anchors.leftMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(14)

              Text {
                id: heroGlyph
                text: root.barGlyph
                color: root.severityColor(root.severity, root.panelFg)
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                // Hero mark; deliberately outside the Style.font.* scale,
                // like the weather hero's condition glyph.
                font.pixelSize: 44
                anchors.verticalCenter: parent.verticalCenter

                // Critical state breathes; calm states hold still.
                SequentialAnimation on opacity {
                  running: root.severity === "crit" && root.opened
                  loops: Animation.Infinite
                  NumberAnimation { to: 0.45; duration: 700; easing.type: Easing.InOutSine }
                  NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                  onRunningChanged: if (!running) heroGlyph.opacity = 1
                }
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Text {
                  text: root.summary && root.summary.peersTotal > 0
                    ? root.summary.peersOnline + "/" + root.summary.peersTotal : "—"
                  color: root.panelFg
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: 34
                  font.bold: true
                }

                Text {
                  text: "NODES ONLINE"
                  color: root.dim
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
              }

              Column {
                visible: root.summary !== null && root.summary.issues > 0
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Text {
                  text: root.summary ? "!" + root.summary.issues : ""
                  color: root.severityColor(root.severity, root.panelFg)
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: 34
                  font.bold: true
                }

                Text {
                  text: root.summary && root.summary.issues === 1 ? "ISSUE" : "ISSUES"
                  color: root.dim
                  font.family: root.bar ? root.bar.fontFamily : Style.font.family
                  font.pixelSize: Style.font.caption
                  font.letterSpacing: 1
                }
              }
            }

            Column {
              id: heroRight
              anchors.right: parent.right
              anchors.rightMargin: Style.space(2)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(6)

              Text {
                text: root.fleetName.toUpperCase()
                color: root.dim
                font.family: root.bar ? root.bar.fontFamily : Style.font.family
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                anchors.right: parent.right
              }

              Row {
                anchors.right: parent.right
                spacing: Style.space(2)

                PanelActionButton {
                  iconText: "󰑐"
                  tooltipText: "Refresh"
                  foreground: root.panelFg
                  fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                  onClicked: root.refresh()
                }

                PanelActionButton {
                  visible: root.dashboardUrl !== ""
                  iconText: "󰖟"
                  tooltipText: "Open dashboard"
                  foreground: root.panelFg
                  fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                  onClicked: root.openDashboard()
                }
              }
            }
          }

          // ---- Gaps first: every source failure renders before any data.
          Rectangle {
            visible: root.reportErrors.length > 0 || root.collectorError !== ""
            width: parent.width
            implicitHeight: errorColumn.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
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

          PanelSectionHeader {
            visible: root.peers.length > 0
            text: "NODES"
          }

          Column {
            width: parent.width
            spacing: 0

            Repeater {
              model: root.peers

              CursorSurface {
                id: nodeRow
                required property var modelData
                required property int index
                readonly property string state: Model.peerState(modelData)
                readonly property color dotColor: state === "online" ? Color.accent
                  : state === "offline-expected" ? Color.urgent : root.dim

                width: parent.width
                implicitHeight: nodeInner.implicitHeight + Style.spacing.xl
                radius: Style.cornerRadius
                foreground: root.panelFg
                hasCursor: nodeMouse.containsMouse || root.cursorIndex === index

                MouseArea {
                  id: nodeMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: nodeRow.modelData.ip ? Qt.PointingHandCursor : Qt.ArrowCursor
                  onClicked: root.copyPeerIp(nodeRow.modelData)
                }

                RowLayout {
                  id: nodeInner
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(6)
                  spacing: Style.space(10)

                  Item {
                    width: Style.space(8)
                    height: width
                    Layout.alignment: Qt.AlignVCenter

                    Rectangle {
                      id: nodeDot
                      anchors.centerIn: parent
                      width: Style.space(7)
                      height: width
                      radius: width / 2
                      color: nodeRow.dotColor

                      // Live nodes breathe softly while the panel is open —
                      // the fleet reads as alive, not as a table.
                      SequentialAnimation on opacity {
                        running: nodeRow.modelData.online && root.opened
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.4; duration: 1600; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1.0; duration: 1600; easing.type: Easing.InOutSine }
                        onRunningChanged: if (!running) nodeDot.opacity = 1
                      }
                    }
                  }

                  Text {
                    text: Model.osIcon(nodeRow.modelData.os)
                    color: root.dim
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.icon
                    Layout.alignment: Qt.AlignVCenter
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(1)

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: nodeRow.modelData.name + (nodeRow.modelData.self ? "  (this)" : "")
                      color: nodeRow.modelData.online ? root.panelFg : root.dim
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: Model.peerDetail(nodeRow.modelData)
                      color: nodeRow.state === "offline-expected"
                        ? root.mix(root.dim, Color.urgent, 0.6) : root.dim
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  ColumnLayout {
                    visible: latencyText.text !== "" || statsRow.visible
                    spacing: Style.space(1)
                    Layout.alignment: Qt.AlignVCenter

                    Text {
                      id: latencyText
                      visible: text !== ""
                      textFormat: Text.PlainText
                      text: Model.peerBadge(nodeRow.modelData)
                      color: root.dim
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                      Layout.alignment: Qt.AlignRight
                    }

                    // Live utilization badges. Purely informational: their
                    // colors follow the configured stat thresholds, but they
                    // never feed the fleet severity — checks do the alerting.
                    Row {
                      id: statsRow
                      readonly property var stats: nodeRow.modelData.stats || null
                      visible: stats !== null
                      spacing: Style.space(6)
                      Layout.alignment: Qt.AlignRight

                      Text {
                        visible: statsRow.stats && statsRow.stats.cpu !== undefined
                        textFormat: Text.PlainText
                        text: statsRow.stats && statsRow.stats.cpu ? "\uf2db " + statsRow.stats.cpu.display : ""
                        color: statsRow.stats && statsRow.stats.cpu
                          ? (statsRow.stats.cpu.severity === "ok" ? root.dim
                             : root.severityColor(statsRow.stats.cpu.severity, root.panelFg))
                          : root.dim
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                      }

                      Text {
                        visible: statsRow.stats && statsRow.stats.mem !== undefined
                        textFormat: Text.PlainText
                        text: statsRow.stats && statsRow.stats.mem ? "\udb80\udf5b " + statsRow.stats.mem.display : ""
                        color: statsRow.stats && statsRow.stats.mem
                          ? (statsRow.stats.mem.severity === "ok" ? root.dim
                             : root.severityColor(statsRow.stats.mem.severity, root.panelFg))
                          : root.dim
                        font.family: root.bar ? root.bar.fontFamily : Style.font.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }

                  PanelActionButton {
                    visible: nodeRow.modelData.online && !nodeRow.modelData.self
                    iconText: ""
                    tooltipText: "SSH to " + nodeRow.modelData.name
                    foreground: root.panelFg
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.sshInto(nodeRow.modelData)
                  }

                  PanelActionButton {
                    visible: nodeRow.modelData.ip !== ""
                    iconText: "󰆏"
                    tooltipText: "Copy " + nodeRow.modelData.ip
                    foreground: root.panelFg
                    fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                    Layout.alignment: Qt.AlignVCenter
                    onClicked: root.copyPeerIp(nodeRow.modelData)
                  }
                }
              }
            }
          }

          PanelSectionHeader {
            visible: root.checks.length > 0
            text: "CHECKS"
          }

          Column {
            width: parent.width
            spacing: 0

            Repeater {
              model: root.checks

              Item {
                id: checkRow
                required property var modelData
                width: parent.width
                implicitHeight: checkInner.implicitHeight + Style.spacing.xl

                RowLayout {
                  id: checkInner
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(10)

                  Rectangle {
                    id: checkDot
                    width: Style.space(7)
                    height: width
                    radius: width / 2
                    color: root.severityColor(checkRow.modelData.severity, Color.accent)
                    Layout.alignment: Qt.AlignVCenter

                    SequentialAnimation on opacity {
                      running: checkRow.modelData.severity === "crit" && root.opened
                      loops: Animation.Infinite
                      NumberAnimation { to: 0.4; duration: 700; easing.type: Easing.InOutSine }
                      NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                      onRunningChanged: if (!running) checkDot.opacity = 1
                    }
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(1)

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      text: checkRow.modelData.name
                      color: root.panelFg
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }

                    Text {
                      Layout.fillWidth: true
                      textFormat: Text.PlainText
                      visible: text !== ""
                      text: Model.checkDetail(checkRow.modelData)
                      color: checkRow.modelData.severity === "ok" ? root.dim
                        : root.severityColor(checkRow.modelData.severity, root.dim)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  // Worst-direction trend over the configured history span.
                  Canvas {
                    id: spark
                    visible: (checkRow.modelData.history || []).length >= 2
                    width: Style.space(56)
                    height: Style.space(14)
                    Layout.alignment: Qt.AlignVCenter
                    antialiasing: true

                    readonly property var trace: checkRow.modelData.history || []
                    readonly property color lineColor: root.tinted(
                      root.severityColor(checkRow.modelData.severity, root.panelFg),
                      checkRow.modelData.severity === "ok" ? 0.55 : 0.9)

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

                  Text {
                    textFormat: Text.PlainText
                    text: Model.checkHeadline(checkRow.modelData)
                    color: checkRow.modelData.severity === "ok" ? root.dim
                      : root.severityColor(checkRow.modelData.severity, root.panelFg)
                    font.family: root.bar ? root.bar.fontFamily : Style.font.family
                    font.pixelSize: Style.font.caption
                    Layout.alignment: Qt.AlignVCenter
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
            color: root.stale ? Color.urgent : root.dim
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }

          Text {
            width: parent.width
            text: "j/k move  \u23ce ssh  c copy ip  r refresh  g dashboard"
            color: root.tinted(root.dim, 0.75)
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
