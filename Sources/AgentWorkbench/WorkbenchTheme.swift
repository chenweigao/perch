import AppKit
import SwiftUI

/// Perch keeps one monochrome palette in both appearances: the same hues, with
/// lightness inverted for dark. Every value resolves through a dynamic NSColor so
/// AppKit text (cached attributed strings) redraws correctly on appearance changes.
enum WorkbenchTheme {
    /// Primary reading ink: dark slate in light, warm off-white in dark.
    static let inkNS = nsColor(light: (0.16, 0.18, 0.23), dark: (0.88, 0.885, 0.90))
    static let ink = Color(nsColor: inkNS)
    /// Monochrome accent: near-black in light, near-white in dark.
    static let accent = color(light: (0.16, 0.16, 0.17), dark: (0.90, 0.90, 0.92))
    /// De-emphasised ink for status lines and timestamps.
    static let quiet = color(light: (0.48, 0.51, 0.58), dark: (0.60, 0.62, 0.68))
    /// Content surfaces: white in light; dark is a blue-tinted near-black instead
    /// of the system's neutral gray — a designed dark reads intentional, not default.
    /// Sidebar and composer glass keep their system materials and are unaffected.
    static let contentBackgroundNS = nsColor(
        light: (1, 1, 1), dark: (0.104, 0.108, 0.125))
    static let contentBackground = Color(nsColor: contentBackgroundNS)

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

extension WorkbenchTheme {
    /// Sheets and dialogs share one outer padding.
    enum Dialog { static let padding: CGFloat = 24 }

    /// Brand mark colors (Resources/Brand): the only warm hues outside diff/link
    /// semantics. The branch renders in `ink` so the mark adapts to appearance.
    enum Brand {
        static let orbTop = NSColor(srgbRed: 1.0, green: 0.851, blue: 0.557, alpha: 1)      // #FFD98E
        static let orbBottom = NSColor(srgbRed: 1.0, green: 0.478, blue: 0.349, alpha: 1)   // #FF7A59
    }
}

extension WorkbenchTheme {
    /// Row and control highlights, at the sidebar's strengths: pressed > selected > hovered.
    /// Keyboard selection is `selected`, so it never reads as a hover.
    enum Fill {
        static let hover: Double = 0.045
        static let selected: Double = 0.08
        static let pressed: Double = 0.11
        /// A grouped, static surface behind content (cards, chips).
        static let surface: Double = 0.035
    }
    enum Stroke {
        /// Hairline borders of panels and cards.
        static let hairline: Double = 0.08
    }
    /// Corner radii of highlights and containers. Glass surfaces and reply blocks keep their own.
    enum Radius {
        static let row: CGFloat = 7
        static let chip: CGFloat = 5
        static let card: CGFloat = 10
        /// The window frame's panels: sidebar, conversation card and inspector.
        /// Concentric with the window corner across the frame's 12 pt margin.
        static let panel: CGFloat = 16
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
