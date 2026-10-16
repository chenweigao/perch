import AppKit
import SwiftUI
import WorkbenchCore

/// Plain yellow text is hard to read on a light background: the warning title is
/// amber there and keeps system yellow in dark. Its bar and icon keep the tint.
private let warningTitleInk = NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? .systemYellow : NSColor(srgbRed: 0.60, green: 0.40, blue: 0.00, alpha: 1)
}

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
    /// The title's ink; the bar and icon use `tint`.
    var titleInk: Color {
        switch self {
        case .warning: return Color(nsColor: warningTitleInk)
        case .note, .tip, .important, .caution: return tint
        }
    }
}
