// Tests for Model.js — the tree operations behind the layout editor.
// Run with: node tests/model.test.js

const assert = require("assert")
const M = require("../Model.js")

let passed = 0
function test(name, fn) {
  try {
    fn()
    passed++
  } catch (error) {
    console.error(`FAIL  ${name}\n      ${error.message}`)
    process.exitCode = 1
  }
}

const leaf = (app) => ({ type: "leaf", app: app, args: "" })
const apps = (node) => M.leafPaths(node).map((p) => M.nodeAt(node, p).app).join(",")

// ---- splitting

test("splitting a leaf keeps it as the first half", () => {
  const next = M.splitAt(leaf("chromium"), [], "v")
  assert.strictEqual(next.type, "split")
  assert.strictEqual(next.dir, "v")
  assert.strictEqual(next.a.app, "chromium")
  assert.strictEqual(next.b.app, "", "the new half starts empty")
})

test("splitting a nested pane leaves the rest of the tree alone", () => {
  const tree = M.splitAt(leaf("a"), [], "v")
  const next = M.splitAt(tree, ["b"], "h")
  assert.strictEqual(apps(next), "a,,")
  assert.strictEqual(next.b.dir, "h")
})

test("editing returns a new tree rather than mutating the old one", () => {
  const tree = leaf("chromium")
  const next = M.splitAt(tree, [], "v")
  assert.strictEqual(tree.type, "leaf", "the original is untouched")
  assert.notStrictEqual(tree, next)
})

// ---- placing an app

test("clicking an app onto an empty pane fills it", () => {
  const r = M.assignApp(leaf(""), [], "chromium")
  assert.strictEqual(r.tree.type, "leaf")
  assert.strictEqual(r.tree.app, "chromium")
  assert.deepStrictEqual(r.path, [], "selection stays on the pane")
})

test("clicking an app onto a filled pane splits it instead of replacing it", () => {
  const r = M.assignApp(leaf("chromium"), [], "foot", "v")
  assert.strictEqual(r.tree.type, "split")
  assert.strictEqual(r.tree.dir, "v", "side by side")
  assert.strictEqual(r.tree.a.app, "chromium", "what was there stays on the left")
  assert.strictEqual(r.tree.b.app, "foot", "the new app goes on the right")
  assert.deepStrictEqual(r.path, ["b"], "selection follows the app that was just placed")
})

test("a tall pane splits into rows rather than columns", () => {
  // Which way a pane splits is the caller's call, because it depends on the
  // shape on screen: three apps in a row would otherwise be three thin columns.
  const r = M.assignApp(leaf("chromium"), [], "foot", "h")
  assert.strictEqual(r.tree.dir, "h")
  assert.strictEqual(r.tree.b.app, "foot", "the new app goes underneath")
})

test("an app dropped on the top of a pane goes above it", () => {
  const r = M.assignApp(leaf("chromium"), [], "foot", "h", true)
  assert.strictEqual(r.tree.dir, "h")
  assert.strictEqual(r.tree.a.app, "foot", "the incoming app takes the top half")
  assert.strictEqual(r.tree.b.app, "chromium")
  assert.deepStrictEqual(r.path, ["a"])
})

// ---- moving a pane onto the side of another

test("a pane dropped on the bottom of another lands under it", () => {
  const tree = {
    type: "split", dir: "v", ratio: 0.5,
    a: leaf("A"),
    b: { type: "split", dir: "h", ratio: 0.5, a: leaf("B"), b: leaf("C") }
  }
  const r = M.movePane(tree, ["b", "b"], ["a"], "h", false)
  assert.strictEqual(apps(r.tree), "A,C,B", "C moved under A; B took over the space C left")
  assert.strictEqual(M.nodeAt(r.tree, ["a"]).dir, "h")
  assert.deepStrictEqual(r.path, ["a", "b"], "selection follows the pane that moved")
})

