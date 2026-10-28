import AppKit
import Observation
import SwiftUI

/// Perch keeps one monochrome palette in both appearances: the same hues, with
/// lightness inverted for dark. The dark appearance is a designed night scale,
/// not a simple inversion: the canvas is blue-graphite at hue ~226°, and ink,
/// quiet text, and semantic colors are tuned against it for measured contrast
/// (body ink ≈ 12.7:1, quiet ≈ 5.3:1) so long night reads avoid halation. The
/// terminal shares the same canvas. Every value resolves through a dynamic
/// NSColor so AppKit text (cached attributed strings) redraws correctly on
/// appearance changes.
enum WorkbenchTheme {
    /// Primary reading ink: dark slate in light; dark is a soft blue-white held
    /// just below full brightness, which keeps CJK glyphs from blooming on the
    /// graphite canvas.
    static let inkNS = nsColor(light: (0.16, 0.18, 0.23), dark: (0.847, 0.855, 0.882))
    static let ink = Color(nsColor: inkNS)
    /// Monochrome accent: near-black in light, near-white in dark. The dark value
    /// sits one step above `ink`, so primary actions read as the brightest text
    /// tone in the room.
    static let accent = color(light: (0.16, 0.16, 0.17), dark: (0.910, 0.918, 0.941))
    /// De-emphasised ink for status lines and timestamps; dark holds ≈ 5.3:1 on
    /// the canvas — legible, but clearly below body text.
    static let quiet = color(light: (0.48, 0.51, 0.58), dark: (0.520, 0.550, 0.610))
    /// Content surfaces: white in light; dark is the palette's blue-graphite
    /// canvas (#16181E) instead of the system's neutral gray — a designed dark
    /// reads intentional, not default. Sidebar and composer glass keep their
    /// system materials and are unaffected.
    static let contentBackgroundNS = nsColor(
        light: (1, 1, 1), dark: (0.086, 0.094, 0.118))
    static let contentBackground = Color(nsColor: contentBackgroundNS)
    /// Selected sidebar rows: a small light card on the window glass. Translucent,
    /// so the desktop tint still reads through it.
    static let rowCard = Color(nsColor: nsColor(light: NSColor(white: 1, alpha: 0.92),
                                                dark: NSColor(white: 1, alpha: 0.11)))

    /// Glyph color atop the accent-colored primary action circle; dark echoes the
    /// canvas hue so the circle reads as a single molded piece.
    static let actionGlyph = color(light: (1, 1, 1), dark: (0.106, 0.114, 0.141))

    /// Links in reply text; NSTextView resolves dynamic colors while drawing. The
    /// dark value trades a little saturation for luminance so underlined links do
    /// not vibrate against the canvas.
    static let link = nsColor(light: (0.18, 0.36, 0.55), dark: (0.500, 0.651, 0.910))

    /// Diff and hunk ink: in dark, each hue is lifted in lightness and slightly
    /// desaturated, keeping the three roles distinct without neon edges.
    static let diffHunk = nsColor(light: (0.42, 0.32, 0.62), dark: (0.720, 0.631, 0.890))
    static let diffAdded = nsColor(light: (0.12, 0.45, 0.29), dark: (0.357, 0.749, 0.529))
    static let diffRemoved = nsColor(light: (0.64, 0.22, 0.24), dark: (0.898, 0.518, 0.541))

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
    /// Shared by the window title and the conversation's reading controls.
    enum Reading {
        static let inset: CGFloat = 24
        /// The reader's chosen body size; see `ReadingBodySize`.
        static var bodySize: CGFloat { ReadingBodySize.shared.value }
        /// The conversation's one type ramp at the current body size.
        static var scale: ReadingScale { ReadingScale(body: bodySize) }
        /// Conversation chrome outside Markdown prose: thoughts and questions,
        /// process rows and notices, and small counts and hints.
        static var secondarySize: CGFloat { scale.secondary }
        static var labelSize: CGFloat { scale.label }
        static var captionSize: CGFloat { scale.caption }
    }

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
    /// Row and control highlights on opaque surfaces: pressed > selected > hovered.
    /// Keyboard selection is `selected`, so it never reads as a hover. Sidebar rows
    /// on the window glass use `rowCard` instead.
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
        static let row: CGFloat = 10
        static let chip: CGFloat = 5
        static let card: CGFloat = 10
        /// Input remains subordinate to the surrounding reading sheet.
        static let composer: CGFloat = 12
        /// Floating glass controls (return-to-latest, selection bar, bookmarks).
        /// Frame panels use `framePanel(windowCorner:inset:)` instead.
        static let panel: CGFloat = 20
        /// The corner of a toolbar window on macOS 26 and later, used while the
        /// window reports none (full screen, or before the window exists).
        static let toolbarWindowCorner: CGFloat = 26

