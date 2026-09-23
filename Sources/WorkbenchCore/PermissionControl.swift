import Foundation

public enum PermissionRisk: String, Codable, Sendable {
    case standard
    case elevated
    case dangerous
}

public enum PermissionChangeScope: String, Codable, Sendable {
    case nextMessage = "next-message"
    case nextTurn = "next-turn"
    case newSession = "new-session"
    case runtimeManaged = "runtime-managed"

    public var label: String {
        switch self {
        case .nextMessage: return L("下一条消息生效")
        case .nextTurn: return L("下一轮生效")
        case .newSession: return L("创建会话时固定")
        case .runtimeManaged: return L("运行时逐次确认")
        }
    }
}

public struct PermissionOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let titleKey: String
    public let detailKey: String
    public let risk: PermissionRisk

    public init(id: String, titleKey: String, detailKey: String, risk: PermissionRisk = .standard) {
        self.id = id
        self.titleKey = titleKey
        self.detailKey = detailKey
        self.risk = risk
    }

    public var title: String { L(key: titleKey) }
    public var detail: String { L(key: detailKey) }
}

public struct PermissionCapability: Codable, Equatable, Sendable {
    public let selected: String?
    public let options: [String]
    public let scope: PermissionChangeScope

    public init(selected: String?, options: [String], scope: PermissionChangeScope) {
        self.selected = selected
        self.options = options
        self.scope = scope
    }

    public var canSelect: Bool {
        !options.isEmpty && (scope == .nextMessage || scope == .nextTurn)
    }
}

public enum PermissionCatalog {
    public static let runtimeManaged = "runtime-managed"

    public static func options(for provider: SessionKind) -> [PermissionOption] {
        switch provider {
        case .kimi:
            return [
                PermissionOption(id: "manual", titleKey: "始终询问", detailKey: "每次工具执行前都请求你的批准。"),
                PermissionOption(id: "yolo", titleKey: "需要时询问", detailKey: "由 Kimi 判断何时需要请求批准。", risk: .elevated),
                PermissionOption(id: "auto", titleKey: "从不询问", detailKey: "Kimi 可直接执行工具，不再请求批准。", risk: .dangerous)
            ]
        case .omp:
            return [
                PermissionOption(id: "always-ask", titleKey: "始终询问", detailKey: "执行工具前始终请求你的批准。"),
                PermissionOption(id: "write", titleKey: "允许写入", detailKey: "允许工作区写入；其他敏感操作仍可能请求批准。", risk: .elevated),
                PermissionOption(id: "yolo", titleKey: "自动执行", detailKey: "OMP 不再请求工具执行批准。", risk: .dangerous)
            ]
        case .qoder:
            return [
                PermissionOption(id: "default", titleKey: "默认确认", detailKey: "使用 Qoder 的默认权限策略。"),
                PermissionOption(id: "acceptEdits", titleKey: "自动接受编辑", detailKey: "自动接受文件编辑，其他操作仍按 Qoder 策略确认。", risk: .elevated),
                PermissionOption(id: "plan", titleKey: "仅规划", detailKey: "只规划任务，不直接执行修改。"),
                PermissionOption(id: "dontAsk", titleKey: "不主动询问", detailKey: "尽量继续执行而不向你提问。", risk: .elevated),
                PermissionOption(id: "auto", titleKey: "自动判断", detailKey: "由 Qoder 自动决定工具权限。", risk: .elevated),
                PermissionOption(id: "bypassPermissions", titleKey: "绕过权限检查", detailKey: "跳过 Qoder 权限检查，允许危险操作。", risk: .dangerous)
            ]
        case .dsh:
            return [PermissionOption(id: runtimeManaged, titleKey: "运行时逐次确认", detailKey: "DeepSeek 在每次需要权限时通过运行时审批卡片询问。")]
        case .codex:
            return [
                PermissionOption(id: "read-only", titleKey: "只读", detailKey: "仅允许读取；写入和其他额外权限需要批准。"),
                PermissionOption(id: "workspace-ask", titleKey: "工作区 · 需要时询问", detailKey: "允许在工作区内写入，额外权限由你批准。"),
                PermissionOption(id: "workspace-auto", titleKey: "工作区 · 自动执行", detailKey: "允许在工作区内写入且不再请求批准。", risk: .elevated),
                PermissionOption(id: "full-access", titleKey: "完全访问", detailKey: "可访问工作区外文件和网络，执行命令时不再请求批准。", risk: .dangerous)
            ]
        case .claude:
            return [
                PermissionOption(id: "default", titleKey: "默认确认", detailKey: "使用 Claude Code 的默认权限策略。"),
                PermissionOption(id: "acceptEdits", titleKey: "自动接受编辑", detailKey: "自动接受文件编辑，其他操作仍按 Claude Code 策略确认。", risk: .elevated),
                PermissionOption(id: "plan", titleKey: "仅规划", detailKey: "只规划任务，不直接执行修改。"),
                PermissionOption(id: "bypassPermissions", titleKey: "绕过权限检查", detailKey: "跳过 Claude Code 权限检查，允许危险操作。", risk: .dangerous)
            ]
        case .terminal:
            return []
        }
    }

