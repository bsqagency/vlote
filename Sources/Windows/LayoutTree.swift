import Foundation
import CoreGraphics

enum SplitAxis {
    case columns   // children side by side, left to right
    case rows      // children stacked, top to bottom

    var flipped: SplitAxis { self == .columns ? .rows : .columns }
}

/// The arrangement of windows on one screen, as a tree.
///
/// A flat list plus a layout function cannot express "these two windows share
/// the slot where one window used to be" — which is exactly what dropping a
/// window onto another one means. So the arrangement is a tree: leaves are
/// windows, splits divide their area among children by weight.
///
/// Dropping window C onto window B turns `leaf(B)` into `split(.rows, [B, C])`.
/// Dropping D onto C then finds C's parent is already a `.rows` split and adds
/// D as a third sibling — two rows become three, which is the behaviour you get
/// by repeating the gesture.
indirect enum LayoutNode {
    case leaf(CGWindowID)
    case split(SplitAxis, [LayoutNode], [CGFloat])   // weights sum to 1

    // MARK: - Queries

    var ids: [CGWindowID] {
        switch self {
        case .leaf(let id):           return [id]
        case .split(_, let kids, _):  return kids.flatMap(\.ids)
        }
    }

    func contains(_ id: CGWindowID) -> Bool {
        switch self {
        case .leaf(let leafID):       return leafID == id
        case .split(_, let kids, _):  return kids.contains { $0.contains(id) }
        }
    }

    // MARK: - Frames

    /// Walks the tree assigning each leaf a rect. Cocoa coordinates, so for a
    /// `.rows` split child 0 must be the TOP one — hence counting down from maxY.
    func frames(in rect: CGRect, gap: CGFloat) -> [CGWindowID: CGRect] {
        var out: [CGWindowID: CGRect] = [:]
        assign(rect: rect, gap: gap, into: &out)
        return out
    }

    private func assign(rect: CGRect, gap: CGFloat, into out: inout [CGWindowID: CGRect]) {
        switch self {
        case .leaf(let id):
            out[id] = rect

        case .split(let axis, let kids, let weights):
            guard !kids.isEmpty else { return }
            let n = CGFloat(kids.count)
            let totalGap = gap * (n - 1)
            var offset: CGFloat = 0

            for (index, child) in kids.enumerated() {
                let weight = weights.indices.contains(index) ? weights[index] : 1 / n
                let childRect: CGRect

                switch axis {
                case .columns:
                    let available = max(rect.width - totalGap, 1)
                    let w = available * weight
                    childRect = CGRect(x: rect.minX + offset, y: rect.minY,
                                       width: w, height: rect.height)
                    offset += w + gap

                case .rows:
                    let available = max(rect.height - totalGap, 1)
                    let h = available * weight
                    childRect = CGRect(x: rect.minX, y: rect.maxY - offset - h,
                                       width: rect.width, height: h)
                    offset += h + gap
                }
                child.assign(rect: childRect, gap: gap, into: &out)
            }
        }
    }

    // MARK: - Mutation

    /// Removes a window, collapsing any split left with a single child and
    /// redistributing the freed weight proportionally among its siblings.
    /// Returns nil if the whole subtree is gone.
    func removing(_ id: CGWindowID) -> LayoutNode? {
        switch self {
        case .leaf(let leafID):
            return leafID == id ? nil : self

        case .split(let axis, let kids, let weights):
            var newKids: [LayoutNode] = []
            var newWeights: [CGFloat] = []

            for (index, child) in kids.enumerated() {
                guard let kept = child.removing(id) else { continue }
                newKids.append(kept)
                newWeights.append(weights.indices.contains(index) ? weights[index] : 0)
            }

            if newKids.isEmpty { return nil }
            if newKids.count == 1 { return newKids[0] }   // collapse
            return .split(axis, newKids, normalise(newWeights))
        }
    }

    /// Inserts `id` beside `target`, splitting along `axis`.
    ///
    /// If target's parent is already a split on the same axis, the new window
    /// joins it as a sibling (two rows become three). Otherwise the target leaf
    /// becomes a two-child split, and the new window takes half of the target's
    /// share so every other window keeps its size.
    func inserting(_ id: CGWindowID,
                   beside target: CGWindowID,
                   axis: SplitAxis,
                   before: Bool) -> LayoutNode {
        switch self {
        case .leaf(let leafID):
            guard leafID == target else { return self }
            let pair: [LayoutNode] = before
                ? [.leaf(id), .leaf(target)]
                : [.leaf(target), .leaf(id)]
            return .split(axis, pair, [0.5, 0.5])

        case .split(let myAxis, let kids, let weights):
            // Target sitting directly under a split of the same axis: become a sibling.
            if myAxis == axis,
               let slot = kids.firstIndex(where: { if case .leaf(target) = $0 { return true }; return false }) {

                var newKids = kids
                var newWeights = weights.count == kids.count
                    ? weights
                    : Array(repeating: 1 / CGFloat(kids.count), count: kids.count)

                let share = newWeights[slot] / 2
                newWeights[slot] = share

                let insertAt = before ? slot : slot + 1
                newKids.insert(.leaf(id), at: insertAt)
                newWeights.insert(share, at: insertAt)

                return .split(myAxis, newKids, normalise(newWeights))
            }

            // Otherwise recurse into whichever child holds the target.
            let newKids = kids.map { child -> LayoutNode in
                child.contains(target)
                    ? child.inserting(id, beside: target, axis: axis, before: before)
                    : child
            }
            return .split(myAxis, newKids, weights)
        }
    }

    /// Adds a window with no drop target — a newly opened window.
    /// It takes half of the largest current tile, split along that tile's longer
    /// edge, which keeps the arrangement balanced the way the preset would.
    func appending(_ id: CGWindowID, in area: CGRect, gap: CGFloat) -> LayoutNode {
        let current = frames(in: area, gap: gap)
        guard let biggest = current.max(by: { $0.value.area < $1.value.area }) else {
            return .leaf(id)
        }
        let rect = biggest.value
        return inserting(id,
                         beside: biggest.key,
                         axis: rect.width >= rect.height ? .columns : .rows,
                         before: false)
    }

    /// Drops windows that are gone and adds ones that are new, leaving every
    /// surviving window exactly where it was.
    static func sync(_ tree: LayoutNode?,
                     to ids: [CGWindowID],
                     in area: CGRect,
                     gap: CGFloat) -> LayoutNode? {
        let live = Set(ids)
        var result = tree

        for stale in (tree?.ids ?? []) where !live.contains(stale) {
            result = result?.removing(stale)
        }

        let present = Set(result?.ids ?? [])
        for id in ids where !present.contains(id) {
            result = result.map { $0.appending(id, in: area, gap: gap) } ?? .leaf(id)
        }
        return result
    }

    // MARK: - Presets

    /// Builds a fresh tree in the shape of one of the preset layouts.
    static func build(kind: LayoutKind, ids: [CGWindowID], masterRatio: CGFloat) -> LayoutNode? {
        guard !ids.isEmpty else { return nil }
        guard ids.count > 1 else { return .leaf(ids[0]) }

        switch kind {
        case .columns:
            return .split(.columns, ids.map { .leaf($0) }, equal(ids.count))
        case .rows:
            return .split(.rows, ids.map { .leaf($0) }, equal(ids.count))

        case .masterStack:
            let stack = Array(ids.dropFirst())
            let rest: LayoutNode = stack.count == 1
                ? .leaf(stack[0])
                : .split(.rows, stack.map { .leaf($0) }, equal(stack.count))
            let r = min(max(masterRatio, 0.15), 0.85)
            return .split(.columns, [.leaf(ids[0]), rest], [r, 1 - r])

        case .grid:
            let cols = Int(ceil(sqrt(Double(ids.count))))
            let rows = stride(from: 0, to: ids.count, by: cols).map {
                Array(ids[$0..<min($0 + cols, ids.count)])
            }
            let rowNodes: [LayoutNode] = rows.map { row in
                row.count == 1 ? .leaf(row[0])
                               : .split(.columns, row.map { .leaf($0) }, equal(row.count))
            }
            return rowNodes.count == 1 ? rowNodes[0]
                                       : .split(.rows, rowNodes, equal(rowNodes.count))

        case .bsp:
            return bsp(ids)
        }
    }

    /// Recursive halving, always splitting the side that holds more windows
    /// proportionally so an odd count does not leave one window oversized.
    private static func bsp(_ ids: [CGWindowID]) -> LayoutNode {
        guard ids.count > 1 else { return .leaf(ids[0]) }
        let half = ids.count / 2
        let left = Array(ids[0..<half])
        let right = Array(ids[half...])
        let weight = CGFloat(left.count) / CGFloat(ids.count)
        // Alternating axis by depth is what keeps BSP tiles near-square; the
        // frame walk starts on a wide screen, so start with columns.
        return .split(.columns, [bsp(left), bsp(right)], [weight, 1 - weight])
            .alternatingAxes(depth: 0)
    }

    /// Flips the axis at every other depth, turning a pure-columns skeleton into
    /// a proper near-square BSP.
    private func alternatingAxes(depth: Int) -> LayoutNode {
        switch self {
        case .leaf:
            return self
        case .split(_, let kids, let weights):
            let axis: SplitAxis = depth.isMultiple(of: 2) ? .columns : .rows
            return .split(axis, kids.map { $0.alternatingAxes(depth: depth + 1) }, weights)
        }
    }

    // MARK: - Weights

    private static func equal(_ n: Int) -> [CGFloat] {
        Array(repeating: 1 / CGFloat(n), count: n)
    }

    private func normalise(_ weights: [CGFloat]) -> [CGFloat] {
        let total = weights.reduce(0, +)
        guard total > 0 else { return LayoutNode.equal(weights.count) }
        return weights.map { $0 / total }
    }
}
