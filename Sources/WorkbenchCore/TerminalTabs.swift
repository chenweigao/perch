import Foundation

/// The sidebar inventories remote sessions; these are local views only.
public struct TerminalTabs: Equatable, Sendable {
    public private(set) var ids: [String] = []
    public private(set) var selectedID: String?
    public private(set) var previewID: String?

    public init() {}

    public mutating func open(_ id: String, pinned: Bool = false) {
        if !ids.contains(id) {
            if !pinned, let previous = previewID { ids.removeAll { $0 == previous } }
            ids.append(id)
            if !pinned { previewID = id }
        }
        selectedID = id
        if pinned { pin(id) }
    }

    public mutating func pin(_ id: String) {
        if previewID == id { previewID = nil }
    }

    public mutating func select(_ id: String) {
        guard ids.contains(id) else { return }
        selectedID = id
    }

    public mutating func restoreOrder(_ savedIDs: [String]) {
        let ranks = Dictionary(uniqueKeysWithValues: savedIDs.enumerated().map { ($0.element, $0.offset) })
        ids = ids.enumerated().sorted {
            (ranks[$0.element] ?? savedIDs.count + $0.offset) < (ranks[$1.element] ?? savedIDs.count + $1.offset)
        }.map(\.element)
    }

    public mutating func showOverview() { selectedID = nil }

    public mutating func close(_ id: String) {
        ids.removeAll { $0 == id }
        if previewID == id { previewID = nil }
        if selectedID == id { selectedID = ids.last }
    }
}