test("moving a pane re-derives the target path around the hole it leaves", () => {
  // Removing b.b collapses the b split, so the pane that was at b.a is now at
  // b. Splitting the stale path would have hit the wrong pane.
  const tree = {
    type: "split", dir: "v", ratio: 0.5,
    a: leaf("A"),
    b: { type: "split", dir: "h", ratio: 0.5, a: leaf("B"), b: leaf("C") }
  }
  const r = M.movePane(tree, ["b", "b"], ["b", "a"], "v", false)
  assert.strictEqual(apps(r.tree), "A,B,C")
  assert.strictEqual(M.nodeAt(r.tree, ["b"]).dir, "v", "B and C are now side by side")
})

test("a pane cannot be moved inside itself", () => {
  const tree = M.splitAt(leaf("a"), [], "v")
  assert.strictEqual(M.movePane(tree, [], ["a"], "v", false).tree, tree, "the root has nowhere to go")
  const nested = { type: "split", dir: "v", ratio: 0.5, a: { type: "split", dir: "v", ratio: 0.5, a: leaf("A"), b: leaf("B") }, b: leaf("C") }
  assert.strictEqual(M.movePane(nested, ["a"], ["a", "b"], "v", false).tree, nested, "would drop the subtree")
})

// ---- removing

test("removing a pane gives its space to its sibling", () => {
  const tree = M.setAppAt(M.splitAt(leaf("a"), [], "v"), ["b"], "b")
  const next = M.removeAt(tree, ["a"])
  assert.strictEqual(next.type, "leaf")
  assert.strictEqual(next.app, "b")
})

test("removing the last pane leaves an empty one, not nothing", () => {
  const next = M.removeAt(leaf("chromium"), [])
  assert.strictEqual(next.type, "leaf")
  assert.strictEqual(next.app, "")
})

// ---- swapping

test("swapping exchanges two panes", () => {
  const tree = M.setAppAt(M.splitAt(leaf("a"), [], "v"), ["b"], "b")
  const next = M.swap(tree, ["a"], ["b"])
  assert.strictEqual(apps(next), "b,a")
})

test("swapping a pane with one inside it is refused", () => {
  const tree = M.splitAt(leaf("a"), [], "v")
  assert.strictEqual(M.swap(tree, [], ["a"]), tree, "would drop a subtree")
})

// ---- ratios

test("ratios are clamped so a divider cannot be dragged off the edge", () => {
  const tree = M.splitAt(leaf("a"), [], "v")
  assert.strictEqual(M.setRatioAt(tree, [], 0.01).ratio, 0.05)
  assert.strictEqual(M.setRatioAt(tree, [], 0.99).ratio, 0.95)
  assert.strictEqual(M.setRatioAt(tree, [], 0.62).ratio, 0.62)
})

// ---- geometry
//
// The canvas is a scale model of the workspace, so these numbers are the same
// proportions the launcher asks Hyprland for.

test("rectangles divide the canvas by the split ratios", () => {
  const tree = {
    type: "split", dir: "v", ratio: 0.6,
    a: leaf("A"),
    b: { type: "split", dir: "h", ratio: 0.5, a: leaf("B"), b: leaf("C") }
  }
  const { leaves, dividers } = M.layoutRects(tree, { x: 0, y: 0, w: 405, h: 200 }, 5)

  assert.strictEqual(leaves.length, 3)
  assert.strictEqual(dividers.length, 2)

  const A = leaves.find((l) => l.node.app === "A")
  const B = leaves.find((l) => l.node.app === "B")
  const C = leaves.find((l) => l.node.app === "C")

  assert.strictEqual(A.w, 240, "0.6 of (405 - 5)")
  assert.strictEqual(B.x, 245, "starts after A plus the gap")
  assert.strictEqual(A.w + B.w + 5, 405, "the halves and the gap fill the width")
  assert.strictEqual(B.h + C.h + 5, 200, "and the height, inside the right column")
})

test("a divider carries the rectangle of the split it belongs to", () => {
  const tree = { type: "split", dir: "v", ratio: 0.5, a: leaf("A"), b: leaf("B") }
  const { dividers } = M.layoutRects(tree, { x: 10, y: 20, w: 100, h: 50 }, 4)
  const d = dividers[0]
  assert.deepStrictEqual(
    { x: d.originX, y: d.originY, w: d.spanW, h: d.spanH },
    { x: 10, y: 20, w: 100, h: 50 },
    "so a pointer position converts straight back into a ratio")
})

