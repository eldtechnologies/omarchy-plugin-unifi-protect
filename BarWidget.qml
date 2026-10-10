import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar entry for UniFi Protect.
//
// A single camera glyph. It turns the bar's urgent colour when a camera is
// offline, and carries a quiet dot when the console could not be reached on
// the last poll. Everything else lives in the panel.
BarWidget {
  id: root
  moduleName: "com.eldtechnologies.unifi-protect"

  readonly property bool configured: panelLoader.item ? panelLoader.item.configured : false
  readonly property bool healthy: panelLoader.item ? panelLoader.item.healthy : true
  readonly property bool stale: panelLoader.item ? panelLoader.item.stale : false

  // nf-fa-video_camera
  readonly property string icon: ""

  // Shape contract for Bar.findPanelWidget popout routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true : false

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }
  function toggle() { togglePanel() }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }
  function refresh() { if (panelLoader.item) panelLoader.item.reloadState() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
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

  IpcHandler {
    target: "com.eldtechnologies.unifi-protect"

    function refresh(): void { root.refresh() }
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    // Fullscreen grid of every visible camera; calling again closes it.
    function wall(): void {
      Quickshell.execDetached([decodeURIComponent(String(Qt.resolvedUrl("bin/eld-unifi-protect"))
                                 .replace("file://", "")), "wall", "--mode",
                               root.setting("wallMode", "window") === "overlay" ? "overlay" : "window"])
    }
    // Jump straight into a camera's live view, e.g. from a keybinding:
    //   omarchy-shell com.eldtechnologies.unifi-protect live "Front Door"
    function live(name: string): void {
      if (panelLoader.item) panelLoader.item.openLiveByName(name)
    }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.configured ? root.icon : root.icon + "  setup"
    labelVisible: true
    hasVisualContent: text !== ""
    horizontalMargin: 9.625
    verticalPadding: 8.75

    active: !root.healthy && root.configured
    useActiveColor: true

    tooltipText: panelLoader.item ? panelLoader.item.barTooltip : "UniFi Protect"

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.togglePanel()
      else if (buttonCode === Qt.MiddleButton) root.refresh()
      else if (buttonCode === Qt.RightButton && panelLoader.item)
        panelLoader.item.openConsole()
    }

    Rectangle {
      visible: root.stale && root.configured
      width: Style.space(5)
      height: width
      radius: width / 2
      color: root.bar ? root.bar.urgent : Color.urgent
      opacity: 0.8
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.rightMargin: Style.space(2)
      anchors.topMargin: Style.space(2)
    }
  }
}
