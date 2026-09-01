import QtQuick
import qs.Commons
import qs.Ui

// Fleetbar bar widget: thin host following the first-party weather pattern —
// the button lives here, all data and the detail panel live in Panel.qml
// (loaded once, shared identity for the bar's popout coordinator).
BarWidget {
  id: root
  moduleName: "stratoforce.fleetbar"

  readonly property var panelItem: panelLoader.item
  readonly property string barText: {
    if (!panelItem) return ""
    var label = panelItem.barLabel
    return panelItem.barGlyph + (label !== "" && !root.vertical ? " " + label : "")
  }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelItem && panelItem.refresh) panelItem.refresh()
  }

  function togglePanel() {
    if (panelItem && panelItem.toggle) panelItem.toggle()
  }

  // Shape contract for shell summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelItem ? panelItem.opened === true : false

  function open() {
    if (panelItem && panelItem.openFromHotkey) panelItem.openFromHotkey()
  }

  function close() {
    if (panelItem && panelItem.close) panelItem.close()
  }

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity (Bar.requestPopout prefers closeForPopoutSwitch over close).
  readonly property bool popoutSwitchClosing: panelItem ? panelItem.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelItem) panelItem.closeForPopoutSwitch()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barText
    // Severity rides the foreground blend computed by the panel; dimming is
    // never used, so the glyph stays legible in every theme.
    foreground: root.panelItem ? root.panelItem.barColor
      : (root.bar ? root.bar.barForeground : Color.foreground)
    tooltipText: root.panelItem && root.panelItem.summary
      ? root.panelItem.fleetName + ": " + root.panelItem.severity : "Fleetbar"

    onPressed: function(b) {
      if (b === Qt.RightButton) { if (root.panelItem) root.panelItem.openDashboard() }
      else if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