// ---- launch order

test("the sequence lists exactly the configured workspaces", () => {
  const profile = M.normalizeProfile({
    id: "p", name: "P", sequence: [3, 1],
    workspaces: { "1": { root: leaf("a") }, "3": { root: leaf("b") }, "5": { root: leaf("c") } }
  })
  assert.deepStrictEqual(profile.sequence, [3, 1, 5], "the stored order is kept, new ones go on the end")
})

test("a workspace that has been emptied drops out of the sequence", () => {
  const profile = { id: "p", name: "P", sequence: [1, 3], workspaces: { "1": { root: leaf("a") }, "3": { root: leaf("") } } }
  assert.deepStrictEqual(M.syncSequence(profile).sequence, [1])
})

test("a workspace can be dragged to any slot in the sequence", () => {
  assert.deepStrictEqual(M.moveInSequenceTo({ sequence: [1, 3, 5] }, 5, 0).sequence, [5, 1, 3])
  assert.deepStrictEqual(M.moveInSequenceTo({ sequence: [1, 3, 5] }, 1, 2).sequence, [3, 5, 1])
  assert.deepStrictEqual(M.moveInSequenceTo({ sequence: [1, 3, 5] }, 3, 1).sequence, [1, 3, 5], "dropped where it was")
  assert.deepStrictEqual(M.moveInSequenceTo({ sequence: [1, 3, 5] }, 3, 9).sequence, [1, 3, 5], "out of range")
})

// ---- the store

test("a store read off disk is coerced into shape", () => {
  const store = M.normalizeStore({
    profiles: [{ id: "x", name: "X", workspaces: { "1": { root: { type: "split", dir: "sideways", ratio: 7 } } } }],
    activeProfile: "gone"
  })
  assert.strictEqual(store.profiles[0].workspaces["1"].root.dir, "v", "an unknown direction falls back")
  assert.strictEqual(store.profiles[0].workspaces["1"].root.ratio, 0.95, "an absurd ratio is clamped")
  assert.strictEqual(store.activeProfile, "x", "a selection pointing at nothing falls back to the first profile")
})

test("a fresh install ships no apps at all", () => {
  // What the panel seeds when there is no profiles.json: one profile, one
  // workspace, one empty pane. Nothing is preset — the canvas the user first
  // sees is theirs to fill, and a suggested app would just be one to delete.
  const store = M.normalizeStore(null)
  assert.deepStrictEqual(store.profiles, [], "an absent store holds no profiles")

  const seeded = M.newProfile("default", "Default")
  seeded.workspaces["1"] = M.emptyWorkspace()
  assert.strictEqual(M.filledLeaves(seeded.workspaces["1"].root), 0, "no app is preset")
  assert.strictEqual(M.isConfigured(seeded.workspaces["1"]), false)
  assert.deepStrictEqual(M.syncSequence(seeded).sequence, [],
    "and nothing would launch at login")
})

test("the login profile is on by default and stays off once turned off", () => {
  // A store that never named a login profile adopts the active one — opening a
  // profile at login is the point of the plugin.
  const fresh = M.normalizeStore({ activeProfile: "day", profiles: [{ id: "day", name: "Day" }] })
  assert.strictEqual(fresh.loginProfile, "day", "an unnamed login profile defaults to the active one")

  // An explicit "" is the unticked box, and it is kept.
  const off = M.normalizeStore({ activeProfile: "day", loginProfile: "", profiles: [{ id: "day", name: "Day" }] })
  assert.strictEqual(off.loginProfile, "", "an explicit empty login profile is kept")

  // A login profile pointing at a profile that is gone falls back to the active one.
  const stale = M.normalizeStore({ activeProfile: "day", loginProfile: "gone", profiles: [{ id: "day", name: "Day" }] })
  assert.strictEqual(stale.loginProfile, "day", "a stale login profile falls back")
})

