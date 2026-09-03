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

  // Result of the last Capture or Run, shown next to the buttons. Both can
  // finish having done nothing for a reason the desktop does not show —
  // windows that could not be named, workspaces that were already open — and
  // a button that looks like it did nothing is the same as a broken one.
  property string statusHint: ""

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

  // Drag a tab onto another to carry that layout across: the workspaces are
  // keyed by number, so this swaps two keys and touches no pane. withProfile
  // runs syncSequence for us, so the launch order follows. The open tab trails
  // the layout you dragged — after 3 onto 4, you are looking at 4.
  function swapWorkspaceLayouts(from, to) {
    if (from === to) return
    withProfile(function(profile) { Model.swapWorkspaces(profile, from, to) })
    root.currentWorkspace = to
    root.selectedPath = []
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

  // ------------------------------------------------- capture what is open
  //
  // The other direction of the editor: arrange the real workspace by dragging
  // its windows about, then take that shape as the profile. Dragging tiled
  // windows is something Hyprland already does well, and reproducing a layout
  // you are looking at, pane by pane, on a scale model is the tedious half of
  // setting a profile up.
  //
  // The workspace read is the one whose tab is open, not the one in front of
  // you -- the panel is being looked at on some workspace of its own, and the
  // tab is the only unambiguous statement of which layout is being edited.

  function captureCurrent() {
    if (!activeProfile) return
    statusHint = ""
    captureClients.running = true
  }

  // A window reports the class it was launched with; a profile stores a
  // desktop entry id. Nothing guarantees the two are the same string, so this
  // works down from an exact match to progressively looser ones, and gives up
  // rather than guessing wrong -- an unmatched window still becomes a pane,
  // just an empty one waiting for an app to be dropped in.
  function desktopIdForClass(cls) {
    var want = String(cls || "").toLowerCase()
    if (want === "") return ""

    var values = DesktopEntries.applications.values || []
    var tail = function(id) {
      var parts = String(id).toLowerCase().split(".")
      return parts[parts.length - 1]
    }
    var bare = function(text) { return String(text).toLowerCase().replace(/[^a-z0-9]/g, "") }

    var i, entry
    for (i = 0; i < values.length; i++) {
      if (String(values[i].id).toLowerCase() === want) return String(values[i].id)
    }
    // StartupWMClass exists precisely to tie a window back to its entry, so it
    // outranks every guess below it.
    for (i = 0; i < values.length; i++) {
      entry = values[i]
      if (entry.startupClass && String(entry.startupClass).toLowerCase() === want)
        return String(entry.id)
    }
    // org.gnome.Nautilus vs nautilus.
    for (i = 0; i < values.length; i++) {
      if (tail(values[i].id) === want) return String(values[i].id)
    }
    // brave-browser vs brave_browser vs BraveBrowser.
    for (i = 0; i < values.length; i++) {
      if (bare(values[i].id) === bare(want)) return String(values[i].id)
    }
    // A browser web app is named after its own URL, not after the .desktop
    // file that launched it: --app=https://www.facebook.com/messages/ opens a
    // window of class brave-www.facebook.com__messages_-Profile_3. Flatten
    // both sides to alphanumerics and look for one inside the other, rather
    // than reproducing Chromium's exact spelling of it, which differs between
    // versions and between Brave and Chrome.
    var flat = function(text) {
      return String(text).toLowerCase().replace(/[^a-z0-9]+/g, "_")
        .replace(/^_+|_+$/g, "")
    }
    var flatClass = flat(want)
    var bestId = "", bestLength = 0

    for (i = 0; i < values.length; i++) {
      entry = values[i]
      var exec = String(entry.execString || (entry.command || []).join(" ") || "")
      var app = exec.match(/--app=(\S+)/)
      if (!app) continue

      var token = flat(String(app[1]).replace(/^[a-z]+:\/\//i, ""))
      // Short tokens match too much: a two-letter host would hit half the
      // browser windows open. Longest match wins, so a URL with a path beats
      // the bare host it sits on.
      if (token.length < 6 || token.length <= bestLength) continue
      if (flatClass.indexOf(token) >= 0) { bestId = String(entry.id); bestLength = token.length }
    }
    if (bestId !== "") return bestId

    for (i = 0; i < values.length; i++) {
      entry = values[i]
      if (!entry.noDisplay && bare(entry.name) === bare(want)) return String(entry.id)
    }
    return ""
  }

  function applyCapture(raw) {
    var clients
    try {
      clients = JSON.parse(raw)
    } catch (e) {
      statusHint = "Could not read the running windows"
      statusHintTimer.restart()
      return
    }
    if (!Array.isArray(clients)) clients = []

    var boxes = []
    var unmatched = 0

    for (var i = 0; i < clients.length; i++) {
      var c = clients[i]
      var ws = c && c.workspace ? Number(c.workspace.id) : NaN
      if (ws !== root.currentWorkspace) continue
      // Floating windows sit over the layout rather than in it, and an
      // unmapped or hidden one has no place on screen to read.
      if (c.floating || c.hidden || c.mapped === false) continue

      var at = c.at || [], size = c.size || []
      var w = Number(size[0]), h = Number(size[1])
      if (!(w > 0 && h > 0)) continue

      var app = desktopIdForClass(c.class || c.initialClass)
      if (app === "") app = desktopIdForClass(c.initialClass)
      if (app === "") unmatched++

      boxes.push({ x: Number(at[0]), y: Number(at[1]), w: w, h: h, app: app, args: "" })
    }

    if (boxes.length === 0) {
      statusHint = "Workspace " + root.currentWorkspace + " has no tiled windows"
      statusHintTimer.restart()
      return
    }

    setTree(Model.treeFromBoxes(boxes))
    selectedPath = []

    statusHint = "Captured " + boxes.length + (boxes.length === 1 ? " window" : " windows")
      + (unmatched > 0 ? " — " + unmatched + " left empty, app not recognised" : "")
    statusHintTimer.restart()
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

  // Builds the profile into the running session now instead of waiting for a
  // login. The launcher leaves any workspace that already has windows alone, so
  // this fills the empty ones and cannot disturb what is already open.
  function runNow() {
    if (!activeProfile) return
    persistNow()

    var argv = [root.applyScript, "--profile", String(activeId)]
    if (!notifyOnApply) argv.push("--no-notify")

    statusHint = "Building…"
    statusHintTimer.stop()
    runApply.command = argv
    runApply.running = true
  }

  // The launcher will not build into a workspace that already has windows: the
  // first app is meant to fill it and every split is measured from there. That
  // is the right call, but it means Run right after a Capture always declines —
  // capturing a workspace is proof it has windows on it — and from the panel
  // that was indistinguishable from a dead button. It reports what it did on
  // stderr, so read it back and say so.
  function applyRunResult(text) {
    var skipped = []
    var built = []
    var lines = String(text || "").split("\n")

    for (var i = 0; i < lines.length; i++) {
      var already = lines[i].match(/^workspace (\S+) already has windows/)
      if (already) { skipped.push(already[1]); continue }
      var opened = lines[i].match(/^\s*dispatch\s+.*workspace = "([^"]+)"/)
      if (opened && built.indexOf(opened[1]) < 0) built.push(opened[1])
    }

    // Only the workspaces it declined are worth a line: when it built
    // something, the desktop in front of you is the report.
    if (skipped.length === 0) {
      statusHint = built.length > 0 ? "" : "Nothing to open in this profile"
    } else if (built.length === 0) {
      statusHint = "Nothing opened — workspace" + (skipped.length === 1 ? " " : "s ")
        + skipped.join(", ") + " already had windows"
    } else {
      statusHint = "Workspace" + (skipped.length === 1 ? " " : "s ") + skipped.join(", ")
        + " already had windows and " + (skipped.length === 1 ? "was" : "were") + " left alone"
    }
    if (statusHint !== "") statusHintTimer.restart()
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

  // The freedesktop desktop-file-id shape the launcher enforces before it will
  // open a pane (bin/workspace-profiles-apply:is_app_id). An id it would refuse
  // — most often a .desktop filename with a space in it — is dropped here rather
  // than saved into a profile that fails silently at the next login.
  function isLaunchableId(id) {
    return /^[A-Za-z0-9][A-Za-z0-9._+-]*$/.test(String(id || ""))
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
      if (!isLaunchableId(entry.id)) continue

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

  Timer {
    id: statusHintTimer
    interval: 8000
    onTriggered: root.statusHint = ""
  }

  Process {
    id: runApply
    stderr: StdioCollector {
      onStreamFinished: root.applyRunResult(text)
    }
  }

  Process {
    id: captureClients
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      onStreamFinished: root.applyCapture(text)
    }
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
        else if (text === "f" || text === "F") editor.flip(root.selectedPath)
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
            // Clipped rather than overlapping: a chip half cut off at the
            // Rename button still reads as "there are more profiles over
            // there", where a chip drawn under the buttons reads as a broken
            // panel. The panel widens to its content first, so this only bites
            // once there are more profiles than the screen has room for.
            width: Math.max(0, parent.width - profileActions.width - Style.space(10))
            clip: true

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
            id: profileActions
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
              id: statusLine
              anchors.verticalCenter: parent.verticalCenter
              visible: root.statusHint !== "" && !root.savedHint && !root.renaming
              text: root.statusHint
              width: Math.min(implicitWidth, Style.space(230))
              elide: Text.ElideRight
              color: Util.alpha(Color.foreground, 0.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: root.hasTestResult && !root.savedHint && root.statusHint === ""
              text: root.testSummary
              color: root.testResult && root.testResult.failed > 0
                ? Color.urgent : Util.alpha(Color.foreground, 0.6)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Button {
              text: "Run"
              tooltipText: "Build this profile into the running session now. A workspace that already has windows is left alone, so close them first if you want it rebuilt"
              visible: !root.renaming
              horizontalPadding: Style.space(9)
              verticalPadding: Style.space(3)
              onClicked: root.runNow()
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

          // The tabs pick which layout you are editing, and drag onto each
          // other to move a layout to another workspace — drop 3 on 4 and the
          // two swap which number they are keyed under. One MouseArea over the
          // whole strip and the swap only on release, same as the launch order
          // below and for the same reason: a rekey mid-drag would rebuild the
          // tabs under the pointer and destroy the grab. A press that never
          // moved is still just a click.
          Item {
            id: tabStrip
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: tabRow.width
            height: Style.space(24)

            readonly property real step: Style.space(58) + tabRow.spacing

            function slotAt(x) {
              var slot = Math.floor(x / step)
              return Math.max(0, Math.min(Model.WORKSPACES.length - 1, slot))
            }

            Row {
              id: tabRow
              spacing: Style.space(4)

              Repeater {
                model: Model.WORKSPACES

                Rectangle {
                  id: tab
                  required property int index
                  required property int modelData

                  readonly property bool current: tab.modelData === root.currentWorkspace
                  readonly property bool lifted: tabMouse.grabbed === tab.index
                  readonly property string summary: Model.workspaceSummary(root.activeProfile, tab.modelData)

                  width: Style.space(58)
                  height: Style.space(24)
                  radius: Style.cornerRadius > 0 ? Style.space(5) : 0
                  opacity: tab.lifted ? 0.45 : 1
                  color: Util.alpha(Color.foreground, tab.current ? 0.16 : (tabMouse.hovered === tab.index ? 0.08 : 0.03))
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
                }
              }
            }

            // Where the tab being dragged would land.
            Rectangle {
              visible: tabMouse.grabbed >= 0 && tabMouse.target !== tabMouse.grabbed
              x: tabMouse.target * tabStrip.step - Style.space(3)
              y: 0
              width: Style.space(2)
              height: parent.height
              color: Color.accent
            }

            MouseArea {
              id: tabMouse
              anchors.fill: parent
              hoverEnabled: true
              preventStealing: true
              cursorShape: grabbed >= 0 ? Qt.ClosedHandCursor : Qt.PointingHandCursor

              property int grabbed: -1
              property int target: -1
              property int hovered: -1

              onPressed: function(mouse) {
                grabbed = tabStrip.slotAt(mouse.x)
                target = grabbed
              }
              onPositionChanged: function(mouse) {
                hovered = tabStrip.slotAt(mouse.x)
                if (grabbed >= 0) target = tabStrip.slotAt(mouse.x)
              }
              onReleased: {
                if (grabbed >= 0 && target >= 0) {
                  var from = Model.WORKSPACES[grabbed]
                  // A press that never moved is a click: open that workspace.
                  if (target === grabbed) {
                    root.currentWorkspace = from
                    root.selectedPath = []
                  } else {
                    root.swapWorkspaceLayouts(from, Model.WORKSPACES[target])
                  }
                }
                grabbed = -1
                target = -1
              }
              onExited: hovered = -1
              onCanceled: { grabbed = -1; target = -1; hovered = -1 }
            }
          }

          // Both act on the workspace whose tab is open rather than on the
          // profile, which is why they sit on this row and not up with Save.
          Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            Button {
              text: "Capture"
              tooltipText: "Read workspace " + root.currentWorkspace
                + " as it is arranged on screen right now, and make that this layout"
              horizontalPadding: Style.space(9)
              verticalPadding: Style.space(3)
              onClicked: root.captureCurrent()
            }

            Button {
              text: "Clear workspace"
              visible: Model.isConfigured(root.currentWorkspaceData)
              horizontalPadding: Style.space(9)
              verticalPadding: Style.space(3)
              onClicked: root.clearWorkspace()
            }
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
