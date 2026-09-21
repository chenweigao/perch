import Foundation

/// Reasoning effort. Both runtimes accept an unrecognised value without failing —
/// OMP answers success and leaves the level null, Kimi returns code 0 — so a level
/// is only ever sent after checking it against the target model's own list.
public enum ThinkingLevel: String, CaseIterable, Sendable, Equatable {
    case off, minimal, low, medium, high, xhigh, max, auto

    public var label: String {
        switch self {
        case .off: return "Off"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max"
        case .auto: return "Auto"
        }
    }
    public static func parse(_ value: String?) -> ThinkingLevel? {
        guard let value, !value.isEmpty else { return nil }
        return ThinkingLevel(rawValue: value.lowercased())
    }
}

/// A model the user can pick, with the effort levels that model actually accepts.
/// An empty `thinking` list means the model has no reasoning control, which must be
/// shown as unavailable rather than as a default level.
public struct AgentModel: Identifiable, Equatable, Sendable {
    /// What the runtime expects back when selecting: OMP's provider + id pair is
    /// carried separately because `set_model` rejects a combined "provider/id".
    public let id: String
    public let provider: String
    public let name: String
    public let contextWindow: Int?
    public let thinking: [ThinkingLevel]
    public let defaultThinking: ThinkingLevel?
    /// The runtime that can route this model. `provider` is the model's own vendor
    /// and says nothing about that, so a combined catalog needs this to avoid
    /// offering a dsh route to OMP. Nil means the catalog did not say.
    public let agent: SessionKind?

    public init(id: String, provider: String, name: String, contextWindow: Int? = nil,
                thinking: [ThinkingLevel] = [], defaultThinking: ThinkingLevel? = nil,
                agent: SessionKind? = nil) {
        self.id = id; self.provider = provider; self.name = name
        self.contextWindow = contextWindow; self.thinking = thinking
        self.defaultThinking = thinking.contains(where: { $0 == defaultThinking }) ? defaultThinking : nil
        self.agent = agent
    }

    public var supportsThinking: Bool { !thinking.isEmpty }
    public func accepts(_ level: ThinkingLevel) -> Bool { thinking.contains(level) }
    /// The level to fall back to when the current choice is not on this model's list,
    /// so switching models cannot leave an unsupported effort selected.
    public func resolve(_ level: ThinkingLevel?) -> ThinkingLevel? {
        guard supportsThinking else { return nil }
        if let level, accepts(level) { return level }
        return defaultThinking
    }
}

public enum ModelSelectionCatalog {
    /// Parses the bridge's normalized catalog, which `omp models --json` and dsh's
    /// ACP config options are both converted to. Verified against OMP 17.1.4
    /// locally and 18.1.16 on the remote host: both emit provider, id, selector,
    /// name, contextWindow and a thinking array.
    public static func parseOMP(_ value: JSONValue) -> [AgentModel] {
        let items: [JSONValue]
        if case .array(let list) = value { items = list }
        else if case .array(let list) = value["models"] { items = list }
        else { items = value["items"].array }
        return items.compactMap { item in
            guard let id = item["id"].string, !id.isEmpty,
                  let provider = item["provider"].string, !provider.isEmpty else { return nil }
            let levels = item["thinking"].array.compactMap { ThinkingLevel.parse($0.string) }
            return AgentModel(id: id, provider: provider,
                              name: item["name"].string ?? id,
                              contextWindow: item["contextWindow"].int,
                              thinking: levels,
                              // OMP states no default, so the highest offered level is
                              // not assumed to be active.
                              defaultThinking: nil,
                              // An agent this client cannot launch is no agent at all.
                              agent: SessionKind(rawValue: item["agent"].string ?? ""))
        }
    }

    /// The models one runtime can actually route. A bridge that predates tagging
    /// reports no agent at all; hiding every model then would leave a working
    /// session with an empty menu, so an untagged catalog is passed through as the
    /// ambiguous list it always was.
    public static func forAgent(_ kind: SessionKind, in models: [AgentModel]) -> [AgentModel] {
        guard models.contains(where: { $0.agent != nil }) else { return models }
        return models.filter { $0.agent == kind }
    }

    /// Parses Kimi `/api/v1/models`. Effort levels come from `support_efforts`, which
    /// only some models carry; the rest genuinely have no effort control.
    public static func parseKimi(_ items: [JSONValue]) -> [AgentModel] {
        items.compactMap { item in
            guard let id = item["model"].string, !id.isEmpty,
                  let provider = item["provider"].string else { return nil }
            let levels = item["support_efforts"].array.compactMap { ThinkingLevel.parse($0.string) }
            return AgentModel(id: id, provider: provider,
                              name: item["display_name"].string.flatMap { $0.isEmpty ? nil : $0 }
                                  ?? String(id.split(separator: "/").last ?? Substring(id)),
                              contextWindow: item["max_context_size"].int,
                              thinking: levels,
                              defaultThinking: ThinkingLevel.parse(item["default_effort"].string))
        }
    }

    public static func model(_ id: String, in models: [AgentModel]) -> AgentModel? {
        models.first { $0.id == id }
    }
}

/// How much context is left. A runtime that has not reported a window yet is
/// `unknown` rather than shown as empty, since 0 of 0 reads as "nothing used".
public struct ContextBudget: Equatable, Sendable {
    public let used: Int
    public let limit: Int

    public init?(used: Int?, limit: Int?) {
        guard let used, let limit, limit > 0, used >= 0 else { return nil }
        self.used = min(used, limit); self.limit = limit
    }

    public var remaining: Int { limit - used }
    public var usedFraction: Double { Double(used) / Double(limit) }
    public var remainingPercent: Int { Int((1 - usedFraction) * 100) }

    public enum Pressure: Sendable, Equatable { case comfortable, tight, critical }
    public var pressure: Pressure {
        if usedFraction >= 0.9 { return .critical }
        if usedFraction >= 0.75 { return .tight }
        return .comfortable
    }

    /// Remaining is what the user acts on, so it leads. Compaction is the runtime's
    /// own behaviour and is not promised here.
    public var summary: String { "Context remaining: \(remainingPercent)% · \(Self.short(remaining)) / \(Self.short(limit))" }
    public var detail: String { "\(used) of \(limit) tokens used. Reported by the agent; excludes unsent drafts." }

    public static func short(_ tokens: Int) -> String {
        if tokens >= 1_000_000 { return String(format: "%.1fM", Double(tokens) / 1_000_000) }
        if tokens >= 1_000 { return "\(tokens / 1000)K" }
        return "\(tokens)"
    }
}
