import SwiftUI

/// Children: first is the add control, second the compressible model picker,
/// the last is send; everything between are middle controls. Wide bars keep all
/// on one row; narrow bars shrink the model picker and move middle controls to
/// a second leading row, never squeezing the send button.
struct ComposerToolbarLayout: Layout {
    private func dimensions(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (sizes: [CGSize], width: CGFloat, wraps: Bool, top: CGFloat, bottom: CGFloat) {
        var sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let last = subviews.count - 1
        let ideal = sizes.reduce(CGFloat(40)) { $0 + $1.width }
        let width = proposal.width ?? ideal
        let wraps = ideal > width
        if wraps, subviews.count > 2 {
            let modelWidth = max(0, width - sizes[0].width - sizes[last].width - 20)
            sizes[1] = subviews[1].sizeThatFits(ProposedViewSize(width: modelWidth, height: nil))
        }
        let top = (wraps && subviews.count > 2 ? [sizes[0], sizes[1], sizes[last]] : sizes).map(\.height).max() ?? 0
        let bottom = subviews.count > 3 ? sizes[2..<last].map(\.height).max() ?? 0 : 0
        return (sizes, width, wraps, top, bottom)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let layout = dimensions(proposal, subviews)
        return CGSize(width: layout.width, height: layout.top + (layout.wraps ? layout.bottom + 8 : 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = dimensions(ProposedViewSize(bounds.size), subviews)
        let sizes = layout.sizes
        let last = subviews.count - 1
        guard last >= 1 else { return }
        func place(_ index: Int, x: CGFloat, rowY: CGFloat, rowHeight: CGFloat) {
            subviews[index].place(at: CGPoint(x: x, y: rowY + (rowHeight - sizes[index].height) / 2),
                                  anchor: .topLeading, proposal: ProposedViewSize(sizes[index]))
        }
        place(0, x: bounds.minX, rowY: bounds.minY, rowHeight: layout.top)
        let modelX = bounds.minX + sizes[0].width + 10
        place(1, x: modelX, rowY: bounds.minY, rowHeight: layout.top)
        place(last, x: bounds.maxX - sizes[last].width, rowY: bounds.minY, rowHeight: layout.top)
        // Middle controls keep declaration order: packed right before send on
        // one row, leading on the second row when wrapped.
        if last > 2 {
            let middleWidth = sizes[2..<last].reduce(CGFloat(0)) { $0 + $1.width }
                + 10 * CGFloat(last - 3)
            var x = layout.wraps ? bounds.minX : bounds.maxX - sizes[last].width - 10 - middleWidth
            for index in 2..<last {
                let rowY = layout.wraps ? bounds.minY + layout.top + 8 : bounds.minY
                let rowHeight = layout.wraps ? layout.bottom : layout.top
                place(index, x: x, rowY: rowY, rowHeight: rowHeight)
                x += sizes[index].width + 10
            }
        }
    }
}
