#!/bin/bash

# Tests for how bin/workspace-profiles-apply turns a pane into a command.
#
# A pane is a desktop entry id plus a line of arguments somebody typed into a
# text box, and both of them used to be handed to `eval`. That made every
# character with a meaning to the shell — `$(...)`, a backtick, `;`, `>`, `*` —
# do that thing instead of reaching the app, which is wrong twice over: an app
# whose Exec line legitimately contains one gets launched as something else,
# and an arguments box turns into a place to run a second command.
#
# So these cases are all the same question asked about different characters:
# does this arrive at the app as the text it was written as?
#
# Run with: tests/launch.test.sh

set -uo pipefail

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly APPLY="$ROOT/bin/workspace-profiles-apply"

passed=0
failed=0

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# A Hyprland that says every workspace is empty, and writes down what it is
# told to do. `clients` starts answering with a window once an exec_cmd has
# been dispatched, so a --test run finds the window it is waiting for.
mkdir -p "$tmp/stub"
cat >"$tmp/stub/hyprctl" <<'EOF'
#!/bin/bash
case "${1:-}" in
  clients)
    if [[ -e ${FAKE_LAUNCHED:-/nonexistent} ]]; then
      printf '[{"address":"0xabc","size":[100,100],"workspace":{"id":1,"name":"special:workspace-profiles-test"}}]'
    else
      printf '[]'
    fi
    ;;
  dispatch)
    printf '%s\n' "${2:-}" >>"${FAKE_DISPATCH_LOG:-/dev/null}"
    [[ ${2:-} == *exec_cmd* && -n ${FAKE_LAUNCHED:-} ]] && : >"$FAKE_LAUNCHED"
    ;;
