import QtQuick
import Quickshell
import qs.Commons
import "Model.js" as Model

// The layout canvas: a scale model of the workspace, where a pane's share of
// the canvas is its share of the screen.
//
// The tree is flattened into rectangles by Model.layoutRects and drawn as two
// flat lists — panes, then the dividers between them on top. Owning nothing
// matters here: the tree comes down from the panel and every edit goes straight
// back up as `treeEdited`, so there is one copy of the layout and it is the one
// that gets saved.
//
// This is also the interface PaneCard talks to. Keeping the callbacks here
// rather than passing the panel down means a pane only knows about editing a
// layout, not about profiles, files, or the bar.
Item {
  id: root

  property var tree: null
  property var selectedPath: []
  // Where drag proxies are parented so they float above the canvas instead of
  // being clipped by it. Supplied by the panel.
  property var dragLayer: null
  // function(desktopId) -> DesktopEntry or null, supplied by the panel.
  property var appLookup: null

  readonly property string selectedKey: selectedPath.join(".")
  readonly property int gap: Style.space(5)

  readonly property var rects: Model.layoutRects(
    tree, { x: 0, y: 0, w: Math.max(0, width), h: Math.max(0, height) }, gap)

  signal treeEdited(var next)
  signal selectionChanged(var path)

  // ---- what PaneCard calls

  function appName(id) {
    var entry = appLookup ? appLookup(id) : null
    return entry ? String(entry.name || entry.id || id) : String(id || "")
  }

  function appIcon(id) {
    var entry = appLookup ? appLookup(id) : null
    var icon = entry && entry.icon ? String(entry.icon) : ""
    if (icon === "") return Quickshell.iconPath("application-x-executable", true)
    if (icon.charAt(0) === "/") return Util.fileUrl(icon)
    var themed = Quickshell.iconPath(icon, true)
    return themed.length > 0 ? themed : Quickshell.iconPath("application-x-executable", true)
  }

  function select(path) {
    selectionChanged(path.slice())
  }

  // Splitting selects the new empty half — the next thing you want is an app in
  // it, and the app list assigns to whatever is selected.
  function split(path, dir) {
    treeEdited(Model.splitAt(tree, path, dir))
    selectionChanged(path.concat(["b"]))
  }

  function remove(path) {
    treeEdited(Model.removeAt(tree, path))
    selectionChanged(path.length ? path.slice(0, -1) : [])
  }

  function setRatio(path, ratio) {
    treeEdited(Model.setRatioAt(tree, path, ratio))
  }

  function assign(path, appId) {
    treeEdited(Model.setAppAt(tree, path, appId))
    selectionChanged(path.slice())
  }

  function setArgs(path, args) {
    treeEdited(Model.setArgsAt(tree, path, args))
  }

  function swap(from, to) {
    treeEdited(Model.swap(tree, from, to))
    selectionChanged(to.slice())
  }

  Repeater {
    model: root.rects.leaves

    PaneCard {
      required property var modelData

      pane: modelData
      host: root
      x: modelData.x
      y: modelData.y
      width: modelData.w
      height: modelData.h
    }
  }

  // Declared after the panes so they sit on top: a divider is only 5px wide and
  // its grab area deliberately overhangs the panes on either side.
  Repeater {
    model: root.rects.dividers

    Rectangle {
      id: divider
      required property var modelData

      readonly property bool vertical: modelData.dir === "v"

      x: modelData.x
      y: modelData.y
      width: modelData.w
      height: modelData.h
      radius: Style.cornerRadius > 0 ? root.gap / 2 : 0
      color: Util.alpha(Color.accent, dividerMouse.pressed ? 0.75 : (dividerMouse.containsMouse ? 0.4 : 0))

      Behavior on color { ColorAnimation { duration: 110 } }

      MouseArea {
        id: dividerMouse
        // Reaches past the painted divider so a 5px gap is still an easy
        // target; the extra width is invisible and overlaps the panes.
        anchors.centerIn: parent
        width: divider.vertical ? Math.max(divider.width, Style.space(11)) : divider.width
        height: divider.vertical ? divider.height : Math.max(divider.height, Style.space(11))
        hoverEnabled: true
        preventStealing: true
        cursorShape: divider.vertical ? Qt.SplitHCursor : Qt.SplitVCursor

        // Driven from the pointer's absolute position inside the split rather
        // than from a delta: the divider moves under the cursor as the ratio
        // changes, and re-deriving from where the cursor actually is keeps the
        // two from drifting apart over a long drag.
        function applyFromPoint(mx, my) {
          var point = mapToItem(root, mx, my)
          var span = divider.vertical ? divider.modelData.spanW : divider.modelData.spanH
          if (span <= 0) return
          var offset = divider.vertical
            ? point.x - divider.modelData.originX
            : point.y - divider.modelData.originY
          root.setRatio(divider.modelData.path, offset / span)
        }

        onPositionChanged: function(mouse) {
          if (pressed) applyFromPoint(mouse.x, mouse.y)
        }
        onDoubleClicked: root.setRatio(divider.modelData.path, 0.5)
      }
    }
  }
}
