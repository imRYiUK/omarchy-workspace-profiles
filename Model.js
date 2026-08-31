// Pure data operations for Workspace Profiles: the layout tree the editor
// manipulates, and the profile store it is saved in.
//
// Nothing here touches a QML type, so tests/model.test.js loads this file
// directly under node. Every tree operation returns a new tree rather than
// mutating the one it was given — QML only re-evaluates a `var` binding when
// the property is reassigned, so an in-place edit would leave the canvas
// showing the old layout.
//
// A layout is a binary tree, which is what Hyprland's dwindle layout is:
//
//   leaf   { type: "leaf",  app, args }
//   split  { type: "split", dir: "v"|"h", ratio, a, b }
//
// "v" splits into left/right, "h" into top/bottom. `ratio` is the fraction of
// the split taken by child `a`.

var WORKSPACES = [1, 2, 3, 4, 5]
var MIN_RATIO = 0.15
var MAX_RATIO = 0.85

function clone(node) {
  return JSON.parse(JSON.stringify(node))
}

function leaf(app, args) {
  return { type: "leaf", app: String(app || ""), args: String(args || "") }
}

function isSplit(node) {
  return !!node && node.type === "split"
}

function clampRatio(value) {
  var n = Number(value)
  if (!isFinite(n)) return 0.5
  return Math.min(MAX_RATIO, Math.max(MIN_RATIO, n))
}

// Coerce anything read off disk into a well-formed tree, so a hand-edited or
// half-written profiles.json renders instead of throwing.
function normalizeNode(node) {
  if (!node || typeof node !== "object") return leaf("")
  if (node.type === "split") {
    return {
      type: "split",
      dir: node.dir === "h" ? "h" : "v",
      ratio: clampRatio(node.ratio),
      a: normalizeNode(node.a),
      b: normalizeNode(node.b)
    }
  }
  return leaf(node.app, node.args)
}

// ------------------------------------------------------------------- paths
//
// A pane is addressed by the branches taken from the root: [] is the root,
// ["a", "b"] is the second child of the first child.

function nodeAt(root, path) {
  var node = root
  for (var i = 0; i < path.length; i++) {
    if (!isSplit(node)) return null
    node = path[i] === "a" ? node.a : node.b
  }
  return node || null
}

function replaceAt(root, path, replacement) {
  if (path.length === 0) return replacement

  var copy = clone(root)
  var parent = copy
  for (var i = 0; i < path.length - 1; i++) {
    if (!isSplit(parent)) return root
    parent = path[i] === "a" ? parent.a : parent.b
  }
  if (!isSplit(parent)) return root

  if (path[path.length - 1] === "a") parent.a = replacement
  else parent.b = replacement
  return copy
}

function samePath(left, right) {
  return left.join(".") === right.join(".")
}

function isAncestor(maybeAncestor, path) {
  if (maybeAncestor.length >= path.length) return false
  for (var i = 0; i < maybeAncestor.length; i++) {
    if (maybeAncestor[i] !== path[i]) return false
  }
  return true
}

function leafPaths(root, base) {
  base = base || []
  if (!isSplit(root)) return [base]
  return leafPaths(root.a, base.concat(["a"])).concat(leafPaths(root.b, base.concat(["b"])))
}

// ------------------------------------------------------------- tree edits

// Turn a pane into a split: whatever was there becomes the first half, and an
// empty pane opens beside it, waiting for an app.
function splitAt(root, path, dir) {
  var target = nodeAt(root, path)
  if (!target) return root
  return replaceAt(root, path, {
    type: "split",
    dir: dir === "h" ? "h" : "v",
    ratio: 0.5,
    a: clone(target),
    b: leaf("")
  })
}

// Remove a pane; its sibling takes over the space they shared. Removing the
// last pane leaves an empty one rather than nothing, so the canvas always has
// a drop target.
function removeAt(root, path) {
  if (path.length === 0) return leaf("")

  var parentPath = path.slice(0, -1)
  var parent = nodeAt(root, parentPath)
  if (!isSplit(parent)) return root

  var sibling = path[path.length - 1] === "a" ? parent.b : parent.a
  return replaceAt(root, parentPath, clone(sibling))
}

function setAppAt(root, path, app, args) {
  var target = nodeAt(root, path)
  if (!target || isSplit(target)) return root
  return replaceAt(root, path, leaf(app, args === undefined ? target.args : args))
}

function setArgsAt(root, path, args) {
  var target = nodeAt(root, path)
  if (!target || isSplit(target)) return root
  return replaceAt(root, path, leaf(target.app, args))
}

function setRatioAt(root, path, ratio) {
  var target = nodeAt(root, path)
  if (!isSplit(target)) return root

  var next = clone(target)
  next.ratio = clampRatio(ratio)
  return replaceAt(root, path, next)
}

// Swap two panes. Refused when one contains the other — there is no sensible
// result, and attempting it would drop a subtree.
function swap(root, pathA, pathB) {
  if (samePath(pathA, pathB)) return root
  if (isAncestor(pathA, pathB) || isAncestor(pathB, pathA)) return root

  var a = nodeAt(root, pathA)
  var b = nodeAt(root, pathB)
  if (!a || !b) return root

  // Neither path is inside the other, so replacing one leaves the other valid.
  return replaceAt(replaceAt(root, pathA, clone(b)), pathB, clone(a))
}

