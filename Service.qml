import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Headless half of Workspace Profiles.
//
// Two jobs, both small: apply the login profile once per boot, and expose the
// apply commands over IPC so a profile can be launched from a keybinding
// without going near the bar.
//
// Deliberately thin. All of the decision-making — is there a store, is a login
// profile set, has this boot already been handled — lives in
// bin/workspace-profiles-apply, which exits in milliseconds when the answer is
// no. Duplicating those checks here would mean two places to keep in agreement,
// and the shell would carry a JSON parse and a file watch it has no other use
// for.
Item {
  id: root

  property var shell: null

  // Qt hands back a percent-encoded file: URL; the plugin lives under a path
  // the user chose, so decode it before it becomes an argv entry.
  readonly property string pluginDir: decodeURIComponent(
    String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string applyScript: pluginDir + "/bin/workspace-profiles-apply"

  function applyProfile(profileId) {
    var argv = [root.applyScript]
    if (profileId) argv = argv.concat(["--profile", String(profileId)])
    Util.execArgv(argv)
  }

  function applyLoginProfile() {
    Util.execArgv([root.applyScript, "--boot"])
  }

  IpcHandler {
    target: "workspace-profiles"

    // Apply a specific profile by id.
    function apply(profileId: string): void { root.applyProfile(profileId) }

    // Apply whichever profile the panel currently has selected.
    function applyActive(): void { root.applyProfile("") }

    // The once-per-boot login run, including its marker check — useful for
    // testing the login path without logging out.
    function applyLogin(): void { root.applyLoginProfile() }
  }

  // The shell is started by Hyprland's autostart, so at Component.onCompleted
  // the compositor is up but its workspaces may not have settled and the bar
  // has not reserved its strip yet. Waiting a moment means the first window is
  // measured against the desktop the user will actually be looking at — the
  // split ratios are computed from real window geometry, so a bar that appears
  // mid-build would skew them.
  Timer {
    interval: 2500
    repeat: false
    running: true
    onTriggered: root.applyLoginProfile()
  }
}
