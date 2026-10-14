import Foundation

/// Page whole process rows so their tool/thought identity and source stay intact.
/// Timeline rows already cap their source parts at 24; a page mounts at most 8 rows.
public struct ConversationProcessPage {
    public static let size = 8
    public let range: Range<Int>
    public let number: Int
    public let count: Int
    public init(ids: [String], anchor: String?) {
        let index = anchor.flatMap { ids.firstIndex(of: $0) } ?? 0
        let start = index / Self.size * Self.size
        range = start..<min(ids.count, start + Self.size)
        number = ids.isEmpty ? 0 : start / Self.size + 1
        count = (ids.count + Self.size - 1) / Self.size
    }
}