test("profile ids stay unique", () => {
  const store = M.normalizeStore({ profiles: [{ id: "work", name: "Work" }] })
  assert.strictEqual(M.uniqueProfileId(store, "Work"), "work-2")
  assert.strictEqual(M.uniqueProfileId(store, "After Hours"), "after-hours")
})

// ---- snapping

test("a ratio near a fraction lands exactly on it", () => {
  assert.strictEqual(M.snapRatio(0.49, 0.05), 0.5)
  assert.strictEqual(M.snapRatio(0.26, 0.05), 0.25)
  assert.ok(Math.abs(M.snapRatio(0.34, 0.05) - 1 / 3) < 1e-9)
})

test("a ratio between fractions is left where it is", () => {
  assert.strictEqual(M.snapRatio(0.42, 0.02), 0.42)
})

test("zero tolerance snaps nothing", () => {
  assert.strictEqual(M.snapRatio(0.499, 0), 0.499)
})

test("snapping still respects the ratio limits", () => {
  assert.strictEqual(M.snapRatio(0.001, 0.05), 0.05)
})

// ---- capturing a layout back off the screen

// The rectangles a tree draws, as the boxes a capture would be handed.
const boxesOf = (tree, gap) =>
  M.layoutRects(tree, { x: 100, y: 60, w: 1920, h: 1080 }, gap).leaves
    .map((l) => ({ x: l.x, y: l.y, w: l.w, h: l.h, app: l.node.app, args: "" }))

test("a captured layout rebuilds the tree it came from", () => {
  const tree = {
    type: "split", dir: "v", ratio: 0.25, a: leaf("a"),
    b: { type: "split", dir: "h", ratio: 0.5, a: leaf("b"), b: leaf("c") }
  }
  assert.deepStrictEqual(M.treeFromBoxes(boxesOf(tree, 6)), tree)
})

test("a gap between windows is taken out of the ratio, not counted as layout", () => {
  const tree = { type: "split", dir: "v", ratio: 0.5, a: leaf("a"), b: leaf("b") }
  // Same layout, three different gaps: the ratio must not drift with the gap.
  for (const gap of [0, 6, 24]) {
    assert.strictEqual(M.treeFromBoxes(boxesOf(tree, gap)).ratio, 0.5)
  }
})

test("a capture keeps a ratio that is deliberately not a round one", () => {
  const tree = { type: "split", dir: "v", ratio: 0.37, a: leaf("a"), b: leaf("b") }
  assert.ok(Math.abs(M.treeFromBoxes(boxesOf(tree, 6)).ratio - 0.37) < 0.005)
})

test("a single window captures as a bare leaf", () => {
  assert.deepStrictEqual(
    M.treeFromBoxes([{ x: 0, y: 0, w: 800, h: 600, app: "foot", args: "" }]),
    leaf("foot"))
})

test("nothing on the workspace captures as an empty leaf", () => {
  assert.deepStrictEqual(M.treeFromBoxes([]), leaf(""))
})

test("a two by two grid captures as two splits inside one", () => {
  const grid = [
    { x: 0, y: 0, w: 950, h: 500, app: "a", args: "" },
    { x: 960, y: 0, w: 950, h: 500, app: "b", args: "" },
    { x: 0, y: 510, w: 950, h: 500, app: "c", args: "" },
    { x: 960, y: 510, w: 950, h: 500, app: "d", args: "" }
  ]
  const out = M.treeFromBoxes(grid)
  assert.strictEqual(out.type, "split")
  assert.strictEqual(out.a.type, "split")
  assert.strictEqual(out.b.type, "split")
  assert.strictEqual(apps(out), "a,c,b,d")
})

test("overlapping windows still all end up in the tree", () => {
  const overlapping = [
    { x: 0, y: 0, w: 800, h: 600, app: "a", args: "" },
    { x: 400, y: 0, w: 800, h: 600, app: "b", args: "" },
    { x: 200, y: 300, w: 800, h: 600, app: "c", args: "" }
  ]
  assert.strictEqual(M.leafPaths(M.treeFromBoxes(overlapping)).length, 3)
})

console.log(`${passed} passed`)
