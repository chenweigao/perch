import AppKit
import SwiftUI

/// Perch keeps one monochrome palette in both appearances: the same hues, with
/// lightness inverted for dark. Every value resolves through a dynamic NSColor so
/// AppKit text (cached attributed strings) redraws correctly on appearance changes.
enum WorkbenchTheme {
    /// Primary reading ink: dark slate in light, warm off-white in dark.
    static let ink = color(light: (0.16, 0.18, 0.23), dark: (0.88, 0.885, 0.90))
    /// Monochrome accent: near-black in light, near-white in dark.
    static let accent = color(light: (0.16, 0.16, 0.17), dark: (0.90, 0.90, 0.92))
    /// De-emphasised ink for status lines and timestamps.
    static let quiet = color(light: (0.48, 0.51, 0.58), dark: (0.60, 0.62, 0.68))
    /// Content surfaces were pure white in light; dark uses the system window fill.
    static let contentBackground = Color(nsColor: nsColor(
        light: .white, dark: .windowBackgroundColor))

    /// Glyph color atop the accent-colored primary action circle.
    static let actionGlyph = color(light: (1, 1, 1), dark: (0.13, 0.13, 0.14))

    /// Links in reply text; NSTextView resolves dynamic colors while drawing.
    static let link = nsColor(light: (0.18, 0.36, 0.55), dark: (0.44, 0.63, 0.88))

    static let diffHunk = nsColor(light: (0.42, 0.32, 0.62), dark: (0.70, 0.60, 0.87))
    static let diffAdded = nsColor(light: (0.12, 0.45, 0.29), dark: (0.32, 0.72, 0.50))
    static let diffRemoved = nsColor(light: (0.64, 0.22, 0.24), dark: (0.87, 0.47, 0.49))

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func color(light: (Double, Double, Double),
                              dark: (Double, Double, Double)) -> Color {
        Color(nsColor: nsColor(light: light, dark: dark))
    }

    private static func nsColor(light: (Double, Double, Double),
                                dark: (Double, Double, Double)) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = isDark(appearance) ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }

    private static func nsColor(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            isDark(appearance) ? dark : light
        }
    }
}

/// Appearance override from settings; `system` leaves the scheme to macOS.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    static let defaultsKey = "perch.appearance"
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
}
