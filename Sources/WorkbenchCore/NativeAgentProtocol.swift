import Foundation

public enum NativeAgentWire {
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try KimiWire.decoder().decode(Response<T>.self, from: data).value
    }
    private struct Response<T: Decodable>: Decodable {
        let value: T
        private enum CodingKeys: String, CodingKey { case id, error }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if try container.decodeIfPresent(String.self, forKey: .id) == nil,
               let error = try container.decodeIfPresent(String.self, forKey: .error) {
                throw WorkbenchError(error)
            }
            value = try T(from: decoder)
        }
    }
}

public struct NativeSnapshotResponse: Decodable {
    public let snapshot: NativeAgentSnapshot?
    private enum CodingKeys: String, CodingKey { case unchanged }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try container.decodeIfPresent(Bool.self, forKey: .unchanged) == true
            ? nil : NativeAgentSnapshot(from: decoder)
    }
}

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
    public let permission: PermissionCapability?
    public let thinking: String?
    public let context: ContextUsage?
    public let turnId: String?
    public let turnState: String?
    public let steer: Bool?
    public var status: String { pending > 0 ? L("等你处理") : busy ? L("运行中") : error != nil ? L("出错") : cancelled == true ? L("已停止") : L("就绪") }
    public var budget: ContextBudget? { ContextBudget(used: context?.tokens, limit: context?.limit) }
}

/// Raw usage as the runtime reported it. Absent until a turn has run, which is why
/// both fields are optional rather than defaulting to zero.
public struct ContextUsage: Decodable, Equatable, Sendable {
    public let tokens: Int?
    public let limit: Int?
    public let reportedAt: Double?
}
public struct NativeAgentSnapshot: Decodable {
    public let id: String
    public let provider: SessionKind
    public let title: String
    public let cwd: String
    public let busy: Bool
    public let revision: Int
    public let completed: Int
    public let model: String
    public var messages: [KimiMessage]
    public var history: NativeHistoryWindow?
    public let interactions: [JSONValue]
    public let error: String?
    public let permission: PermissionCapability?
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
    /// The server marks real steering receipts; a promoted prompt has no steer mode.
    public let mode: String?
    public let runtimeTurnId: String?
    public let turnId: String?
    public var activeTurnId: String { runtimeTurnId ?? turnId ?? id }
}

/// Absolute message positions belong to one bridge history epoch. Legacy full
/// responses have no window and remain readable by the same client.
public struct NativeHistoryWindow: Decodable {
    public let epoch: String
    public var start: Int
    public let total: Int
    public let end: Int
    public let indices: [Int]?
    public let baseRevision: Int?
}

extension NativeAgentSnapshot {
    public var hasOlder: Bool { (history?.start ?? 0) > 0 }

    public func applying(to previous: NativeAgentSnapshot?) throws -> NativeAgentSnapshot {
        guard let window = history, let indices = window.indices else { return self }
        guard let previous, previous.id == id, let old = previous.history,
              old.epoch == window.epoch, previous.revision == window.baseRevision,
              old.start == window.start, window.total >= old.start,
              indices.count == messages.count else { throw WorkbenchError("Invalid transcript delta base") }
        var combined = Array(previous.messages.prefix(window.total - old.start))
        var last = old.start - 1
        for (index, message) in zip(indices, messages) {
            guard index > last, index >= old.start, index < window.total,
                  index - old.start <= combined.count else { throw WorkbenchError("Invalid transcript delta position") }
            let offset = index - old.start
            if offset == combined.count { combined.append(message) } else { combined[offset] = message }
            last = index
        }
        guard combined.count == window.total - old.start else { throw WorkbenchError("Incomplete transcript delta") }
        var result = self
        result.messages = combined
        result.history?.start = old.start
        return result
    }

    public func prepending(_ page: NativeAgentSnapshot) throws -> NativeAgentSnapshot {
        guard page.id == id, let old = history, let window = page.history,
              window.indices == nil, window.epoch == old.epoch,
              window.end == old.start, window.start < old.start,
              page.messages.count == old.start - window.start else { throw WorkbenchError("Invalid history page") }
        var result = self
        result.messages = page.messages + messages
        result.history?.start = window.start
        // Keep our revision: the next delta reconciles edits that raced this page.
        return result
    }
}
