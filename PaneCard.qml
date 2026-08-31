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

  // Selecting a pane, and dragging a filled one onto another to swap them.
  MouseArea {
    id: cardMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: root.filled ? Qt.OpenHandCursor : Qt.PointingHandCursor
    drag.target: root.filled ? paneProxy : null
    onPressed: function(mouse) {
      if (root.host) root.host.select(root.path)
      if (!root.filled || !root.host || !root.host.dragLayer) return
      var point = mapToItem(root.host.dragLayer, mouse.x, mouse.y)
      paneProxy.x = point.x - paneProxy.width / 2
      paneProxy.y = point.y - paneProxy.height / 2
    }
    onReleased: if (paneProxy.Drag.active) paneProxy.Drag.drop()
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
  // resting canvas stays a clean picture of the layout.
  //
  // Explicitly above the whole-card MouseArea. Among siblings the last one
  // declared takes input first, so without this the card would swallow every
  // click meant for these buttons — which is what it did before the MouseArea
  // was moved above them.
  Row {
    z: 1
    anchors.top: parent.top
    anchors.right: parent.right
    anchors.margins: Style.space(4)
    spacing: Style.space(2)
    opacity: cardMouse.containsMouse || root.selected ? 1 : 0
    visible: opacity > 0 && root.roomy

    Behavior on opacity { NumberAnimation { duration: 110 } }

    Repeater {
      model: [
        { glyph: "◫", rotate: 0,  action: "split-v" },
        { glyph: "◫", rotate: 90, action: "split-h" },
        { glyph: "✕", rotate: 0,  action: "remove" }
      ]

      Rectangle {
        id: paneButton
        required property var modelData

        width: Style.space(18)
        height: Style.space(18)
        radius: Style.cornerRadius > 0 ? Style.space(4) : 0
        color: Util.alpha(Color.foreground, buttonMouse.containsMouse ? 0.18 : 0.08)

        Text {
          anchors.centerIn: parent
          text: paneButton.modelData.glyph
          rotation: paneButton.modelData.rotate
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        MouseArea {
          id: buttonMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (!root.host) return
            var action = paneButton.modelData.action
            if (action === "split-v") root.host.split(root.path, "v")
            else if (action === "split-h") root.host.split(root.path, "h")
            else root.host.remove(root.path)
          }
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

  DropArea {
    id: dropTarget
    anchors.fill: parent
    keys: ["wsp-app", "wsp-pane"]
    onDropped: function(drop) {
      if (!root.host || !drop.source) return

      if (drop.source.appEntryId !== undefined && String(drop.source.appEntryId) !== "") {
        root.host.assign(root.path, String(drop.source.appEntryId))
        drop.accept()
      } else if (drop.source.panePath !== undefined) {
        root.host.swap(drop.source.panePath, root.path)
        drop.accept()
      }
    }
  }
}
