#!/bin/bash

# Tests for lib/plan.jq — the step list that rebuilds a saved layout in dwindle.
#
# These are the steps that get dispatched at a live compositor, so getting the
# order wrong means windows land in the wrong halves. Each case states the tree
# and the exact steps it must produce.
#
# Run with: tests/plan.test.sh

set -uo pipefail

readonly ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly PLAN="$ROOT/lib/plan.jq"

passed=0
failed=0

check() {
  local name="$1" tree="$2" want="$3" got

  got="$(jq -r -f "$PLAN" <<<"$tree")"
  if [[ $got == "$want" ]]; then
    ((passed++))
  else
    ((failed++))
    printf 'FAIL  %s\n--- want ---\n%s\n--- got ---\n%s\n\n' "$name" "$want" "$got" >&2
  fi
}

# A lone app just opens; there is nothing to split.
check "single pane" \
  '{"root":{"type":"leaf","app":"chromium","args":"https://google.com"}}' \
"$(printf 'seed\t-\t/\t-\t-\tchromium\thttps://google.com')"

# The first app fills the workspace, then it is split to make room for the second.
check "two side by side" \
  '{"root":{"type":"split","dir":"v","ratio":0.7,"a":{"type":"leaf","app":"A"},"b":{"type":"leaf","app":"B"}}}' \
"$(printf 'seed\t-\ta\t-\t-\tA\t\nsplit\ta\tb\tr\t0.7\tB\t')"

# "h" stacks, so the preselect is downwards rather than to the right.
check "two stacked" \
  '{"root":{"type":"split","dir":"h","ratio":0.5,"a":{"type":"leaf","app":"A"},"b":{"type":"leaf","app":"B"}}}' \
"$(printf 'seed\t-\ta\t-\t-\tA\t\nsplit\ta\tb\td\t0.5\tB\t')"

# One big pane beside a stacked pair. The second split divides the window that
# opened for the right-hand column, not the one on the left.
check "one beside a stacked pair" \
  '{"root":{"type":"split","dir":"v","ratio":0.62,
            "a":{"type":"leaf","app":"chromium","args":"https://google.com"},
            "b":{"type":"split","dir":"h","ratio":0.4,
                 "a":{"type":"leaf","app":"foot"},
                 "b":{"type":"leaf","app":"files"}}}}' \
"$(printf 'seed\t-\ta\t-\t-\tchromium\thttps://google.com\nsplit\ta\tb.a\tr\t0.62\tfoot\t\nsplit\tb.a\tb.b\td\t0.4\tfiles\t')"

# A 2x2 grid: the outer split is made first, then each row is split in turn —
# every step splits a window that already exists.
check "two by two grid" \
  '{"root":{"type":"split","dir":"h","ratio":0.5,
            "a":{"type":"split","dir":"v","ratio":0.5,"a":{"type":"leaf","app":"A"},"b":{"type":"leaf","app":"B"}},
            "b":{"type":"split","dir":"v","ratio":0.4,"a":{"type":"leaf","app":"C"},"b":{"type":"leaf","app":"D"}}}}' \
"$(printf 'seed\t-\ta.a\t-\t-\tA\t\nsplit\ta.a\tb.a\td\t0.5\tC\t\nsplit\ta.a\ta.b\tr\t0.5\tB\t\nsplit\tb.a\tb.b\tr\t0.4\tD\t')"

# A layout still being built launches the panes that are filled and ignores the
# rest, rather than refusing or opening a window with no app.
check "half-filled layout drops its empty panes" \
  '{"root":{"type":"split","dir":"v","ratio":0.5,"a":{"type":"leaf","app":"chromium"},"b":{"type":"leaf","app":""}}}' \
"$(printf 'seed\t-\t/\t-\t-\tchromium\t')"

check "a layout with no apps produces no steps" \
  '{"root":{"type":"split","dir":"v","ratio":0.5,"a":{"type":"leaf","app":""},"b":{"type":"leaf","app":""}}}' \
  ""

# Hyprland refuses sizes at the extremes, and a stored ratio is not necessarily
# one the editor produced.
check "ratios are clamped" \
  '{"root":{"type":"split","dir":"v","ratio":0.99,"a":{"type":"leaf","app":"A"},"b":{"type":"leaf","app":"B"}}}' \
"$(printf 'seed\t-\ta\t-\t-\tA\t\nsplit\ta\tb\tr\t0.85\tB\t')"

if ((failed)); then
  echo "$passed passed, $failed failed" >&2
  exit 1
fi

echo "$passed passed"
