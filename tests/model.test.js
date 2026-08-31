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
  assert.strictEqual(M.setRatioAt(tree, [], 0.01).ratio, 0.15)
  assert.strictEqual(M.setRatioAt(tree, [], 0.99).ratio, 0.85)
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

// ---- the store

test("a store read off disk is coerced into shape", () => {
  const store = M.normalizeStore({
    profiles: [{ id: "x", name: "X", focusWorkspace: 99, workspaces: { "1": { root: { type: "split", dir: "sideways", ratio: 7 } } } }],
    activeProfile: "gone"
  })
  assert.strictEqual(store.profiles[0].focusWorkspace, 1, "an out-of-range workspace falls back")
  assert.strictEqual(store.profiles[0].workspaces["1"].root.dir, "v", "an unknown direction falls back")
  assert.strictEqual(store.profiles[0].workspaces["1"].root.ratio, 0.85, "an absurd ratio is clamped")
  assert.strictEqual(store.activeProfile, "x", "a selection pointing at nothing falls back to the first profile")
})

test("profile ids stay unique", () => {
  const store = M.normalizeStore({ profiles: [{ id: "work", name: "Work" }] })
  assert.strictEqual(M.uniqueProfileId(store, "Work"), "work-2")
  assert.strictEqual(M.uniqueProfileId(store, "After Hours"), "after-hours")
})

console.log(`${passed} passed`)
