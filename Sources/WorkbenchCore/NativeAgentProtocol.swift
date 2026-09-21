import Foundation

public struct NativeAgentSession: Decodable, Identifiable, Equatable {
    public let id: String
    public let provider: SessionKind
    public let title: String
    public let cwd: String
    public let busy: Bool
    public let archived: Bool
    public let updated: Double
    public let completed: Int
    public let pending: Int
    public let model: String
    public let error: String?
    public let cancelled: Bool?
    public let thinking: String?
    public let context: ContextUsage?
    public let turnId: String?
    public let turnState: String?
    public var status: String { pending > 0 ? L("等你处理") : busy ? L("运行中") : error != nil ? L("出错") : cancelled == true ? L("已停止") : L("就绪") }
    public var budget: ContextBudget? { ContextBudget(used: context?.tokens, limit: context?.limit) }
}

/// Raw usage as the runtime reported it. Absent until a turn has run, which is why
/// both fields are optional rather than defaulting to zero.
public struct ContextUsage: Decodable, Equatable, Sendable {
    public let tokens: Int?
    public let limit: Int?
}
public struct NativeAgentSnapshot: Decodable {
    public let id: String
    public let provider: SessionKind
    public let title: String
    public let cwd: String
    public let busy: Bool
    public let revision: Int
    public let model: String
    public let messages: [KimiMessage]
    public let interactions: [JSONValue]
    public let error: String?
    public let thinking: String?
    public let context: ContextUsage?
    /// Absent for runtimes that never announce commands, which is different from a
    /// runtime that announced an empty list.
    public let commands: [AgentCommand]?
    public let commandResult: NativeCommandResult?
    public var budget: ContextBudget? { ContextBudget(used: context?.tokens, limit: context?.limit) }
}

public struct NativeCommandResult: Decodable {
    public let id: String
    public let status: String
    public let error: String?
}

public struct NativeRequestReceipt: Decodable {
    public let id: String
    public let status: String
    public let error: String?
}
