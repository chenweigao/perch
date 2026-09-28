import Foundation

public enum GroupStage: String, Codable, CaseIterable, Sendable {
    case active, paused, completed
    public var title: String {
        switch self { case .active: return "进行中"; case .paused: return "已暂停"; case .completed: return "已完成" }
    }
}

public struct GroupCriterion: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var completed: Bool
    public init(title: String, completed: Bool = false) { self.title = title; self.completed = completed }
}

public struct GroupOutcome: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var title: String
    public var detail: String
    public var link: String
    public var source: SessionReference?
    public init(title: String, detail: String = "", link: String = "", source: SessionReference? = nil) {
        self.title = title; self.detail = detail; self.link = link; self.source = source
    }
    /// Only web links open directly. Remote filesystem paths remain copyable text.
    public var webURL: URL? {
        guard let url = URL(string: link), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }
}

/// Acknowledging a change is independent from reviewing a result or answering an approval.
public struct DashboardObservation: Codable, Equatable, Sendable {
    public let state: String
    public let revision: String
    public init(state: String, revision: String) { self.state = state; self.revision = revision }
    public func isNew(since previous: Self?) -> Bool {
        guard state == "attention" || state == "review" else { return false }
        guard let previous else { return true }
        return state != previous.state || revision != previous.revision
    }
}

/// Freeze the order while a person processes a queue; new arrivals append at the end.
public struct ActionQueueOrder: Equatable {
    public private(set) var ids: [String] = []
    public init() {}
    public mutating func update(_ candidates: [String]) {
        let live = Set(candidates)
        ids.removeAll { !live.contains($0) }
        var known = Set(ids)
        for id in candidates where known.insert(id).inserted { ids.append(id) }
    }
    public func next(after id: String) -> String? {
        guard let index = ids.firstIndex(of: id) else { return ids.first }
        guard ids.count > 1 else { return nil }
        return ids[(index + 1) % ids.count]
    }
}
