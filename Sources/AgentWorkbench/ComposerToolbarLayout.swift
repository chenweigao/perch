import SwiftUI

struct ComposerToolbarLayout: Layout {
    private func dimensions(_ proposal: ProposedViewSize, _ subviews: Subviews) -> (sizes: [CGSize], width: CGFloat, wraps: Bool, top: CGFloat, bottom: CGFloat) {
        var sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let ideal = sizes.reduce(CGFloat(40)) { $0 + $1.width }
        let width = proposal.width ?? ideal
        let wraps = ideal > width
        if wraps {
            let modelWidth = max(0, width - sizes[0].width - sizes[4].width - 20)
            sizes[1] = subviews[1].sizeThatFits(ProposedViewSize(width: modelWidth, height: nil))
        }
        let top = (wraps ? [sizes[0], sizes[1], sizes[4]] : sizes).map(\.height).max() ?? 0
        let bottom = max(sizes[2].height, sizes[3].height)
        return (sizes, width, wraps, top, bottom)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let layout = dimensions(proposal, subviews)
        return CGSize(width: layout.width, height: layout.top + (layout.wraps ? layout.bottom + 8 : 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = dimensions(ProposedViewSize(bounds.size), subviews)
        let sizes = layout.sizes
        let modelX = bounds.minX + sizes[0].width + 10
        let positions = [bounds.minX, modelX,
                         layout.wraps ? bounds.minX : modelX + sizes[1].width + 10,
                         bounds.maxX - sizes[3].width - (layout.wraps ? 0 : sizes[4].width + 10),
                         bounds.maxX - sizes[4].width]
        for index in subviews.indices {
            let secondary = layout.wraps && (index == 2 || index == 3)
            let rowY = bounds.minY + (secondary ? layout.top + 8 : 0)
            let rowHeight = secondary ? layout.bottom : layout.top
            subviews[index].place(at: CGPoint(x: positions[index], y: rowY + (rowHeight - sizes[index].height) / 2),
                                  anchor: .topLeading, proposal: ProposedViewSize(sizes[index]))
        }
    }
}