esac
EOF
cat >"$tmp/stub/pgrep" <<'EOF'
#!/bin/bash
echo 4242
EOF
cat >"$tmp/stub/ps" <<'EOF'
#!/bin/bash
echo 5
EOF
chmod +x "$tmp/stub"/*

# Desktop entries covering what a real applications directory has in it: field
# codes, spec quoting, and Exec values holding characters the shell would act
# on. `awkward` is not a hypothetical — an Exec line is allowed to contain a
# `$` or a `;`, and the spec says they are just characters.
mkdir -p "$tmp/share/applications"
cat >"$tmp/share/applications/plain.desktop" <<'EOF'
[Desktop Entry]
Name=Plain
Exec=plainapp %U
EOF
cat >"$tmp/share/applications/quoted.desktop" <<'EOF'
[Desktop Entry]
Name=Quoted
Exec=quotedapp --flag "a b" %f
EOF
cat >"$tmp/share/applications/awkward.desktop" <<'EOF'
[Desktop Entry]
Name=Awkward
Exec=awkwardapp --price "$5;00" --glob "*"
EOF
cat >"$tmp/share/applications/actions.desktop" <<'EOF'
[Desktop Entry]
Name=Actions
Exec=realapp --real

[Desktop Action New]
Name=New
Exec=wrongapp --wrong
EOF

# One profile, one workspace, one pane; each case rewrites the app and args.
write_store() {
  jq -nc --arg app "$1" --arg args "$2" '{
    version: 1, activeProfile: "p", profiles: [{
      id: "p", name: "P", sequence: [1],
      workspaces: { "1": { root: { type: "leaf", app: $app, args: $args } } }
    }]
  }' >"$tmp/profiles.json"
}

# What a dry run says it would launch, which is the argv it would really pass,
# written back out with each word quoted.
launched() {
  write_store "$1" "$2"
  PATH="$tmp/stub:$PATH" XDG_DATA_DIRS="$tmp/share" XDG_RUNTIME_DIR="$tmp/run" \
    WORKSPACE_PROFILES_STORE="$tmp/profiles.json" \
    "$APPLY" --dry-run --no-notify --profile p 2>&1 |
    sed -n 's/^  launch    //p'
}

check() {
  local name="$1" got="$2" want="$3"
  if [[ $got == "$want" ]]; then
    ((passed++))
  else
    ((failed++))
    printf 'FAIL  %s\n--- want ---\n%s\n--- got ---\n%s\n\n' "$name" "$want" "$got" >&2
  fi
}

check_has() {
  local name="$1" got="$2" want="$3"
  if [[ $got == *"$want"* ]]; then
    ((passed++))
  else
    ((failed++))
    printf 'FAIL  %s\n--- wanted to contain ---\n%s\n--- got ---\n%s\n\n' "$name" "$want" "$got" >&2
  fi
}

# ------------------------------------------------------------------ no args

# Nothing typed means the launcher call Omarchy makes everywhere else, which
# copes with entries whose Exec is not worth reconstructing.
check "a pane with no arguments goes through gtk-launch" \
  "$(launched plain '')" \
  "'uwsm-app' '--' 'gtk-launch' 'plain.desktop'"

# ---------------------------------------------------------------- Exec lines

# Field codes stand for the files and URLs a launcher would be opening. There
# are none here, so they expand to nothing and take their argument with them.
check "field codes expand to nothing" \
  "$(launched plain '--here')" \
  "'uwsm-app' '--' 'plainapp' '--here'"

# The spec quotes with double quotes, and a quoted argument is one argument.
check "a quoted Exec argument stays one argument" \
  "$(launched quoted '--here')" \
  "'uwsm-app' '--' 'quotedapp' '--flag' 'a b' '--here'"

# The case eval got wrong. `$5;00` is a price and `*` is a literal asterisk —
# the spec gives neither of them any meaning, and the shell gives both.
check "shell characters in an Exec line are text" \
  "$(launched awkward '--here')" \
  "'uwsm-app' '--' 'awkwardapp' '--price' '\$5;00' '--glob' '*' '--here'"

# An action group further down the file has its own Exec, and it is not this one.
check "only the Desktop Entry group's Exec is read" \
  "$(launched actions '--here')" \
  "'uwsm-app' '--' 'realapp' '--real' '--here'"

# ----------------------------------------------------------------- arguments

# The box is a command line, so quoting works the way it does in a terminal.
check "a quoted argument is one argument" \
  "$(launched plain '--title "two words"')" \
  "'uwsm-app' '--' 'plainapp' '--title' 'two words'"

check "single quotes work too" \
  "$(launched plain "--title 'two words'")" \
  "'uwsm-app' '--' 'plainapp' '--title' 'two words'"

# Command substitution is text. This is the one that mattered: typing it used
# to run it, at every login, before the app was even started.
check "command substitution in arguments is text" \
  "$(launched plain '$(id) `id`')" \
  "'uwsm-app' '--' 'plainapp' '\$(id)' '\`id\`'"

# So is everything else that would have chained, redirected or expanded.
check "separators and redirections in arguments are text" \
  "$(launched plain '; touch /tmp/x > /tmp/y')" \
  "'uwsm-app' '--' 'plainapp' ';' 'touch' '/tmp/x' '>' '/tmp/y'"

check "a glob in arguments is not expanded" \
  "$(launched plain '/etc/*')" \
  "'uwsm-app' '--' 'plainapp' '/etc/*'"

check "a variable in arguments is not expanded" \
  "$(launched plain '$HOME ~')" \
  "'uwsm-app' '--' 'plainapp' '\$HOME' '~'"

# A backslash survives the trip through the plan's TSV and back, so a Windows
# path or a Wine argument arrives as it was typed.
check "backslashes survive" \
  "$(launched plain 'C:\Users\me')" \
  "'uwsm-app' '--' 'plainapp' 'C:\\Users\\me'"

# Unbalanced quotes are a typo, not an instruction. The app still opens; it
# just opens the way an app with nothing typed after it does.
out="$(launched plain 'oops "unbalanced')"
check "unbalanced quotes fall back rather than guess" "$out" \
  "'uwsm-app' '--' 'gtk-launch' 'plain.desktop'"

# ------------------------------------------------------------------- app ids

# `app` is pasted into a path to look for the entry. Only a desktop file id is.
out="$(launched '../../../etc/passwd' '--here' 2>&1)"
check "an app id that is a path launches nothing" "$out" ""

# ----------------------------------------------------------- the hidden path
#
# --test launches through Hyprland's exec, which takes a command line rather
# than an argv, so the words have to be quoted for the shell on the other side.
# Joining them with spaces let an argument containing one come apart, and the
# test then tested a command the real launch would never run.
write_store quoted '--title "two words"'
: >"$tmp/dispatched"
rm -f "$tmp/launched"
PATH="$tmp/stub:$PATH" XDG_DATA_DIRS="$tmp/share" XDG_RUNTIME_DIR="$tmp/run" \
  FAKE_DISPATCH_LOG="$tmp/dispatched" FAKE_LAUNCHED="$tmp/launched" \
  WORKSPACE_PROFILES_STORE="$tmp/profiles.json" \
  "$APPLY" --test --no-notify --profile p >/dev/null 2>&1

check_has "the hidden launch keeps its words together" "$(cat "$tmp/dispatched")" \
  "hl.dsp.exec_cmd([==['uwsm-app' '--' 'quotedapp' '--flag' 'a b' '--title' 'two words']==]"

printf '%d passed, %d failed\n' "$passed" "$failed"
((failed == 0))
