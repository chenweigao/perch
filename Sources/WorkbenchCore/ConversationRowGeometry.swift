import Foundation

/// The transcript's reserved row geometry. Scroll lookups must not walk every
/// previously read message on each wheel event.
public struct ConversationRowGeometry {
    public let offsets: [CGFloat]
    public let totalHeight: CGFloat
    private let heights: [CGFloat]

    public init(heights: [CGFloat], spacingAfter: [CGFloat]? = nil) {
        precondition(spacingAfter == nil || spacingAfter!.count == heights.count)
        self.heights = heights
        var y: CGFloat = 0
        offsets = heights.enumerated().map { index, height in
            defer { y += height + (index < heights.count - 1 ? spacingAfter?[index] ?? 18 : 0) }
            return y
        }
        totalHeight = max(0, y)
    }

    /// First row whose content extends below y; count means no intersection.
    public func firstIntersecting(_ y: CGFloat) -> Int {
        boundary { offsets[$0] + heights[$0] <= y }
    }
    public func end(before y: CGFloat) -> Int {
        boundary { offsets[$0] < y }
    }
    /// Gaps belong to the preceding row so reading offsets survive restoration.
    public func readingRow(at y: CGFloat) -> Int? {
        let next = boundary { offsets[$0] <= y }
        return next > 0 ? next - 1 : nil
    }
    /// Retain nearby hosts for direction reversals, without accumulating every
    /// row ever visited. This reserves no extra views and does not preload rows.
    public func retainedRows(around visible: Range<Int>) -> Range<Int> {
        max(0, visible.lowerBound - 12)..<min(heights.count, visible.upperBound + 12)
    }
    private func boundary(_ precedes: (Int) -> Bool) -> Int {
        var lower = 0, upper = offsets.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if precedes(middle) { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
}
