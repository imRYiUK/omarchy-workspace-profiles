import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// The bar entry point: one icon, and the host for the editor panel.
//
// Left click opens the editor. Right click applies the active profile straight
// away — the common case once a profile is set up is wanting it, not wanting to
// look at it.
//
// Structure follows omarchy.clock's BarWidget: the panel is a child loaded
// internally and injected with the bar, and open/close/opened are forwarded
// from here because the bar's popout coordinator tracks the widget in the slot,
// not the panel nested inside it.
BarWidget {
  id: root
  moduleName: "io.github.imryiuk.workspace-profiles"

  readonly property string pluginDir: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string applyScript: pluginDir + "/bin/workspace-profiles-apply"

  readonly property bool showProfileName: setting("showProfileName", false) === true
  readonly property bool notifyOnApply: setting("notify", true) !== false

  // Filled in by the panel once it has read the store, so the bar can label
  // itself and the tooltip can name what a right click would launch.
  property string activeProfileName: ""

  readonly property string icon: "󰙀"
  readonly property string label: showProfileName && activeProfileName !== ""
    ? icon + "  " + activeProfileName
    : icon

  function applyActive() {
    var argv = [root.applyScript]
    if (!root.notifyOnApply) argv.push("--no-notify")
    Util.execArgv(argv)
  }

  // ---- Panel plumbing. The bar routes summon/hide/toggle through these, and
  //      Bar.findPanelWidget requires open/close/opened on the widget root.

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    panelLoader.active = true
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function togglePanel() {
    if (!panelLoader.active) {
      panelLoader.active = true
      Qt.callLater(function() { if (panelLoader.item) panelLoader.item.open() })
      return
    }
    if (panelLoader.item) panelLoader.item.toggle()
  }

  readonly property real openPanelIndicatorWidth: button.labelWidth
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

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

  // Loaded lazily: until the editor is opened for the first time this widget is
  // a single button and nothing else, which is the whole idle cost of the plugin.
  Loader {
    id: panelLoader
    active: false
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "io.github.imryiuk.workspace-profiles"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function applyActive(): void { root.applyActive() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.vertical ? "" : root.label
    labelVisible: !root.vertical
    hasVisualContent: true
    fixedWidth: root.vertical ? root.barSize : -1
    tooltipText: root.activeProfileName !== ""
      ? "Workspace Profiles — " + root.activeProfileName + " (right click to apply)"
      : "Workspace Profiles"

    onPressed: function(b) {
      if (b === Qt.RightButton) root.applyActive()
      else root.togglePanel()
    }

    // Vertical bars have an icon slot rather than a text label, so the glyph is
    // painted on its own instead of going through the button's label.
    OpticalGlyph {
      visible: root.vertical
      anchors.fill: parent
      text: root.icon
      fontFamily: button.fontFamily
      fontSize: button.fontSize
      color: button.foreground
    }
  }
}
