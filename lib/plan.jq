# Turns one workspace's layout tree into an ordered list of steps that rebuild
# it in Hyprland's dwindle layout.
#
# Dwindle's only structural operation is "split one existing window in two", so
# the tree has to be built top-down: at each split node, the window that already
# occupies the node's whole rectangle is split, and the new window seeds the
# second half. Walking splits in pre-order guarantees the window a step needs to
# split already exists.
#
# Input:  { "root": <node> }        node = leaf {type,app,args}
#                                        | split {type,dir,ratio,a,b}
# Output: TSV rows, one step per line:
#           seed   -       <pane>  -    -       <app>  <args>
#           split  <from>  <pane>  r|d  <ratio> <app>  <args>
#
#   <pane>  dotted path of the leaf the launched window belongs to ("/" = root)
#   <from>  pane whose window gets split; it keeps the first half
#   r|d     preselect direction handed to the dwindle layout message
#   <ratio> fraction of the split taken by the first half
#
# Ratios are carried on the split step rather than applied in a later pass: at
# the moment a split is made, each half is a single window, so a resize lands on
# exactly that split. Once the halves are subdivided further, the same resize
# would hit the innermost split instead.

# Drop leaves with no app, and collapse splits left with a single child, so a
# half-finished layout in the editor still launches the panes that are filled.
def prune:
  if . == null then null
  elif .type == "leaf" then
    (if (.app // "") == "" then null else . end)
  else
    (.a | prune) as $a
    | (.b | prune) as $b
    | if   $a == null and $b == null then null
      elif $a == null then $b
      elif $b == null then $a
      else .a = $a | .b = $b
      end
  end;

def leftmost_path: if .type == "leaf" then [] else ["a"] + (.a | leftmost_path) end;
def leftmost_leaf: if .type == "leaf" then . else (.a | leftmost_leaf) end;
def pstr: if length == 0 then "/" else join(".") end;

# Clamped so a divider dragged to the very edge can't produce a window Hyprland
# refuses to size, and so a missing/garbage ratio still lands on an even split.
def ratio_of: (.ratio // 0.5) | (if type == "number" then . else 0.5 end)
              | if . < 0.15 then 0.15 elif . > 0.85 then 0.85 else . end;

def steps($base):
  if .type == "leaf" then empty
  else
    [ "split"
    , (($base + ["a"] + (.a | leftmost_path)) | pstr)
    , (($base + ["b"] + (.b | leftmost_path)) | pstr)
    , (if .dir == "h" then "d" else "r" end)
    , (ratio_of | tostring)
    , (.b | leftmost_leaf | .app  // "")
    , (.b | leftmost_leaf | .args // "")
    ]
    , (.a | steps($base + ["a"]))
    , (.b | steps($base + ["b"]))
  end;

(.root | prune) as $root
| if $root == null then empty
  else
    ( [ "seed"
      , "-"
      , ($root | leftmost_path | pstr)
      , "-", "-"
      , ($root | leftmost_leaf | .app  // "")
      , ($root | leftmost_leaf | .args // "")
      ]
    , ($root | steps([]))
    )
    | @tsv
  end
