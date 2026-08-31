import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// One pane on the layout canvas: the app that will open there, or an empty slot
// waiting for one.
//
// Positioned by the LayoutEditor from a rectangle computed off the tree, so a
// pane's share of the canvas is its share of the screen. Every edit is a call
// back into `host` — the card never touches the tree itself.
Item {
  id: root

  // { key, path, node, x, y, w, h } from Model.layoutRects
  property var pane: null
  property var host: null

  readonly property var path: pane ? pane.path : []
  readonly property string appId: pane && pane.node ? String(pane.node.app || "") : ""
  readonly property string appArgs: pane && pane.node ? String(pane.node.args || "") : ""
  readonly property string appLabel: host ? host.appName(appId) : appId
  readonly property bool filled: appId !== ""
  readonly property bool selected: !!host && !!pane && host.selectedKey === pane.key
  readonly property bool roomy: width > Style.space(70) && height > Style.space(40)
  // Which side of this pane an incoming drag would take, from where the pointer
  // is over it. The four edges are the four triangles the diagonals cut the pane
  // into, so aiming at a side is aiming at the half that side will become; the
  // middle is the one gesture that does not split, replacing what is here.
  function zoneAt(px, py) {
    if (!filled || width <= 0 || height <= 0) return "centre"

    var nx = px / width
    var ny = py / height
    if (Math.abs(nx - 0.5) < 0.18 && Math.abs(ny - 0.5) < 0.18) return "centre"

    var zone = "top"
    var nearest = ny
    if (1 - ny < nearest) { zone = "bottom"; nearest = 1 - ny }
    if (nx < nearest) { zone = "left"; nearest = nx }
    if (1 - nx < nearest) { zone = "right"; nearest = 1 - nx }
    return zone
  }

  // "", "ok", or "failed" — the result for this pane from the last test run.
  readonly property string testState: host && pane ? host.testState(pane.key) : ""

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: root.filled
      ? Util.alpha(Color.foreground, root.selected ? 0.14 : (cardMouse.containsMouse ? 0.10 : 0.06))
      : Util.alpha(Color.foreground, dropTarget.containsDrag ? 0.10 : 0.02)
    border.width: 1
    border.color: dropTarget.containsDrag
      ? Color.accent
      : (root.selected ? Util.alpha(Color.accent, 0.9) : Util.alpha(Color.foreground, root.filled ? 0.22 : 0.14))

    Behavior on color { ColorAnimation { duration: 110 } }
    Behavior on border.color { ColorAnimation { duration: 110 } }
  }

  // One MouseArea for the whole card — selection, dragging, and the hover
  // controls all come through here.
  //
  // The buttons deliberately have no MouseArea of their own. When they did, each
  // one consumed hover on the way past, so the card stopped counting as hovered,
  // so the row hid itself, so the card counted as hovered again: the pointer
  // sat there flickering between two cursors several times a second. With a
  // single area and a hit test there is nothing to compete with.
  MouseArea {
    id: cardMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: hoveredAction !== ""
      ? Qt.PointingHandCursor
      : (root.filled ? Qt.OpenHandCursor : Qt.PointingHandCursor)

    // Which control the pointer is over, "" for none. Recomputed on movement
    // rather than bound, because a MouseArea only reports a position while the
    // pointer is inside it.
    property string hoveredAction: ""

    function actionAt(mx, my) {
      if (!controls.visible) return ""
      var local = mapToItem(controls, mx, my)
      for (var i = 0; i < controls.children.length; i++) {
        var button = controls.children[i]
        if (button.action === undefined) continue
        if (local.x >= button.x && local.x <= button.x + button.width
          && local.y >= button.y && local.y <= button.y + button.height) return button.action
      }
      return ""
    }

    // A press on a control must not also start dragging the pane away.
    drag.target: root.filled && hoveredAction === "" ? paneProxy : null

    onPositionChanged: function(mouse) { hoveredAction = actionAt(mouse.x, mouse.y) }
    onExited: hoveredAction = ""

    onPressed: function(mouse) {
      hoveredAction = actionAt(mouse.x, mouse.y)
      if (hoveredAction !== "") return

      if (root.host) root.host.select(root.path)
      if (!root.filled || !root.host || !root.host.dragLayer) return
      var point = mapToItem(root.host.dragLayer, mouse.x, mouse.y)
      paneProxy.x = point.x - paneProxy.width / 2
      paneProxy.y = point.y - paneProxy.height / 2
    }

    onReleased: if (paneProxy.Drag.active) paneProxy.Drag.drop()

    onClicked: function(mouse) {
      var action = actionAt(mouse.x, mouse.y)
      if (action === "" || !root.host) return
      if (action === "split-v") root.host.split(root.path, "v")
      else if (action === "split-h") root.host.split(root.path, "h")
      else root.host.remove(root.path)
    }
  }

  // Empty pane: says what to do with it rather than sitting there blank.
  Column {
    anchors.centerIn: parent
    visible: !root.filled
    spacing: Style.space(3)
    opacity: 0.55

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: "＋"
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
    }

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: root.width > Style.space(90)
      text: "drop an app"
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  // Filled pane: icon, name, and the arguments underneath when they fit.
  Column {
    anchors.centerIn: parent
    width: root.width - Style.space(16)
    visible: root.filled
    spacing: Style.space(4)

    Image {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: root.height > Style.space(64)
      source: root.host ? root.host.appIcon(root.appId) : ""
      sourceSize.width: Style.space(26)
      sourceSize.height: Style.space(26)
      width: Style.space(26)
      height: visible ? Style.space(26) : 0
      fillMode: Image.PreserveAspectFit
      smooth: true
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      text: root.appLabel
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      maximumLineCount: 1
    }

    Text {
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      visible: text !== "" && root.height > Style.space(46)
      height: visible ? implicitHeight : 0
      text: root.appArgs
      color: Util.alpha(Color.foreground, 0.55)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
      maximumLineCount: 1
    }
  }

  // Whether this app actually opened a window the last time the profile was
  // tested. Sits opposite the hover controls so the two never overlap.
  Rectangle {
    visible: root.testState !== ""
    anchors.top: parent.top
    anchors.left: parent.left
    anchors.margins: Style.space(4)
    width: Style.space(18)
    height: Style.space(18)
    radius: width / 2
    color: root.testState === "ok" ? Util.alpha(Color.foreground, 0.12) : Util.alpha(Color.urgent, 0.25)

    Text {
      anchors.centerIn: parent
      text: root.testState === "ok" ? "✓" : "!"
      color: root.testState === "ok" ? Color.foreground : Color.urgent
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  // Hover controls, top-right. Hidden until the pointer is on the pane so the
  // resting canvas stays a clean picture of the layout. Purely visual — the
  // card's MouseArea does the hit testing, see the note there.
  Row {
    id: controls
    z: 1
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.margins: Style.space(4)
    spacing: Style.space(2)
    visible: root.roomy && (cardMouse.containsMouse || root.selected)
    opacity: visible ? 1 : 0

    Behavior on opacity { NumberAnimation { duration: 110 } }

    Repeater {
      model: [
        { glyph: "◫", rotate: 0,  name: "split-v" },
        { glyph: "◫", rotate: 90, name: "split-h" },
        { glyph: "✕", rotate: 0,  name: "remove" }
      ]

      Rectangle {
        id: paneButton
        required property var modelData

        // Read back by cardMouse.actionAt to work out what was clicked.
        readonly property string action: paneButton.modelData.name

        width: Style.space(18)
        height: Style.space(18)
        radius: Style.cornerRadius > 0 ? Style.space(4) : 0
        color: Util.alpha(Color.foreground,
          cardMouse.hoveredAction === paneButton.action ? 0.22 : 0.08)

        Behavior on color { ColorAnimation { duration: 90 } }

        Text {
          anchors.centerIn: parent
          text: paneButton.modelData.glyph
          rotation: paneButton.modelData.rotate
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // The thing that actually gets dragged. It lives in the panel's drag layer,
  // not in this pane, so it is not clipped by the canvas and can be dropped
  // anywhere in the editor.
  Item {
    id: paneProxy
    parent: root.host ? root.host.dragLayer : null
    width: Style.space(150)
    height: Style.space(30)
    visible: Drag.active
    z: 10

    property var panePath: root.path

    Drag.active: cardMouse.drag.active
    Drag.keys: ["wsp-pane"]
    Drag.hotSpot.x: width / 2
    Drag.hotSpot.y: height / 2

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: Util.alpha(Color.background, 0.95)
      border.width: 1
      border.color: Color.accent

      Text {
        anchors.centerIn: parent
        width: parent.width - Style.space(16)
        horizontalAlignment: Text.AlignHCenter
        text: root.appLabel
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        elide: Text.ElideRight
      }
    }
  }

  // Shows the space the incoming pane would take before it is dropped, so the
  // split is chosen by aiming rather than by remembering the rule. A whole-pane
  // highlight means the middle: replace, not split.
  Rectangle {
    z: 2
    visible: dropTarget.containsDrag
    radius: Style.cornerRadius
    color: Util.alpha(Color.accent, 0.22)
    border.width: 1
    border.color: Color.accent

    x: dropTarget.zone === "right" ? root.width / 2 : 0
    y: dropTarget.zone === "bottom" ? root.height / 2 : 0
    width: dropTarget.zone === "left" || dropTarget.zone === "right" ? root.width / 2 : root.width
    height: dropTarget.zone === "top" || dropTarget.zone === "bottom" ? root.height / 2 : root.height

    Behavior on x { NumberAnimation { duration: 90 } }
    Behavior on y { NumberAnimation { duration: 90 } }
    Behavior on width { NumberAnimation { duration: 90 } }
    Behavior on height { NumberAnimation { duration: 90 } }
  }

  DropArea {
    id: dropTarget
    anchors.fill: parent
    keys: ["wsp-app", "wsp-pane"]

    property string zone: "centre"

    onEntered: function(drag) { zone = root.zoneAt(drag.x, drag.y) }
    onPositionChanged: function(drag) { zone = root.zoneAt(drag.x, drag.y) }

    onDropped: function(drop) {
      if (!root.host || !drop.source) return

      var where = root.zoneAt(drop.x, drop.y)
      var dir = where === "top" || where === "bottom" ? "h" : "v"
      var before = where === "top" || where === "left"

      if (drop.source.appEntryId !== undefined && String(drop.source.appEntryId) !== "") {
        var appId = String(drop.source.appEntryId)
        if (where === "centre") root.host.replaceApp(root.path, appId)
        else root.host.assign(root.path, appId, dir, before)
        drop.accept()
      } else if (drop.source.panePath !== undefined) {
        if (where === "centre") root.host.swap(drop.source.panePath, root.path)
        else root.host.movePane(drop.source.panePath, root.path, dir, before)
        drop.accept()
      }
    }
  }
}
