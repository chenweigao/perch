import Foundation

/// The same piecewise mapping paints ticks and resolves pointer hits. A dwell
/// opens a fixed local lens; moving within it never moves the targets away.
public struct ConversationTurnRailGeometry {
    public struct Focus: Equatable {
        public let index: Int
        public let y: CGFloat
        public init(index: Int, y: CGFloat) { self.index = index; self.y = y }
    }
    public let count: Int
    public let height: CGFloat
    public let expanded: Range<Int>
    private let top: CGFloat
    private let bottom: CGFloat

    public init(count: Int, height: CGFloat, focus: Focus? = nil) {
        precondition(count > 0 && height > 0)
        self.count = count
        self.height = min(height, CGFloat(count) * 14)
        if let focus, height / CGFloat(count) < 10, height >= 54 {
            let center = min(max(focus.y, 9), height - 9)
            let before = min(4, focus.index, Int(max(0, center - 10) / 18))
            let after = min(4, count - 1 - focus.index, Int(max(0, height - center - 10) / 18))
            expanded = (focus.index - before)..<(focus.index + after + 1)
            let step: CGFloat = 18
            let lower = center - (CGFloat(before) + 0.5) * step
            let upper = center + (CGFloat(after) + 0.5) * step
            // Reserve room for compressed history at either edge without
            // moving the entry under the pointer out of its expanded hit area.
            top = expanded.lowerBound > 0 ? max(lower, min(1, focus.y / 2)) : lower
            bottom = expanded.upperBound < count ? min(upper, height - min(1, (height - focus.y) / 2)) : upper
        } else {
            expanded = 0..<count
            top = 0
            bottom = self.height
        }
    }

    public func y(for index: Int) -> CGFloat {
        if index < expanded.lowerBound {
            return (CGFloat(index) + 0.5) * top / CGFloat(expanded.lowerBound)
        }
        if index >= expanded.upperBound {
            return bottom + (CGFloat(index - expanded.upperBound) + 0.5) * (height - bottom) / CGFloat(count - expanded.upperBound)
        }
        return top + (CGFloat(index - expanded.lowerBound) + 0.5) * (bottom - top) / CGFloat(expanded.count)
    }

    public func index(at y: CGFloat) -> Int {
        let index: Int
        if y < top && expanded.lowerBound > 0 {
            index = Int(max(0, y) / top * CGFloat(expanded.lowerBound))
        } else if y >= bottom && expanded.upperBound < count {
            index = expanded.upperBound + Int((y - bottom) / (height - bottom) * CGFloat(count - expanded.upperBound))
        } else {
            index = expanded.lowerBound + Int((y - top) / (bottom - top) * CGFloat(expanded.count))
        }
        return min(count - 1, max(0, index))
    }

    /// Paint compressed history at most once per five points, not once per turn.
    public var ticks: [CGFloat] {
        func band(_ range: Range<Int>, _ from: CGFloat, _ to: CGFloat) -> [CGFloat] {
            let n = min(range.count, max(0, Int((to - from) / 5)))
            return (0..<n).map { from + (CGFloat($0) + 0.5) * (to - from) / CGFloat(n) }
        }
        return band(0..<expanded.lowerBound, 0, top)
            + band(expanded, top, bottom)
            + band(expanded.upperBound..<count, bottom, height)
    }
}
