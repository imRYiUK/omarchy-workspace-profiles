#!/bin/bash

# Tests for the two decisions bin/workspace-profiles-apply makes around the
# building itself: whether a --boot run happens at all, and where you are left
# when it is over.
#
# Both are about not moving the desktop under someone. A boot run opens a dozen
# windows, which is welcome the moment you log in and an ambush at any other
# time; and an apply that turned out to have nothing to open should not throw
# you across the workspaces to show you it.
#
# Run with: tests/apply.test.sh

set -uo pipefail

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APPLY="$ROOT/bin/workspace-profiles-apply"

passed=0
failed=0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A compositor of whatever age the case asks for, and a Hyprland that answers
# the two questions a dry run still puts to it.
mkdir -p "$tmp/stub"
cat >"$tmp/stub/pgrep" <<'EOF'
#!/bin/bash
echo 4242
EOF
cat >"$tmp/stub/ps" <<'EOF'
#!/bin/bash
echo "${FAKE_COMPOSITOR_AGE:-0}"
EOF
# Answers the two questions a run puts to Hyprland — which workspaces already
# have windows, and where you are — and writes down every dispatch it is sent,
# so a case can assert on where focus ended up.
cat >"$tmp/stub/hyprctl" <<'EOF'
#!/bin/bash
case "${1:-}" in
  activeworkspace) echo '{"id":9}' ;;
  clients)
    sep=""
    printf '['
    for ws in ${FAKE_OCCUPIED:-}; do
      printf '%s{"address":"0x%s","workspace":{"id":%s}}' "$sep" "$ws" "$ws"
      sep=","
    done
    printf ']'
    ;;
  dispatch) printf '%s\n' "${2:-}" >>"${FAKE_DISPATCH_LOG:-/dev/null}" ;;
esac
EOF
chmod +x "$tmp/stub"/*

cat >"$tmp/profiles.json" <<'EOF'
{
  "version": 1,
  "activeProfile": "morning",
  "loginProfile": "morning",
  "profiles": [{
    "id": "morning",
    "name": "Morning",
    "sequence": [1],
    "workspaces": {
      "1": { "root": { "type": "leaf", "app": "chromium", "args": "" } }
    }
  }]
}
EOF

# Runs a dry run with a compositor of the given age. Nothing here reaches a
# real Hyprland: --dry-run prints the dispatches instead of sending them.
run() {
  local age="$1"; shift
  PATH="$tmp/stub:$PATH" FAKE_COMPOSITOR_AGE="$age" \
    XDG_RUNTIME_DIR="$tmp/run" WORKSPACE_PROFILES_STORE="$tmp/profiles.json" \
    "$APPLY" --dry-run --no-notify "$@" 2>&1
}

# The same, for real: --dry-run never asks who is on a workspace, and being
# left alone is the case worth testing. Nothing escapes the stubs, and the
# timeout is short because no window is ever going to map.
run_live() {
  local occupied="$1"; shift
  : >"$tmp/dispatched"
  PATH="$tmp/stub:$PATH" FAKE_COMPOSITOR_AGE=6 FAKE_OCCUPIED="$occupied" \
    FAKE_DISPATCH_LOG="$tmp/dispatched" \
    XDG_RUNTIME_DIR="$tmp/run" WORKSPACE_PROFILES_STORE="$tmp/profiles.json" \
    "$APPLY" --no-notify --timeout 1 "$@" 2>&1
}

check() {
  local name="$1" got="$2" want="$3" mode="${4:-has}"

  if [[ $mode == has && $got == *"$want"* ]] || [[ $mode == lacks && $got != *"$want"* ]]; then
    ((passed++))
  else
    ((failed++))
    printf 'FAIL  %s\n--- %s ---\n%s\n--- got ---\n%s\n\n' \
      "$name" "$mode $want" "$want" "$got" >&2
  fi
}

# Logging in: the shell starts seconds after the compositor, so a boot run then
# is the one the login checkbox asked for.
out="$(run 6 --boot)"
check "a fresh session is built" "$out" "workspace 1"

# The case this guard exists for. Enabling the plugin or restarting the shell
# starts the service again with no marker written, and the old marker check
# alone would let it build the profile over a desktop already in use.
out="$(run 10776 --boot)"
check "an hours-old session is left alone" "$out" "this is not a login"
check "an hours-old session opens nothing" "$out" "workspace 1" lacks

# The boundary is a plain number of seconds, and it is configurable for anyone
# whose login takes longer than the default two minutes to reach the shell.
out="$(run 3600 --boot)"
check "the default window is minutes, not hours" "$out" "this is not a login"

out="$(WORKSPACE_PROFILES_BOOT_WINDOW=7200 run 3600 --boot)"
check "a widened window lets the boot run through" "$out" "workspace 1"

# Only --boot is guarded. Asking for a profile, from the panel or a keybinding,
# is a decision made just now and is always honoured.
out="$(run 10776 --profile morning)"
check "an explicit apply is never refused" "$out" "workspace 1"
check "an explicit apply says nothing about logins" "$out" "this is not a login" lacks

# The complaint this half exists for: every workspace was already open, the
# profile opened nothing, and you were still dragged to workspace 1 to look at
# the nothing that had happened.
out="$(run_live "1 2 3" --profile morning)"
check "an all-skipped apply says so" "$out" "already has windows"
check "an all-skipped apply moves nobody" "$(cat "$tmp/dispatched")" "focus" lacks

# When there is something to build, its workspace is where you want to be.
out="$(run_live "" --profile morning)"
check "a built workspace is where you land" "$(cat "$tmp/dispatched")" \
  'hl.dsp.focus({ workspace = "1" })'

# A seed pane that never opens — here an id the launcher refuses — used to take
# every pane that would have split off it down too, and the workspace came up
# empty. Now the rest still launch, untiled, for dwindle to fold into place.
cat >"$tmp/badseed.json" <<'EOF'
{
  "version": 1,
  "activeProfile": "broken",
  "profiles": [{
    "id": "broken",
    "name": "Broken",
    "sequence": [2],
    "workspaces": {
      "2": { "root": { "type": "split", "dir": "v", "ratio": 0.5,
        "a": { "type": "leaf", "app": "Google Messages", "args": "" },
        "b": { "type": "leaf", "app": "chromium", "args": "" } } }
    }
  }]
}
EOF
out="$(PATH="$tmp/stub:$PATH" FAKE_COMPOSITOR_AGE=6 FAKE_OCCUPIED="" \
  FAKE_DISPATCH_LOG="$tmp/dispatched" XDG_RUNTIME_DIR="$tmp/run" \
  WORKSPACE_PROFILES_STORE="$tmp/badseed.json" \
  "$APPLY" --no-notify --timeout 1 --profile broken 2>&1)"
check "a missing seed still launches the panes below it" "$out" \
  "launching 'chromium' without its split"
check "a missing seed does not drop the rest of the workspace" "$out" \
  "skipping the pane it splits" lacks

printf '%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
