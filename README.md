# Workspace Profiles

An [Omarchy](https://omarchy.org) plugin that opens your session for you.

Say which apps belong on which workspace and drag out the tiling layout they
should open into. Mark one profile as your login profile and the whole thing
builds itself the first time you log in, announced by a notification and nothing
else — no dialog, no click.

![The editor](preview.png)

The layouts are real tiling layouts, not floating windows placed by hand. What
you draw on the canvas is the dwindle tree Hyprland ends up with, ratios and
all, so the result is something you can go on using with your normal keybinds.

- **Five workspaces, any number of profiles** — a morning one, a work one, one
  for whatever you are shipping this week.
- **Apps with their arguments**, so a pane is "Chromium on the dashboard" or
  "a terminal running btop", not just "Chromium".
- **Test** opens every app out of sight and tells you which ones did not start,
  before a login run is the thing that finds out.
- **At login, or on demand** — a right click on the bar icon, or a keybinding
  you choose.

## Install

```bash
omarchy plugin add https://github.com/imRYiUK/omarchy-workspace-profiles.git --enable
```

Then click the ◫ icon in your bar.

It needs Omarchy 4 with the Quickshell bar, Hyprland 0.56 or newer, and
workspaces on the **dwindle** layout; `jq` and `uwsm-app` ship with Omarchy
already. The [requirements](#requirements) spell that out.

It writes one file of its own, `~/.config/omarchy/workspace-profiles/profiles.json`,
and nothing else. Your Hyprland config, your keybindings and your bar config are
left exactly as you wrote them, and removing the plugin takes the widget with it.

To remove it:

```bash
omarchy plugin remove io.github.imryiuk.workspace-profiles
```

## Using it

**The editor** opens on a left click of the bar icon.

- **Profiles** run along the top. `+` makes another, `Rename` renames the one
  you are on, `Delete` appears once there is more than one, and a dot on a chip
  marks the profile that runs at login.
- **Workspaces 1–5** are the row below. A dot means something is set up there,
  and `Clear workspace` empties the one you are on.
- **Search for an app** on the left, then either click it onto the selected pane
  or drag it onto any pane. Where you let go on the pane decides the split:
- **Split a pane** with the `◫` buttons that appear when you hover it — the
  first splits side by side, the second top and bottom. `✕` removes a pane and
  gives its space back to its neighbour.
- **Drag a divider** to set how the space is shared. The drag is continuous —
  a pane you want at 37% goes to 37% — but passing near a quarter, third or
  half lands on it exactly, and the divider goes solid to say so. Hold `Ctrl`
  while dragging to turn the snapping off. Double-click one to even it up
  again.
```
            ┌───────────────────┐
            │ ╲   above (rows) ╱│   drop near an edge and the incoming app
            │  ╲             ╱  │   takes that half: top and bottom split
            │   ╲___________╱   │   into rows, left and right into columns
            │ l │  replace  │ r │
            │ e │           │ i │   the middle replaces what is there
            │ f │___________│ g │   instead of splitting
            │ t ╱           ╲ h │
            │  ╱             ╲ t │
            │ ╱  below (rows) ╲ │
            └───────────────────┘
```

  A highlight shows the half you are about to take before you let go.

- **Drag one pane onto another** the same way to move it there; drop it in the
  middle to swap the two.
- **Arguments** for the selected pane go in the field under the canvas. This is
  what turns "open Chromium" into "open Chromium on google.com", and it takes
  ordinary command-line arguments, so `-e btop` works on a terminal. Quote them
  the way you would in a terminal — `--title "two words"` is one argument — but
  it is a field for arguments, not a shell: a `$HOME`, a `*` or a `;` in there
  is handed to the app as those characters, and nothing is expanded or run.
- **Launch order** along the bottom is the order the workspaces get built in,
  and the first of them is where you are left once everything has opened. Drag a
  workspace along the strip to reorder it. If a workspace was already open it is
  left alone, and if that goes for all of them — nothing was opened — you are
  not moved anywhere either.

*Clicking* an app onto a pane that already has one **splits** it rather than
replacing what was there — a pane you already filled is a decision you made, and
losing it to a mis-click would be worse than an extra divider. Which way it
splits follows the shape of the pane, the same rule dwindle uses: a pane wider
than it is tall becomes two columns, a taller one becomes two rows. So a third
app dropped beside two columns lands under one of them rather than making a
third thin column.

**Capture**, on the workspace row next to Clear workspace, goes the other way: arrange the real workspace by dragging its
windows about in Hyprland, then take that shape as the layout. It reads the
workspace whose tab is open — not the one you happen to be looking at — and
turns the tiled windows on it into panes, matching each window back to the app
that opened it. Gaps and the bar's reserved strip are measured out rather than
counted as layout, so a hand-made half comes back as a half and not as 0.4989.
A window it cannot name still becomes a pane, just an empty one, and the count
of those is reported next to the button.

**Save** writes the profile down. It does not touch the desktop you are on —
the layout opens on its own at your next login, the way an i3 config takes hold
when i3 restarts. To build it into the running session there and then, right
click the bar icon, or bind a key (below); both are deliberate, made from
outside the editor. Edits are also saved on their own a moment after you make
them, so Save is really just the "and I mean it" button.

Keyboard, while the editor is open: `1`–`5` switch workspace, arrows move
between panes, `s` and `S` split the selected pane, `x` removes it, `/` jumps to
the search box, `a` saves, `Esc` closes.

### Test

**Test** answers one question per pane: does this app, with these arguments,
actually open a window? Wrong arguments are the failure worth catching — a
browser given a malformed URL, a terminal given a command that is not installed
— and otherwise they only show up at your next login.

It runs **out of sight**. Every app is started on a special workspace, which
Hyprland only renders while it is toggled open, so the windows really open, are
really checked, and are really closed again without the desktop you are looking
at changing at all. Each pane then carries a ✓ or a `!`, and a notification
gives the tally.

An app with a window **already open** is not started again. It is asked to,
answers by raising the window it has, and nothing new appears for the test to
find — which used to be recorded as a failure for the one kind of app that most
obviously works, since it is on screen while you read the result. A window on
screen already answers the question the test is asking, so the pane passes and
the line says the app was left alone.

One case still surfaces: an app that is already running but opens a **second**
window — a browser web app, mostly — does start something for Hyprland to
catch, but the running copy puts it wherever you are rather than on the test
workspace. The test notices, still counts it as working, closes the window, and
tells you it happened.

### At login

**Open this profile when I log in** is ticked by default — a profile is made to
be opened for you, so a new one takes that job straight away. Untick it on a
profile you only ever apply by hand, or tick it on another to move the job
there; the dot on the chip always shows which profile has it.

It applies once per login, and only
at one — a login run has to reach a Hyprland that started in the last two
minutes, so nothing opens by surprise. That is what makes enabling the plugin,
or an `omarchy-restart-shell` at four in the afternoon, a no-op: the service
starts again either way, sees a session hours old, and does nothing. A second
run inside the same login is blocked as well, by a marker in `$XDG_RUNTIME_DIR`
which the system clears when you log out.

If your login is slow enough that the shell starts more than two minutes after
the compositor, widen the window with `WORKSPACE_PROFILES_BOOT_WINDOW`, in
seconds.

A workspace that already has windows on it is left alone. The first app of a
layout is meant to fill the workspace and every split is measured from there, so
building into an occupied workspace would nest your layout inside whatever was
already open. You get a notification saying which workspaces were skipped.

### From a keybinding

The plugin registers two IPC targets, so a profile can be launched without
touching the bar. It binds no keys of its own and never edits your config, so
pick your own combos — the ones below are placeholders. In
`~/.config/hypr/bindings.lua`:

```lua
o.bind("<YOUR KEYBIND>", "Apply workspace profile", "omarchy-shell workspace-profiles apply morning")
o.bind("<YOUR KEYBIND>", "Edit workspace profiles", "omarchy-shell io.github.imryiuk.workspace-profiles toggle")
```

Replace `<YOUR KEYBIND>` with a combo of your own, written the way Omarchy
writes them (`"SUPER + SHIFT + K"`), and check it against `omarchy-menu` →
Keybindings first so it does not shadow one you already use.

| Call | Effect |
|---|---|
| `omarchy-shell workspace-profiles apply <id>` | apply a profile by id |
| `omarchy-shell workspace-profiles applyActive` | apply the selected profile |
| `omarchy-shell workspace-profiles applyLogin` | the login run — does nothing unless the session is new |
| `bin/workspace-profiles-apply --profile <id> --test` | check every app starts, out of sight |
| `omarchy-shell io.github.imryiuk.workspace-profiles toggle` | open or close the editor |

## Bar settings

Both are optional, set on the widget's entry in `~/.config/omarchy/shell.json`:

| Key | Default | What it does |
|---|---|---|
| `showProfileName` | `false` | put the active profile's name beside the icon |
| `notify` | `true` | send a notification when a profile is applied |

## How the layout actually gets built

Hyprland's dwindle layout has exactly one structural move: split an existing
window in two. There is no "arrange these five windows like this". So a saved
layout is rebuilt from the top down.

At each split, the window already filling that region is focused, a
`preselect` layout message aims the next window at the chosen side, and the app
is launched into it:

```
realize(node, seed):                # seed currently fills node's rectangle
  if node is a leaf:  done          # seed is this pane's window
  else:
    focus(seed)
    layoutmsg preselect  r | d
    new = launch(leftmost leaf of node.b)
    realize(node.a, seed)
    realize(node.b, new)
```

Walking the splits in pre-order means the window a step needs to divide always
exists already. `lib/plan.jq` turns a tree into that step list;
`bin/workspace-profiles-apply` runs it.

Ratios are set right after each split rather than in a pass at the end. At that
moment each half is a single window, so a resize lands on exactly that split;
once the halves have been subdivided further, the same resize would be absorbed
by the innermost split instead.

The orchestration is a shell script rather than QML because it is sequential and
blocking — it waits for each window to map before aiming the next one — and the
Omarchy shell is a single long-running process that should not be waiting on
anything.

## Where things are kept

| Path | What |
|---|---|
| `~/.config/omarchy/workspace-profiles/profiles.json` | your profiles |
| `$XDG_RUNTIME_DIR/omarchy-workspace-profiles/applied` | the once-per-login marker |
| `$XDG_RUNTIME_DIR/omarchy-workspace-profiles/test-result.json` | the last test run |

The bottom two live wherever `XDG_RUNTIME_DIR` points, which is where they
belong: it is private to you and emptied at logout, so the marker lasts exactly
one login. Without it they fall back to `$TMPDIR/omarchy-workspace-profiles-$UID`,
and either way the directory has to be yours and not a symlink before anything
is written into it.

`profiles.json` is plain and hand-editable. A layout is a binary tree, the same
shape as dwindle's:

```json
{
  "version": 1,
  "activeProfile": "morning",
  "loginProfile": "morning",
  "profiles": [{
    "id": "morning",
    "name": "Morning",
    "sequence": [1],
    "workspaces": {
      "1": { "root": {
        "type": "split", "dir": "v", "ratio": 0.62,
        "a": { "type": "leaf", "app": "chromium", "args": "https://google.com" },
        "b": { "type": "split", "dir": "h", "ratio": 0.4,
               "a": { "type": "leaf", "app": "foot", "args": "" },
               "b": { "type": "leaf", "app": "org.gnome.Nautilus", "args": "" } } } }
    }
  }]
}
```

`dir` is `"v"` for side by side and `"h"` for stacked; `ratio` is the share
taken by child `a`; `app` is a desktop entry id. `sequence` is the order the
workspaces are built in — leave it out and they are built in numeric order.

## Requirements

Omarchy 4 with the Quickshell bar, Hyprland 0.56 or newer (the plugin uses the
Lua dispatch API), and the `jq` and `uwsm-app` that Omarchy already installs.
Workspaces must be using the **dwindle** layout — `preselect` is a dwindle
message, and a workspace switched to `scrolling` will open the apps in order
without the splits.

## Development

```bash
git clone https://github.com/imRYiUK/omarchy-workspace-profiles.git
cd omarchy-workspace-profiles

node tests/model.test.js     # tree operations and canvas geometry
tests/plan.test.sh           # the launch plan, step by step
tests/apply.test.sh          # when a login run goes ahead, and where you land

scripts/install              # copy into ~/.config/omarchy/plugins/ and rescan
```

The launcher can be driven without the UI, which is the fastest way to work on
the layout half:

```bash
bin/workspace-profiles-apply --profile morning --dry-run   # print the plan
bin/workspace-profiles-apply --profile morning --test      # check the apps start
bin/workspace-profiles-apply --profile morning             # actually build it
```

Note that Quickshell caches plugin QML — `scripts/install` picks up edits, but
if a change seems not to have landed, `omarchy-restart-shell` forces a clean
reload.

## Not there yet

Per-pane float and fullscreen, workspaces beyond 5, multi-monitor placement,
"save my current desktop as a profile", and exporting profiles. The data model
has room for all of them.

## License

MIT
