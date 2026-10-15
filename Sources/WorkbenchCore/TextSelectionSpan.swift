import Foundation

/// One selection across consecutive text views of a transcript entry.
///
/// AppKit keeps one selection per text view, so a drag from one paragraph into
/// another is resolved here: the anchor view keeps the part on the drag's side,
/// views in between are selected whole, and the view under the pointer is
/// selected up to the pointer.
public enum TextSelectionSpan {
    public struct Point: Equatable, Sendable {
        public var view: Int
        public var offset: Int
        public init(view: Int, offset: Int) { self.view = view; self.offset = offset }
    }

    /// Ranges by view index for a drag from `anchor` to `focus`, in UTF-16 units.
    /// `lengths` holds each view's text length; views outside the span are absent.
    public static func ranges(anchor: Point, focus: Point, lengths: [Int]) -> [Int: NSRange] {
        guard lengths.indices.contains(anchor.view), lengths.indices.contains(focus.view) else { return [:] }
        func clamp(_ point: Point) -> Int { min(max(0, point.offset), lengths[point.view]) }
        let start = clamp(anchor), end = clamp(focus)
        if anchor.view == focus.view {
            return [anchor.view: NSRange(location: min(start, end), length: abs(end - start))]
        }
        var result: [Int: NSRange] = [:]
        let down = focus.view > anchor.view
        result[anchor.view] = down ? NSRange(location: start, length: lengths[anchor.view] - start)
                                   : NSRange(location: 0, length: start)
        result[focus.view] = down ? NSRange(location: 0, length: end)
                                  : NSRange(location: end, length: lengths[focus.view] - end)
        for view in (min(anchor.view, focus.view) + 1)..<max(anchor.view, focus.view) {
            result[view] = NSRange(location: 0, length: lengths[view])
        }
        return result
    }
}
