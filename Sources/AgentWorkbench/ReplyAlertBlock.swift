import SwiftUI
import WorkbenchCore

extension ReplyAlertKind {
    var title: String {
        switch self {
        case .note: return L("注意")
        case .tip: return L("提示")
        case .important: return L("重要")
        case .warning: return L("警告")
        case .caution: return L("当心")
        }
    }
    var symbol: String {
        switch self {
        case .note: return "info.circle"
        case .tip: return "lightbulb"
        case .important: return "exclamationmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .caution: return "xmark.octagon"
        }
    }
    var tint: Color {
        switch self {
        case .note: return .blue
        case .tip: return .green
        case .important: return .purple
        case .warning: return .yellow
        case .caution: return .red
        }
    }
}
