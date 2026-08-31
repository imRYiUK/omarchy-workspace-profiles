import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The app list down the left of the editor: a search box over the desktop
// entries, and a row per match that can be clicked onto the selected pane or
// dragged onto any pane.
//
// Both gestures exist because both are natural here. Dragging is the obvious
// one when you are looking at the layout and know where the app goes; clicking
// is faster when you are filling panes in order and never take your hands off
// the keyboard.
Item {
  id: root

  property var dragLayer: null
  property alias searchField: search
  property alias query: search.text

  // [{ id, name, icon }], filtered and sorted by the panel.
  property var entries: []

  signal activated(string appId)

  Column {
    anchors.fill: parent
    spacing: Style.space(8)

    TextField {
      id: search
      width: parent.width
      placeholderText: "Search apps…"
      font.pixelSize: Style.font.bodySmall

      // Enter assigns the top match, so a pane can be filled without ever
      // reaching for the mouse.
      onAccepted: {
        if (root.entries.length > 0) root.activated(String(root.entries[0].id))
      }
    }

    Text {
      id: emptyLabel
      width: parent.width
      visible: root.entries.length === 0
      text: search.text === "" ? "No applications found." : "Nothing matches “" + search.text + "”."
      color: Util.alpha(Color.foreground, 0.55)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      wrapMode: Text.WordWrap
    }

    ListView {
      id: list
      width: parent.width
      height: parent.height - search.height - Style.space(8)
              - (emptyLabel.visible ? emptyLabel.height + Style.space(8) : 0)
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      model: root.entries
      spacing: Style.space(1)
      cacheBuffer: Style.space(200)

      delegate: Item {
        id: row
        required property var modelData

        width: list.width
        height: Style.space(30)

        Rectangle {
          anchors.fill: parent
          anchors.rightMargin: Style.space(4)
          radius: Style.cornerRadius > 0 ? Style.space(4) : 0
          color: Util.alpha(Color.foreground, rowMouse.containsMouse ? 0.10 : 0)
          Behavior on color { ColorAnimation { duration: 100 } }
        }

        Row {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.rightMargin: Style.space(10)
          anchors.leftMargin: Style.space(6)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(8)

          Image {
            anchors.verticalCenter: parent.verticalCenter
            source: row.modelData.icon
            sourceSize.width: Style.space(18)
            sourceSize.height: Style.space(18)
            width: Style.space(18)
            height: Style.space(18)
            fillMode: Image.PreserveAspectFit
            smooth: true
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            width: row.width - Style.space(42)
            text: row.modelData.name
            color: Color.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
            maximumLineCount: 1
          }
        }

        MouseArea {
          id: rowMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          drag.target: appProxy
          onPressed: function(mouse) {
            if (!root.dragLayer) return
            var point = mapToItem(root.dragLayer, mouse.x, mouse.y)
            appProxy.x = point.x - appProxy.width / 2
            appProxy.y = point.y - appProxy.height / 2
          }
          onClicked: root.activated(String(row.modelData.id))
          onReleased: if (appProxy.Drag.active) appProxy.Drag.drop()
        }

        // Parented into the panel's drag layer so it can be carried out of the
        // list and over the canvas without the ListView clipping it.
        Item {
          id: appProxy
          parent: root.dragLayer
          width: Style.space(150)
          height: Style.space(30)
          visible: Drag.active
          z: 10

          property string appEntryId: String(row.modelData.id)

          Drag.active: rowMouse.drag.active
          Drag.keys: ["wsp-app"]
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
              text: row.modelData.name
              color: Color.foreground
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }
}
