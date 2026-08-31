#!/bin/bash

# Tests for the --boot guard in bin/workspace-profiles-apply.
#
# A boot run opens a dozen windows. It is welcome the moment you log in and an
# ambush at any other time, so the script asks how long the compositor has been
# up before it does anything. These cases pin down when it goes ahead.
#
# Run with: tests/boot.test.sh

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
cat >"$tmp/stub/hyprctl" <<'EOF'
#!/bin/bash
case "${1:-}" in
  activeworkspace) echo '{"id":1}' ;;
  clients) echo '[]' ;;
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

printf '%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
