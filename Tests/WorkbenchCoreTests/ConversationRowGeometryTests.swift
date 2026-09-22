import Foundation
import WorkbenchCore

func checkConversationRowGeometry() {
    // Every painted turn remains addressable through the lens, including the
    // first/last turn and highly compressed history outside the neighborhood.
    for count in [2, 40, 200, 2_000] {
        for height in [CGFloat(80), 568, 900] {
            let plain = ConversationTurnRailGeometry(count: count, height: height)
            for focus in [0, 1, count / 2, count - 2, count - 1] {
                let pointer = plain.y(for: focus)
                let lens = ConversationTurnRailGeometry(count: count, height: height,
                    focus: .init(index: focus, y: pointer))
                precondition(lens.index(at: pointer) == focus, "Opening a lens must retain the entry under the pointer")
                var previous: CGFloat = -1
                for index in 0..<count {
                    let y = lens.y(for: index)
                    precondition(y > previous && y >= 0 && y <= lens.height)
                    precondition(lens.index(at: y) == index, "Painting and selection must use identical coordinates")
                    previous = y
                }
                precondition(lens.ticks.count <= Int(height / 5) + 3)
                if height / CGFloat(count) < 10 {
                    for index in lens.expanded.dropLast() {
                        precondition(lens.y(for: index + 1) - lens.y(for: index) >= 17,
                                     "Dense neighbors need usable hit targets")
                    }
                }
            }
        }
    }
    let heights: [CGFloat] = [0, 10, 160, 0, 42, 300]
    let geometry = ConversationRowGeometry(heights: heights)
    precondition(geometry.totalHeight == heights.reduce(0, +) + CGFloat(heights.count - 1) * 18)
    // Includes exact starts/ends, gaps, zero-height rows and outside the document.
    for step in -2...Int(geometry.totalHeight + 2) * 2 {
        let y = CGFloat(step) / 2
        precondition(geometry.firstIntersecting(y) == (heights.indices.first { geometry.offsets[$0] + heights[$0] > y } ?? heights.count))
        precondition(geometry.end(before: y) == (geometry.offsets.firstIndex { $0 >= y } ?? heights.count))
        precondition(geometry.readingRow(at: y) == geometry.offsets.indices.last { geometry.offsets[$0] <= y })
    }
    let empty = ConversationRowGeometry(heights: [])
    precondition(empty.totalHeight == 0 && empty.firstIntersecting(0) == 0 && empty.end(before: 1) == 0 && empty.readingRow(at: 0) == nil)

    // Follow the same retention policy across a long history in both directions.
    let long = ConversationRowGeometry(heights: (0..<10_000).map { CGFloat(40 + $0 % 700) })
    var cached: Set<Int> = []
    for first in Array(stride(from: 9_995, through: 0, by: -1)) + Array(0...9_995) {
        let visible = first..<first + 5
        cached.formUnion(visible)
        let retained = long.retainedRows(around: visible)
        cached = cached.filter { retained.contains($0) }
        precondition(Set(visible).isSubset(of: cached), "Visible rows must never be evicted")
        precondition(cached.count <= visible.count + 24, "Retention must not grow with reading depth")
        let y = long.offsets[first] + 1
        precondition(long.readingRow(at: y) == first && long.firstIntersecting(y) == first)
    }
    precondition(long.retainedRows(around: 0..<5).contains(5), "Keep nearby rows for a direction reversal")
    print("PASS: transcript geometry boundaries, reading anchors and bounded retention across 10,000 rows in both directions")
}