    public static func safeDefault(for provider: SessionKind) -> String? {
        switch provider {
        case .kimi: return "manual"
        case .omp: return "always-ask"
        case .qoder, .claude: return "default"
        case .dsh: return runtimeManaged
        case .codex: return "workspace-ask"
        case .terminal: return nil
        }
    }

    public static func scope(for provider: SessionKind) -> PermissionChangeScope {
        switch provider {
        case .kimi: return .nextMessage
        case .qoder, .claude: return .nextTurn
        case .omp, .codex: return .newSession
        case .dsh, .terminal: return .runtimeManaged
        }
    }

    public static func option(_ id: String?, for provider: SessionKind) -> PermissionOption? {
        guard let id else { return nil }
        return options(for: provider).first { $0.id == id }
    }

    public static func isValid(_ id: String, for provider: SessionKind) -> Bool {
        option(id, for: provider) != nil
    }

    public static func capability(for provider: SessionKind, selected: String? = nil) -> PermissionCapability {
        let available = options(for: provider)
        let scope = scope(for: provider)
        if provider == .dsh {
            return PermissionCapability(selected: runtimeManaged, options: [], scope: scope)
        }
        if provider == .terminal {
            return PermissionCapability(selected: nil, options: [], scope: scope)
        }
        return PermissionCapability(selected: selected, options: available.map(\.id), scope: scope)
    }

    public static func resolvedOptions(_ capability: PermissionCapability, for provider: SessionKind) -> [PermissionOption] {
        let allowed = Set(capability.options)
        return options(for: provider).filter { allowed.contains($0.id) }
    }
}

public enum PermissionDefaults {
    private static let prefix = "perch.permission.default."
    private static let legacyCodexKey = "codex.defaultPermissionMode"

    public static func mode(for provider: SessionKind, defaults: UserDefaults = .standard) -> String? {
        if let stored = defaults.string(forKey: prefix + provider.rawValue), PermissionCatalog.isValid(stored, for: provider) {
            return stored
        }
        if provider == .codex, let legacy = defaults.string(forKey: legacyCodexKey) {
            switch legacy {
            case "full-access": return "full-access"
            case "ask", "auto-review": return "workspace-ask"
            default: break
            }
        }
        return PermissionCatalog.safeDefault(for: provider)
    }

    public static func set(_ mode: String, for provider: SessionKind, defaults: UserDefaults = .standard) {
        guard PermissionCatalog.isValid(mode, for: provider), provider != .dsh, provider != .terminal else { return }
        defaults.set(mode, forKey: prefix + provider.rawValue)
    }

    public static func restoreSafeDefault(for provider: SessionKind, defaults: UserDefaults = .standard) {
        guard let mode = PermissionCatalog.safeDefault(for: provider) else { return }
        defaults.set(mode, forKey: prefix + provider.rawValue)
    }
}