        /// The window frame's panels — conversation card, inspector and the
        /// narrow-window sidebar overlay — sit `inset` inside the window edge and
        /// share the window corner's center, as macOS concentric shapes do:
        /// R = window corner − inset, never tighter than `card`.
        static func framePanel(windowCorner: CGFloat, inset: CGFloat) -> CGFloat {
            max(card, (windowCorner > 0 ? windowCorner : toolbarWindowCorner) - inset)
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

/// The conversation body size the reader chose in Settings › 界面 › 正文字号 or
/// with View › 放大 / 缩小 / 实际大小 (⌘= ⌘− ⌘0). Observable: every SwiftUI body
/// that reads the reading scale re-renders when it changes, and native row caches
/// compare it before reusing prepared text.
@Observable final class ReadingBodySize {
    static let shared = ReadingBodySize()
    static let defaultsKey = "perch.reading.bodySize"
    /// Mixed CJK and Latin prose reads best one step above the 13 pt macOS UI
    /// body; 16 pt keeps about 42 CJK characters on the 680 pt reading column.
    static let standard: CGFloat = 16
    static let sizes: [CGFloat] = [14, 15, 16, 17, 18]

    private(set) var value: CGFloat

    private init() {
        let stored = CGFloat(UserDefaults.standard.double(forKey: Self.defaultsKey))
        value = Self.sizes.contains(stored) ? stored : Self.standard
    }

    var canIncrease: Bool { value < Self.sizes[Self.sizes.count - 1] }
    var canDecrease: Bool { value > Self.sizes[0] }

    /// Snaps to the nearest offered size and persists it.
    func set(_ size: CGFloat) {
        let nearest = Self.sizes.min { abs($0 - size) < abs($1 - size) } ?? Self.standard
        guard nearest != value else { return }
        value = nearest
        UserDefaults.standard.set(Double(nearest), forKey: Self.defaultsKey)
    }

    /// One offered size larger (+1) or smaller (−1).
    func step(_ direction: Int) {
        let index = Self.sizes.firstIndex(of: value) ?? Self.sizes.firstIndex(of: Self.standard) ?? 0
        set(Self.sizes[min(Self.sizes.count - 1, max(0, index + direction))])
    }
}

/// One type ramp for everything inside the conversation, derived from the body
/// size so the hierarchy keeps its proportions at every setting:
///
/// | Role | Size at 16 pt | Used by |
/// | --- | --- | --- |
/// | heading 1 / 2 | 20 / 18 semibold | Markdown H1 / H2 (H3+ use the body size) |
/// | body | 16 on 26 | replies, user prompts, composer text |
/// | secondary | 14 on 22 | thoughts, quiet notes, code, tables, questions |
/// | label | 13 | process and tool rows, fold headers, activity bar, notices |
/// | caption | 12 | counts, chips, code labels, row actions, small hints |
///
/// No text drops below the 11 pt floor of the visual refresh.
struct ReadingScale: Equatable {
    let body: CGFloat
    var unit: CGFloat { body / ReadingBodySize.standard }
    var bodyLine: CGFloat { (body * 1.625).rounded() }
    var heading1: CGFloat { body + 4 }
    var heading2: CGFloat { body + 2 }
    var secondary: CGFloat { max(11, body - 2) }
    var secondaryLine: CGFloat { (secondary * 1.57).rounded() }
    var label: CGFloat { max(11, body - 3) }
    var caption: CGFloat { max(11, body - 4) }
    /// Vertical rhythm designed at 16 pt, scaled with the body.
    func spacing(_ points: CGFloat) -> CGFloat { (points * unit).rounded() }
}
