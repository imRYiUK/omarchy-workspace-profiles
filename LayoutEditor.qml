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
  // { "<paneKey>": true|false } from the last test run of this workspace.
  property var testPanes: ({})

  readonly property string selectedKey: selectedPath.join(".")
  readonly property int gap: Style.space(5)

  readonly property var rects: Model.layoutRects(
    tree, { x: 0, y: 0, w: Math.max(0, width), h: Math.max(0, height) }, gap)

  // Key of the divider being dragged right now, for the delegate to paint.
  property string resizingKey: ""

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

  // Flips the split this pane sits in, so two columns become two rows. It acts
  // on the parent: the pane itself is a leaf and has no direction to flip.
  function flip(path) {
    if (!path || !path.length) return
    treeEdited(Model.flipAt(tree, path.slice(0, -1)))
  }

  function setRatio(path, ratio) {
    treeEdited(Model.setRatioAt(tree, path, ratio))
  }

  // The shape of the pane on screen decides which way it splits: a pane wider
  // than it is tall becomes two columns, a taller one becomes two rows. Three
  // apps in a row would otherwise end up as three thin columns, when what the
  // third one wants is the bottom half of the second.
  function splitDirectionFor(key) {
    var leaves = rects.leaves
    for (var i = 0; i < leaves.length; i++) {
      if (leaves[i].key === key) return leaves[i].w >= leaves[i].h ? "v" : "h"
    }
    return "v"
  }

  // An empty pane takes the app; a pane that already has one is split, so a
  // click never costs you a pane you had set up. Selection follows the app to
  // wherever it ended up.
  // `dir` and `before` come from the drop zone when there was one. A click from
  // the app list has no zone, so the pane's own shape decides.
  function assign(path, appId, dir, before) {
    var direction = dir === undefined ? splitDirectionFor(path.join(".")) : dir
    var result = Model.assignApp(tree, path, appId, direction, before === true)
    treeEdited(result.tree)
    selectionChanged(result.path)
  }

  function replaceApp(path, appId) {
    treeEdited(Model.setAppAt(tree, path, appId))
    selectionChanged(path.slice())
  }

  function movePane(from, to, dir, before) {
    var result = Model.movePane(tree, from, to, dir, before === true)
    treeEdited(result.tree)
    selectionChanged(result.path)
  }

  function testState(key) {
    if (!testPanes || testPanes[key] === undefined) return ""
    return testPanes[key] ? "ok" : "failed"
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
  //
  // The delegate paints and reports hover, and nothing more. It cannot own the
  // drag: `rects` is rebuilt from the tree on every ratio change, so each step
  // of a drag replaces this Repeater's model with a fresh array and every
  // delegate under it is destroyed and remade -- taking the grab with it. That
  // is why the drag lives on `resizer` below, which outlives the rebuild.
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
      // Faint but present at rest. At alpha 0 a divider could only be found by
      // sweeping the pointer and watching for the cursor to change, which made
      // resizing a hunt and lit up every pane it crossed on the way.
      color: Util.alpha(Color.accent,
        root.resizingKey === divider.modelData.key ? 0.75
          : (dividerHover.containsMouse ? 0.4 : 0.16))

      Behavior on color { ColorAnimation { duration: 110 } }

      // Hover only, so it never holds a press it could be destroyed still
      // holding. Reaches past the painted divider so a 5px gap is still an easy
      // target; the extra width is invisible and overlaps the panes.
      MouseArea {
        id: dividerHover
        anchors.centerIn: parent
        width: divider.vertical ? Math.max(divider.width, Style.space(16)) : divider.width
        height: divider.vertical ? divider.height : Math.max(divider.height, Style.space(16))
        acceptedButtons: Qt.NoButton
        hoverEnabled: true
        cursorShape: divider.vertical ? Qt.SplitHCursor : Qt.SplitVCursor
      }
    }
  }

  // The drag itself, owned by the canvas rather than by any delegate.
  //
  // Hover stays off here so the panes underneath keep receiving it -- their
  // control rows depend on it -- and a press that is not on a divider is
  // declined outright, so selecting, dragging and dropping panes are untouched.
  MouseArea {
    id: resizer
    anchors.fill: parent
    z: 3
    hoverEnabled: false
    preventStealing: true
    acceptedButtons: Qt.LeftButton

    // A copy, not a reference into `rects`: that array is replaced on every
    // step of the drag, while the split's own rectangle does not move, so the
    // numbers captured at press stay right for the whole gesture.
    property var active: null

    function dividerAt(mx, my) {
      var band = Style.space(16)
      var list = root.rects.dividers

      for (var i = 0; i < list.length; i++) {
        var d = list[i]
        var vertical = d.dir === "v"
        var x0 = vertical ? d.x + d.w / 2 - band / 2 : d.x
        var x1 = vertical ? d.x + d.w / 2 + band / 2 : d.x + d.w
        var y0 = vertical ? d.y : d.y + d.h / 2 - band / 2
        var y1 = vertical ? d.y + d.h : d.y + d.h / 2 + band / 2
        if (mx >= x0 && mx <= x1 && my >= y0 && my <= y1) return d
      }
      return null
    }

    // Driven from the pointer's absolute position inside the split rather than
    // from a delta, so the divider cannot drift away from the cursor over a
    // long drag. The arithmetic is the inverse of layoutRects: it lays the
    // first half across `span - gap` and puts the divider's near edge at the
    // end of it, so reading a ratio back off the full span, from a pointer
    // sitting at the divider's centre, lands short by half a gap.
    function applyFromPoint(mx, my) {
      var d = resizer.active
      if (!d) return

      var vertical = d.dir === "v"
      var span = (vertical ? d.spanW : d.spanH) - root.gap
      if (span <= 0) return

      var offset = (vertical ? mx - d.originX : my - d.originY) - root.gap / 2
      root.setRatio(d.path, offset / span)
    }

    onPressed: function(mouse) {
      var hit = dividerAt(mouse.x, mouse.y)
      if (!hit) { mouse.accepted = false; return }

      resizer.active = {
        path: hit.path, dir: hit.dir, key: hit.key,
        originX: hit.originX, originY: hit.originY,
        spanW: hit.spanW, spanH: hit.spanH
      }
      root.resizingKey = hit.key
    }

    onPositionChanged: function(mouse) {
      if (pressed) applyFromPoint(mouse.x, mouse.y)
    }

    onReleased: { resizer.active = null; root.resizingKey = "" }
    onCanceled: { resizer.active = null; root.resizingKey = "" }

    onDoubleClicked: function(mouse) {
      var hit = dividerAt(mouse.x, mouse.y)
      if (hit) root.setRatio(hit.path, 0.5)
      else mouse.accepted = false
    }
  }
}
