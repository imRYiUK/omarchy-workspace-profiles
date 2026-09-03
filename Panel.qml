import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The editor. Profiles across the top, workspaces below them, then the app list
// beside the layout canvas.
//
// This file owns the profile store — it is the only thing that reads and writes
// profiles.json — and hands the current workspace's tree down to LayoutEditor,
// which hands every edit straight back. Keeping the single copy here is what
// lets a divider drag, a swap, and a rename all go through the same save path.
//
// BarWidget.qml owns the bar button and hands this panel the button to anchor
// against, following the omarchy.clock arrangement.
Panel {
  id: root
  moduleName: "io.github.imryiuk.workspace-profiles"
  ipcTarget: "io.github.imryiuk.workspace-profiles"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string home: Quickshell.env("HOME")
  readonly property string storeDir: home + "/.config/omarchy/workspace-profiles"
  readonly property string storePath: storeDir + "/profiles.json"
  // Cleared by the system at logout, which is exactly the lifetime a test
  // result and the once-per-login marker both want.
  readonly property string runtimeDir:
    (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/omarchy-workspace-profiles"

  readonly property string pluginDir: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string applyScript: pluginDir + "/bin/workspace-profiles-apply"

  // ---------------------------------------------------------------- state

  property var store: Model.normalizeStore(null)
  property string activeId: ""
  property int currentWorkspace: 1
  property var selectedPath: []
  property bool renaming: false

  // Briefly shown after Save, so the button gives an acknowledgement rather
  // than closing on you or doing nothing visible.
  property bool savedHint: false

  // What we last wrote, so the change notification our own save triggers does
  // not bounce back and overwrite an edit made in the meantime.
  property string lastWritten: ""

  readonly property var activeProfile: Model.profileById(store, activeId)
  readonly property var currentWorkspaceData: activeProfile && activeProfile.workspaces
    ? activeProfile.workspaces[String(currentWorkspace)] : null
  readonly property var currentTree: currentWorkspaceData ? currentWorkspaceData.root : Model.leaf("")
  readonly property var selectedNode: Model.nodeAt(currentTree, selectedPath)
  readonly property bool selectedIsFilled: !!selectedNode && !Model.isSplit(selectedNode)
    && String(selectedNode.app || "") !== ""

  readonly property bool notifyOnApply: setting("notify", true) !== false

  // The last test run, if it was of the profile currently on screen. Cleared on
  // any edit: once the layout changes, a previous run says nothing about it.
  property var testResult: null
  readonly property bool hasTestResult: !!testResult && testResult.profile === activeId

  // { "<paneKey>": true|false } for the workspace being edited, which is what
  // puts the tick or the warning on each pane.
  readonly property var testPanesForWorkspace: {
    var map = ({})
    if (!hasTestResult || !testResult.panes) return map
    var prefix = String(currentWorkspace) + ":"
    for (var i = 0; i < testResult.panes.length; i++) {
      var entry = testResult.panes[i]
      var key = String(entry.key || "")
      if (key.indexOf(prefix) === 0) map[key.slice(prefix.length)] = entry.ok === true
    }
    return map
  }

  readonly property var launchOrder: activeProfile && activeProfile.sequence
    ? activeProfile.sequence : []

  readonly property string testSummary: {
    if (!hasTestResult) return ""
    var total = testResult.ok + testResult.failed
    if (testResult.failed === 0) return "all " + total + " opened"
    return testResult.failed + " of " + total + " did not start"
  }

  // ------------------------------------------------------------- the store

  function loadFromText(raw) {
    if (raw === lastWritten) return

    var parsed = null
    try {
      parsed = raw && raw.length ? JSON.parse(raw) : null
    } catch (e) {
      console.warn("workspace-profiles: profiles.json is not valid JSON, starting fresh")
      parsed = null
    }

    var next = Model.normalizeStore(parsed)
    if (next.profiles.length === 0) {
      var seeded = Model.newProfile("default", "Default")
      seeded.workspaces["1"] = Model.emptyWorkspace()
      next.profiles.push(seeded)
      next.activeProfile = seeded.id
      next.loginProfile = seeded.id
      store = next
      persistNow()
    } else {
      store = next
    }

    if (!Model.profileById(store, activeId)) activeId = store.activeProfile
    selectedPath = []
  }

  function persist() {
    saveDebounce.restart()
  }

  function persistNow() {
    saveDebounce.stop()
    var payload = JSON.stringify(store, null, 2) + "\n"
    lastWritten = payload
    storeFile.setText(payload)
  }

  // Every mutation funnels through here: replace the whole store object (QML
  // only re-evaluates a `var` binding on reassignment) and queue a save.
  function commit(next) {
    store = next
    testResult = null
    persist()
  }

  function withProfile(fn) {
    var index = Model.profileIndex(store, activeId)
    if (index < 0) return

    var next = JSON.parse(JSON.stringify(store))
    fn(next.profiles[index])
    // The launch order can never name a workspace with nothing on it, or miss
    // one that has something, whatever the edit was.
    Model.syncSequence(next.profiles[index])
    commit(next)
  }

  function moveWorkspaceTo(workspaceId, index) {
    withProfile(function(profile) { Model.moveInSequenceTo(profile, workspaceId, index) })
  }

  function setTree(tree) {
    withProfile(function(profile) {
      profile.workspaces[String(root.currentWorkspace)] = { root: tree }
    })
  }

  function clearWorkspace() {
    withProfile(function(profile) {
      delete profile.workspaces[String(root.currentWorkspace)]
    })
    selectedPath = []
  }

  // ------------------------------------------------------------- profiles

  function selectProfile(id) {
    activeId = id
    renaming = false
    selectedPath = []

    var next = JSON.parse(JSON.stringify(store))
    next.activeProfile = id
    commit(next)
  }

  function addProfile() {
    var next = JSON.parse(JSON.stringify(store))
    var name = "Profile " + (next.profiles.length + 1)
    var profile = Model.newProfile(Model.uniqueProfileId(next, name), name)
    profile.workspaces["1"] = Model.emptyWorkspace()
    next.profiles.push(profile)
    next.activeProfile = profile.id
    // On by default: the first profile becomes the login profile, and so does a
    // new one added after the box was unticked for every other. Switching which
    // profile runs at login is still a deliberate tick on its chip.
    if (!next.loginProfile) next.loginProfile = profile.id
    commit(next)

    activeId = profile.id
    currentWorkspace = 1
    selectedPath = []
    renaming = true
  }

  function renameProfile(name) {
    var trimmed = String(name || "").trim()
    renaming = false
    if (trimmed === "") return
    withProfile(function(profile) { profile.name = trimmed })
  }

  function deleteProfile() {
    var index = Model.profileIndex(store, activeId)
    if (index < 0) return

    var next = JSON.parse(JSON.stringify(store))
    next.profiles.splice(index, 1)
    if (next.loginProfile === activeId) next.loginProfile = ""
    next.activeProfile = next.profiles.length ? next.profiles[Math.max(0, index - 1)].id : ""
    commit(next)

    activeId = next.activeProfile
    currentWorkspace = 1
    selectedPath = []
  }

  function setLoginProfile(enabled) {
    var next = JSON.parse(JSON.stringify(store))
    next.loginProfile = enabled ? activeId : ""
    commit(next)
  }

  // -------------------------------------------------------------- actions

  // Saving is all this does. The editor lays a profile out; it does not
  // rearrange the desktop you are working on. The profile opens on its own at
  // your next login, the way an i3 config takes hold when i3 restarts. To build
  // it into the running session there is the bar icon's right click, or a
  // keybinding of your own — both deliberate "do it now" gestures, made from
  // outside the editor.
  function applyNow() {
    persistNow()
    savedHint = true
    savedHintTimer.restart()
  }

  // Checks every app starts, on a hidden workspace, then closes what it opened
  // and notifies. Nothing on screen changes while it runs.
  function testNow() {
    if (!activeProfile) return
    persistNow()
    testResult = null

    var argv = [root.applyScript, "--profile", String(activeId), "--test"]
    if (!notifyOnApply) argv.push("--no-notify")
    Util.execArgv(argv)
  }

  function loadTestResult(raw) {
    try {
      testResult = raw && raw.length ? JSON.parse(raw) : null
    } catch (e) {
      testResult = null
    }
  }

  // ----------------------------------------------------------- app lookup

  function appEntry(id) {
    if (!id) return null
    var values = DesktopEntries.applications.values || []
    for (var i = 0; i < values.length; i++) {
      if (String(values[i].id) === String(id)) return values[i]
    }
    return null
  }

  function appIconFor(entry) {
    var icon = entry && entry.icon ? String(entry.icon) : ""
    if (icon === "") return Quickshell.iconPath("application-x-executable", true)
    if (icon.charAt(0) === "/") return Util.fileUrl(icon)
    var themed = Quickshell.iconPath(icon, true)
    return themed.length > 0 ? themed : Quickshell.iconPath("application-x-executable", true)
  }

  // Name match first, then anything else the entry mentions — so typing
  // "chrom" puts Chromium above an app that merely lists it as a keyword.
  function searchApps(query) {
    var term = String(query || "").trim().toLowerCase()
    var values = DesktopEntries.applications.values || []
    var strong = []
    var weak = []

    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (entry.noDisplay) continue

      var name = String(entry.name || entry.id || "")
      var row = { id: String(entry.id), name: name, icon: appIconFor(entry) }

      if (term === "") {
        strong.push(row)
        continue
      }
      if (name.toLowerCase().indexOf(term) >= 0) strong.push(row)
      else if ([entry.genericName, entry.comment, entry.id].join(" ").toLowerCase().indexOf(term) >= 0) weak.push(row)
    }

    function byName(left, right) { return left.name.toLowerCase() < right.name.toLowerCase() ? -1 : 1 }
    return strong.sort(byName).concat(weak.sort(byName))
  }

  // ------------------------------------------------------------- keyboard

  function moveSelection(step) {
    var paths = Model.leafPaths(currentTree)
    if (paths.length === 0) return

    var key = selectedPath.join(".")
    var index = -1
    for (var i = 0; i < paths.length; i++) {
      if (paths[i].join(".") === key) { index = i; break }
    }

    var next = index < 0 ? 0 : (index + step + paths.length) % paths.length
    selectedPath = paths[next]
  }

  // ------------------------------------------------------------- lifetime

  onOpenedChanged: {
    if (opened) {
      storeFile.reload()
      appSearch.query = ""
      renaming = false
    }
  }

  // The bar label and tooltip name the profile a right click would launch.
  onActiveProfileChanged: {
    if (hostWidget && "activeProfileName" in hostWidget)
      hostWidget.activeProfileName = activeProfile ? String(activeProfile.name) : ""
  }

  Component.onCompleted: ensureDir.running = true

  Process {
    id: ensureDir
    command: ["bash", "-c",
      "mkdir -p \"$HOME/.config/omarchy/workspace-profiles\"; f=\"$HOME/.config/omarchy/workspace-profiles/profiles.json\"; [[ -f \"$f\" ]] || printf '{\\n  \"version\": 1,\\n  \"profiles\": []\\n}\\n' > \"$f\""]
    onExited: storeFile.reload()
  }

  FileView {
    id: storeFile
    path: root.storePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadFromText(text())
    onFileChanged: reload()
    onLoadFailed: root.loadFromText("")
  }

  FileView {
    id: testResultFile
    path: root.runtimeDir + "/test-result.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadTestResult(text())
    onFileChanged: reload()
    onLoadFailed: root.testResult = null
  }

  Timer {
    id: saveDebounce
    interval: 400
    onTriggered: root.persistNow()
  }

  Timer {
    id: savedHintTimer
    interval: 2600
    onTriggered: root.savedHint = false
  }

  // --------------------------------------------------------------- the UI

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(760))
    contentHeight: panel.fittedContentHeight(Style.space(480))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: appSearch.searchField.activeFocus || argsField.activeFocus || nameField.activeFocus

      onMoveRequested: function(dx, dy) { root.moveSelection(dx !== 0 ? dx : dy) }
      onCloseRequested: root.close()
      onDeleteRequested: if (root.selectedPath !== null) editor.remove(root.selectedPath)
      onActivateRequested: appSearch.searchField.forceActiveFocus()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text >= "1" && text <= "9") root.currentWorkspace = parseInt(text)
        else if (text === "s") editor.split(root.selectedPath, "v")
        else if (text === "S") editor.split(root.selectedPath, "h")
        else if (text === "/") appSearch.searchField.forceActiveFocus()
        else if (text === "a" || text === "A") root.applyNow()
      }

      Column {
        anchors.fill: parent
        spacing: Style.space(10)

        // ---- profiles + apply

        Item {
          width: parent.width
          height: Style.space(28)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            visible: !root.renaming

            Repeater {
              model: root.store.profiles

              Rectangle {
                id: chip
                required property var modelData

                readonly property bool current: String(chip.modelData.id) === root.activeId
                readonly property bool isLogin: String(chip.modelData.id) === root.store.loginProfile

                width: chipLabel.implicitWidth + Style.space(22)
                height: Style.space(24)
                radius: Style.cornerRadius > 0 ? Style.space(5) : 0
                color: Util.alpha(Color.foreground, chip.current ? 0.16 : (chipMouse.containsMouse ? 0.08 : 0.03))
                border.width: 1
                border.color: chip.current ? Util.alpha(Color.accent, 0.8) : Util.alpha(Color.foreground, 0.14)

                Row {
                  anchors.centerIn: parent
                  spacing: Style.space(4)

                  // A dot marks the profile that runs at login, so the one that
                  // matters most is identifiable without opening anything.
                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: chip.isLogin
                    width: Style.space(5)
                    height: Style.space(5)
                    radius: width / 2
                    color: Color.accent
                  }

                  Text {
                    id: chipLabel
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(chip.modelData.name)
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                MouseArea {
                  id: chipMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectProfile(String(chip.modelData.id))
                  onDoubleClicked: {
                    root.selectProfile(String(chip.modelData.id))
                    root.renaming = true
                  }
                }
              }
            }

            Button {
              anchors.verticalCenter: parent.verticalCenter
              text: "+"
              tooltipText: "New profile"
              horizontalPadding: Style.space(9)
              verticalPadding: Style.space(3)
              bordered: true
              onClicked: root.addProfile()
            }
          }

          TextField {
            id: nameField
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(200)
            visible: root.renaming
            text: root.activeProfile ? String(root.activeProfile.name) : ""
            placeholderText: "Profile name"
            font.pixelSize: Style.font.bodySmall
            onVisibleChanged: if (visible) { selectAll(); forceActiveFocus() }
            onAccepted: root.renameProfile(text)
            Keys.onEscapePressed: root.renaming = false
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              text: "Rename"
              visible: !!root.activeProfile && !root.renaming
              horizontalPadding: Style.space(9)
              verticalPadding: Style.space(3)
              onClicked: root.renaming = true
            }

            Button {
              text: "Delete"
              visible: root.store.profiles.length > 1 && !root.renaming
              horizontalPadding: Style.space(9)
              verticalPadding: Style.space(3)
              onClicked: root.deleteProfile()
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: root.savedHint
              text: root.store.loginProfile === root.activeId
                ? "Saved — opens at your next login" : "Saved"
              color: Util.alpha(Color.foreground, 0.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: root.hasTestResult && !root.savedHint
              text: root.testSummary
              color: root.testResult && root.testResult.failed > 0
                ? Color.urgent : Util.alpha(Color.foreground, 0.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Button {
              text: "Test"
              tooltipText: "Start every app out of sight, check it opens, then close it again"
              visible: !root.renaming
              horizontalPadding: Style.space(9)
              verticalPadding: Style.space(3)
              onClicked: root.testNow()
            }

            Button {
              text: "Save"
              tooltipText: "Save this profile. It opens on its own at your next login"
              bordered: true
              foreground: Color.accent
              horizontalPadding: Style.space(11)
              verticalPadding: Style.space(3)
              onClicked: root.applyNow()
            }
          }
        }

        // ---- workspace tabs

        Item {
          width: parent.width
          height: Style.space(26)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(4)

            Repeater {
              model: Model.WORKSPACES

              Rectangle {
                id: tab
                required property int modelData

                readonly property bool current: tab.modelData === root.currentWorkspace
                readonly property string summary: Model.workspaceSummary(root.activeProfile, tab.modelData)

                width: Style.space(58)
                height: Style.space(24)
                radius: Style.cornerRadius > 0 ? Style.space(5) : 0
                color: Util.alpha(Color.foreground, tab.current ? 0.16 : (tabMouse.containsMouse ? 0.08 : 0.03))
                border.width: 1
                border.color: tab.current ? Util.alpha(Color.accent, 0.8) : Util.alpha(Color.foreground, 0.12)

                Row {
                  anchors.centerIn: parent
                  spacing: Style.space(5)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: String(tab.modelData)
                    color: Color.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }

                  // A dot rather than a count: the tab only needs to say
                  // "something is set up here", the canvas says what.
                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: tab.summary !== ""
                    width: Style.space(5)
                    height: Style.space(5)
                    radius: width / 2
                    color: Util.alpha(Color.foreground, 0.6)
                  }
                }

                MouseArea {
                  id: tabMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    root.currentWorkspace = tab.modelData
                    root.selectedPath = []
                  }
                }
              }
            }
          }

          Button {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Clear workspace"
            visible: Model.isConfigured(root.currentWorkspaceData)
            horizontalPadding: Style.space(9)
            verticalPadding: Style.space(3)
            onClicked: root.clearWorkspace()
          }
        }

        // ---- app list + canvas

        Item {
          width: parent.width
          height: parent.height - Style.space(28) - Style.space(26) - Style.space(30) - Style.space(26) - Style.space(40)

          AppPicker {
            id: appSearch
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Style.space(196)
            dragLayer: dragLayer
            entries: root.opened ? root.searchApps(query) : []
            onActivated: function(appId) { editor.assign(root.selectedPath, appId) }
          }

          LayoutEditor {
            id: editor
            anchors.left: appSearch.right
            anchors.leftMargin: Style.space(12)
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom

            tree: root.currentTree
            selectedPath: root.selectedPath
            dragLayer: dragLayer
            appLookup: root.appEntry
            testPanes: root.testPanesForWorkspace

            onTreeEdited: function(next) { root.setTree(next) }
            onSelectionChanged: function(path) { root.selectedPath = path }
          }
        }

        // ---- arguments for the selected pane

        Item {
          width: parent.width
          height: Style.space(30)

          Row {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)
            visible: root.selectedIsFilled

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(186)
              text: "Arguments"
              color: Util.alpha(Color.foreground, 0.7)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            TextField {
              id: argsField
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(196)
              // Bound to the selection, so switching panes swaps the value in
              // rather than carrying the last pane's arguments over.
              text: root.selectedIsFilled ? String(root.selectedNode.args || "") : ""
              placeholderText: "https://google.com   ·   -e btop   ·   ~/Projects"
              font.pixelSize: Style.font.bodySmall
              onEditingFinished: {
                if (root.selectedIsFilled && text !== String(root.selectedNode.args || ""))
                  editor.setArgs(root.selectedPath, text)
              }
            }
          }

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.selectedIsFilled
            text: "Click a pane to select it  ·  ◫ splits it  ·  drag a divider to resize  ·  drag an app in from the left"
            color: Util.alpha(Color.foreground, 0.45)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        // ---- footer

        Item {
          width: parent.width
          height: Style.space(26)

          Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Rectangle {
              id: loginBox
              anchors.verticalCenter: parent.verticalCenter
              readonly property bool checked: !!root.activeProfile && root.store.loginProfile === root.activeId

              width: Style.space(14)
              height: Style.space(14)
              radius: Style.cornerRadius > 0 ? Style.space(3) : 0
              color: loginBox.checked ? Color.accent : "transparent"
              border.width: 1
              border.color: loginBox.checked ? Color.accent : Util.alpha(Color.foreground, 0.4)

              Text {
                anchors.centerIn: parent
                visible: loginBox.checked
                text: "✓"
                color: Color.background
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setLoginProfile(!loginBox.checked)
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Open this profile when I log in"
              color: Util.alpha(Color.foreground, 0.8)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setLoginProfile(!loginBox.checked)
              }
            }
          }

          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.launchOrder.length > 1
                ? "Launch order — drag to reorder, you end up on the first"
                : "Launch order"
              color: Util.alpha(Color.foreground, 0.7)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: root.launchOrder.length === 0
              text: "nothing set up yet"
              color: Util.alpha(Color.foreground, 0.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            // The workspaces this profile builds, in the order it builds them,
            // dragged into the order you want.
            //
            // One MouseArea over the whole strip rather than one per chip, and
            // the move is only committed on release. Reordering while the
            // pointer is still down would rebuild the chips underneath it and
            // destroy the very item holding the mouse grab.
            Item {
              id: orderStrip
              anchors.verticalCenter: parent.verticalCenter
              width: orderRow.width
              height: Style.space(20)

              readonly property real step: Style.space(40) + orderRow.spacing

              function slotAt(x) {
                var slot = Math.floor(x / step)
                return Math.max(0, Math.min(root.launchOrder.length - 1, slot))
              }

              Row {
                id: orderRow
                spacing: Style.space(4)

                Repeater {
                  model: root.launchOrder

                  Rectangle {
                    id: orderChip
                    required property int index
                    required property var modelData

                    readonly property bool current: orderChip.modelData === root.currentWorkspace
                    readonly property bool lifted: orderMouse.grabbed === orderChip.index

                    width: Style.space(40)
                    height: Style.space(20)
                    radius: Style.cornerRadius > 0 ? Style.space(4) : 0
                    opacity: orderChip.lifted ? 0.45 : 1
                    color: Util.alpha(Color.foreground, orderChip.current ? 0.16 : 0.02)
                    border.width: 1
                    border.color: orderChip.current
                      ? Util.alpha(Color.accent, 0.8) : Util.alpha(Color.foreground, 0.1)

                    Text {
                      anchors.centerIn: parent
                      text: String(orderChip.modelData)
                      color: Color.foreground
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }

              // Where the chip being dragged would land.
              Rectangle {
                visible: orderMouse.grabbed >= 0 && orderMouse.target !== orderMouse.grabbed
                x: orderMouse.target * orderStrip.step - Style.space(3)
                y: 0
                width: Style.space(2)
                height: parent.height
                color: Color.accent
              }

              MouseArea {
                id: orderMouse
                anchors.fill: parent
                hoverEnabled: true
                preventStealing: true
                cursorShape: grabbed >= 0 ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                property int grabbed: -1
                property int target: -1

                onPressed: function(mouse) {
                  grabbed = orderStrip.slotAt(mouse.x)
                  target = grabbed
                }
                onPositionChanged: function(mouse) {
                  if (grabbed >= 0) target = orderStrip.slotAt(mouse.x)
                }
                onReleased: {
                  if (grabbed >= 0 && target >= 0) {
                    var workspace = root.launchOrder[grabbed]
                    // A press that never moved is a click: show that workspace.
                    if (target === grabbed) {
                      root.currentWorkspace = workspace
                      root.selectedPath = []
                    } else {
                      root.moveWorkspaceTo(workspace, target)
                    }
                  }
                  grabbed = -1
                  target = -1
                }
                onCanceled: { grabbed = -1; target = -1 }
              }
            }
          }
        }
      }

      // Drag proxies are parented here so they float over everything in the
      // panel — out of the app list, across the canvas — without being clipped.
      Item {
        id: dragLayer
        anchors.fill: parent
        z: 50
      }
    }
  }
}
