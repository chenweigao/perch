import Foundation

/// Page whole process rows so their tool/thought identity and source stay intact.
/// Completed process pages mount 8 stages; each expanded stage pages its own records.
public struct ConversationProcessPage {
    public static let size = 8
    public let range: Range<Int>
    public let number: Int
    public let count: Int
    public init(ids: [String], anchor: String?, pageSize: Int = Self.size) {
        let index = anchor.flatMap { ids.firstIndex(of: $0) } ?? 0
        let start = index / pageSize * pageSize
        range = start..<min(ids.count, start + pageSize)
        number = ids.isEmpty ? 0 : start / pageSize + 1
        count = (ids.count + pageSize - 1) / pageSize
    }
}