// ------------------------------------------------------------ geometry
//
// Flatten a tree into the rectangles that draw it: one per leaf, one per split
// divider. QML forbids a component from instantiating itself, so the canvas
// renders two flat Repeaters over these lists rather than a recursive item
// tree — which is also less to lay out and gives every divider the rectangle of
// the split it belongs to, so a drag can be read straight off the pointer.
//
// `rect` is {x, y, w, h}; `gap` is the space left between two halves, matching
// the gap Hyprland leaves between two tiled windows.
function layoutRects(node, rect, gap, path, out) {
  path = path || []
  out = out || { leaves: [], dividers: [] }

  if (!isSplit(node)) {
    out.leaves.push({
      key: path.join("."), path: path, node: node,
      x: rect.x, y: rect.y, w: rect.w, h: rect.h
    })
    return out
  }

  var vertical = node.dir === "v"
  var span = vertical ? rect.w : rect.h
  var first = Math.max(0, Math.round((span - gap) * node.ratio))
  var second = Math.max(0, span - gap - first)

  out.dividers.push({
    key: path.join("."), path: path, dir: node.dir,
    x: vertical ? rect.x + first : rect.x,
    y: vertical ? rect.y : rect.y + first,
    w: vertical ? gap : rect.w,
    h: vertical ? rect.h : gap,
    // The whole split's rectangle, so a pointer position can be turned back
    // into a ratio without walking the tree again.
    originX: rect.x, originY: rect.y, spanW: rect.w, spanH: rect.h
  })

  layoutRects(node.a,
    vertical ? { x: rect.x, y: rect.y, w: first, h: rect.h }
             : { x: rect.x, y: rect.y, w: rect.w, h: first },
    gap, path.concat(["a"]), out)

  layoutRects(node.b,
    vertical ? { x: rect.x + first + gap, y: rect.y, w: second, h: rect.h }
             : { x: rect.x, y: rect.y + first + gap, w: rect.w, h: second },
    gap, path.concat(["b"]), out)

  return out
}

// ---------------------------------------------------------------- queries

function filledLeaves(root) {
  if (!isSplit(root)) return (root && root.app) ? 1 : 0
  return filledLeaves(root.a) + filledLeaves(root.b)
}

function isConfigured(workspace) {
  return !!workspace && filledLeaves(workspace.root) > 0
}

function workspaceSummary(profile, workspaceId) {
  var ws = profile && profile.workspaces ? profile.workspaces[String(workspaceId)] : null
  if (!isConfigured(ws)) return ""
  var n = filledLeaves(ws.root)
  return n === 1 ? "1 app" : n + " apps"
}

// ------------------------------------------------------------ the store

function emptyWorkspace() {
  return { root: leaf("") }
}

function newProfile(id, name) {
  return { id: id, name: name, focusWorkspace: 1, workspaces: {} }
}

function normalizeProfile(raw) {
  var profile = newProfile(
    String((raw && raw.id) || "profile"),
    String((raw && raw.name) || (raw && raw.id) || "Profile"))

  var focus = Number(raw && raw.focusWorkspace)
  profile.focusWorkspace = WORKSPACES.indexOf(focus) >= 0 ? focus : 1

  var source = (raw && raw.workspaces) || {}
  for (var i = 0; i < WORKSPACES.length; i++) {
    var key = String(WORKSPACES[i])
    if (source[key]) profile.workspaces[key] = { root: normalizeNode(source[key].root) }
  }
  return profile
}

function normalizeStore(raw) {
  var store = { version: 1, activeProfile: "", loginProfile: "", profiles: [] }
  if (!raw || typeof raw !== "object") return store

  var list = Array.isArray(raw.profiles) ? raw.profiles : []
  for (var i = 0; i < list.length; i++) store.profiles.push(normalizeProfile(list[i]))

  store.activeProfile = String(raw.activeProfile || "")
  store.loginProfile = String(raw.loginProfile || "")

  // A selection pointing at a profile that no longer exists would leave the
  // panel with nothing to show, so fall back to the first one.
  if (!profileById(store, store.activeProfile))
    store.activeProfile = store.profiles.length ? store.profiles[0].id : ""
  if (!profileById(store, store.loginProfile))
    store.loginProfile = ""

  return store
}

function profileById(store, id) {
  if (!store || !store.profiles) return null
  for (var i = 0; i < store.profiles.length; i++) {
    if (store.profiles[i].id === id) return store.profiles[i]
  }
  return null
}

function profileIndex(store, id) {
  for (var i = 0; i < store.profiles.length; i++) {
    if (store.profiles[i].id === id) return i
  }
  return -1
}

// A filesystem- and JSON-key-safe id derived from the display name, with a
// numeric suffix when the obvious one is taken.
function uniqueProfileId(store, name) {
  var base = String(name || "profile").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "")
  if (!base) base = "profile"
  if (!profileById(store, base)) return base

  for (var n = 2; n < 1000; n++) {
    if (!profileById(store, base + "-" + n)) return base + "-" + n
  }
  return base + "-" + Date.now()
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    WORKSPACES: WORKSPACES, leaf: leaf, isSplit: isSplit, clampRatio: clampRatio,
    normalizeNode: normalizeNode, nodeAt: nodeAt, replaceAt: replaceAt, layoutRects: layoutRects,
    isAncestor: isAncestor, leafPaths: leafPaths, splitAt: splitAt, removeAt: removeAt,
    setAppAt: setAppAt, setArgsAt: setArgsAt, setRatioAt: setRatioAt, swap: swap,
    filledLeaves: filledLeaves, isConfigured: isConfigured, workspaceSummary: workspaceSummary,
    emptyWorkspace: emptyWorkspace, newProfile: newProfile, normalizeProfile: normalizeProfile,
    normalizeStore: normalizeStore, profileById: profileById, profileIndex: profileIndex,
    uniqueProfileId: uniqueProfileId
  }
}
