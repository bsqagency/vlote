import Foundation
import CoreGraphics

let area = CGRect(x: 0, y: 25, width: 1710, height: 1032)
var failures = 0

func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("  FAIL: \(message)") }
}

func assertSane(_ node: LayoutNode, _ label: String, gap: CGFloat = 0, expect: Int) {
    let f = node.frames(in: area, gap: gap)
    check(f.count == expect, "\(label): \(f.count) frames, expected \(expect)")

    for (id, r) in f {
        check(r.width > 0 && r.height > 0, "\(label): window \(id) has non-positive size")
        check(r.minX >= area.minX - 0.5 && r.maxX <= area.maxX + 0.5 &&
              r.minY >= area.minY - 0.5 && r.maxY <= area.maxY + 0.5,
              "\(label): window \(id) escapes the screen")
    }
    let rects = Array(f.values)
    for i in 0..<rects.count {
        for j in (i + 1)..<rects.count {
            check(!rects[i].insetBy(dx: 0.5, dy: 0.5).intersects(rects[j].insetBy(dx: 0.5, dy: 0.5)),
                  "\(label): two windows overlap")
        }
    }
    if gap == 0 {
        let covered = rects.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
        check(abs(covered / (area.width * area.height) - 1) < 0.01,
              "\(label): covers only \(Int(covered / (area.width * area.height) * 100))%")
    }
}

// ---- Presets ----
for kind in LayoutKind.allCases {
    for n in 1...9 {
        let ids = (1...n).map { CGWindowID($0) }
        guard let tree = LayoutNode.build(kind: kind, ids: ids, masterRatio: 0.6) else {
            failures += 1; print("  FAIL: \(kind.label) n=\(n) built nothing"); continue
        }
        for gap in [CGFloat(0), 2, 12] {
            assertSane(tree, "\(kind.label) n=\(n) gap=\(Int(gap))", gap: gap, expect: n)
        }
        check(Set(tree.ids) == Set(ids), "\(kind.label) n=\(n): window set changed")
    }
}

// ---- The drag gesture: drop onto a window, it splits into rows ----
let A: CGWindowID = 1, B: CGWindowID = 2, C: CGWindowID = 3, D: CGWindowID = 4

var tree = LayoutNode.build(kind: .columns, ids: [A, B], masterRatio: 0.6)!
let twoUp = tree.frames(in: area, gap: 0)
let bSlot = twoUp[B]!
check(twoUp[A]!.maxX <= bSlot.minX + 0.5, "two windows should sit side by side")

// Drop C onto B -> B's tile becomes two rows
tree = tree.inserting(C, beside: B, axis: .rows, before: false)
assertSane(tree, "after 1st drop", expect: 3)
var f = tree.frames(in: area, gap: 0)
check(f[A]! == twoUp[A]!, "dropping onto B must not move A")
check(abs(f[B]!.width - bSlot.width) < 0.5 && abs(f[C]!.width - bSlot.width) < 0.5,
      "B and C should share B's old column width")
check(f[B]!.minY >= f[C]!.maxY - 0.5, "B should be the top row, C below it")
check(abs(f[B]!.height + f[C]!.height - bSlot.height) < 0.5,
      "the two rows should fill B's old tile")

// Drop D onto C -> the same tile becomes THREE rows
tree = tree.inserting(D, beside: C, axis: .rows, before: false)
assertSane(tree, "after 2nd drop", expect: 4)
f = tree.frames(in: area, gap: 0)
check(f[A]! == twoUp[A]!, "second drop must still not move A")
for id in [B, C, D] {
    check(abs(f[id]!.width - bSlot.width) < 0.5, "window \(id) should keep the column width")
}
check(f[B]!.minY >= f[C]!.maxY - 0.5 && f[C]!.minY >= f[D]!.maxY - 0.5,
      "rows should read top to bottom: B, C, D")
check(abs(f[B]!.height + f[C]!.height + f[D]!.height - bSlot.height) < 0.5,
      "three rows should fill B's old tile")

// Dropping sideways splits the other way
var sideways = LayoutNode.build(kind: .columns, ids: [A, B], masterRatio: 0.6)!
sideways = sideways.inserting(C, beside: B, axis: .columns, before: true)
let sf = sideways.frames(in: area, gap: 0)
check(sf[C]!.maxX <= sf[B]!.minX + 0.5, "before:true should place C to the left of B")

// ---- Removal collapses cleanly ----
var shrunk = tree
shrunk = shrunk.removing(C)!
assertSane(shrunk, "after closing C", expect: 3)
shrunk = shrunk.removing(D)!
assertSane(shrunk, "after closing D", expect: 2)
check(shrunk.frames(in: area, gap: 0)[B]!.nearlyEquals(bSlot),
      "closing both dropped windows should give B its tile back")

// ---- sync: windows opening and closing ----
var live = LayoutNode.sync(nil, to: [A, B, C], in: area, gap: 0)
assertSane(live!, "sync from empty", expect: 3)
let before = live!.frames(in: area, gap: 0)[A]!
live = LayoutNode.sync(live, to: [A, B, C, D], in: area, gap: 0)
assertSane(live!, "sync after a window opens", expect: 4)
live = LayoutNode.sync(live, to: [A, D], in: area, gap: 0)
assertSane(live!, "sync after two close", expect: 2)
check(LayoutNode.sync(live, to: [], in: area, gap: 0) == nil, "empty sync should give nil")
_ = before

// ---- Coordinate flip ----
let sample = CGRect(x: 120, y: 340, width: 800, height: 500)
check(Geometry.axToCocoa(Geometry.cocoaToAX(sample)) == sample, "coordinate flip must round-trip")

print(failures == 0 ? "All tree + drop checks passed" : "\(failures) checks FAILED")
exit(failures == 0 ? 0 : 1)
