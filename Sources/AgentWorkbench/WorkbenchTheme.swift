import AppKit
import Observation
import SwiftUI

/// Perch keeps one monochrome palette in both appearances: the same hues, with
/// lightness inverted for dark. The dark appearance is a designed night scale,
/// not a simple inversion: the canvas is blue-graphite at hue ~226°, and ink,
/// quiet text, and semantic colors are tuned against it for measured contrast
/// (body ink ≈ 11.4:1, quiet ≈ 4.7:1) so long night reads avoid halation. The
/// terminal shares the same canvas. Fills, strokes and elevation are independent
/// light/dark tokens, not one alpha shared by both appearances. Every value
/// resolves through a dynamic NSColor so AppKit text (cached attributed strings)
/// redraws correctly on appearance changes.
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
    /// De-emphasised ink for status lines and timestamps; dark holds ≈ 4.7:1 on
    /// the canvas — legible, but clearly below body text.
    static let quietNS = nsColor(light: (0.42, 0.45, 0.51), dark: (0.520, 0.550, 0.610))
    static let quiet = Color(nsColor: quietNS)
    /// Content surfaces: white in light; dark is the palette's blue-graphite
    /// canvas (#1F2229) instead of the system's neutral gray — a designed dark
    /// reads intentional, not default. The canvas sits in the #1E–#26 range of
    /// reading-first dark themes (GitHub Dark Dimmed, ChatGPT): near-black is
    /// for media apps, long-form reading wants a softer ground. Sidebar and
    /// composer glass keep their system materials and are unaffected.
    static let contentBackgroundNS = nsColor(
        light: (1, 1, 1), dark: (0.122, 0.133, 0.161))
    static let contentBackground = Color(nsColor: contentBackgroundNS)
    /// Integrated right-column floating card surface: a calm cool-neutral off-white
    /// in light (#F7F8FA) and an elevated slate in dark (#262932), distinct from
    /// the main conversation canvas so the inspector reads as one cohesive floating card.
    static let inspectorCard = color(
        light: (0.969, 0.973, 0.980), dark: (0.149, 0.161, 0.196))
    /// Raised module card inside the inspector (such as the top Session Overview card):
    /// crisp white in light, one step lighter in dark.
    static let overviewCard = color(
        light: (1.0, 1.0, 1.0), dark: (0.180, 0.196, 0.235))
    /// Selected sidebar rows: a small light card on the window glass. Translucent,
    /// so the desktop tint still reads through it.
    static let rowCard = Color(nsColor: nsColor(light: NSColor(white: 1, alpha: 0.92),
                                                dark: NSColor(white: 1, alpha: 0.11)))
    /// The base beneath the window glass, at the reader's chosen intensity
    /// (Settings › 界面 › 窗口玻璃). Day and night share one setting: a white
    /// underlay in light, the canvas's blue-graphite in dark. `standard` keeps
    /// just over half the desktop's contribution; `clear` is closer to pure
    /// desktop glass, `muted` almost matte.
    static func glassUnderlay(_ intensity: WorkbenchGlassIntensity) -> Color {
        Color(nsColor: nsColor(
            light: NSColor(white: 1, alpha: intensity.lightAlpha),
            dark: NSColor(srgbRed: 0.122, green: 0.133, blue: 0.161, alpha: intensity.darkAlpha)))
    }

    /// Glyph color atop the accent-colored primary action circle; dark echoes the
    /// canvas hue so the circle reads as a single molded piece.
    static let actionGlyphNS = nsColor(light: (1, 1, 1), dark: (0.106, 0.114, 0.141))
    static let actionGlyph = Color(nsColor: actionGlyphNS)

    /// Links in reply text; NSTextView resolves dynamic colors while drawing.
    /// DSH anchor blue (deepseek-500 light / deepseek-400 dark).
    static let link = nsColor(light: (65/255, 118/255, 230/255), dark: (122/255, 170/255, 255/255))

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

    static func nsColor(light: (Double, Double, Double),
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

    /// Inline-code chip fill in prose (DSH: `--dsw-alias-markdown-inline-code`,
    /// neutral-50/800, OPAQUE like the web token: an alpha wash over the glass
    /// backdrop reads as a border-only bubble. Rounded, self-drawn (ReplyTextView).
    static let inlineCodeTintNS = nsColor(light: (250/255, 250/255, 250/255), dark: (41/255, 41/255, 41/255))

    /// Code/mermaid/tool card surface (DSH `--dsw-alias-markdown-code-block`:
    /// neutral-bluish-50 / neutral-bluish-900).
    static let replySurfaceNS = nsColor(light: (249/255, 250/255, 251/255), dark: (27/255, 27/255, 28/255))

    /// Code card banner strip (DSH `--dsw-alias-markdown-code-block-banner`):
    /// identical to the surface in light, a lighter strip in dark.
    static let replyBannerNS = nsColor(light: (249/255, 250/255, 251/255), dark: (44/255, 44/255, 46/255))

    /// User message bubble (DSH `--dsw-specific-bubble`: deepseek-50 light,
    /// neutral-bluish-850 dark) — a blue tint, not a neutral wash.
    static let userBubbleNS = nsColor(light: (237/255, 243/255, 254/255), dark: (44/255, 44/255, 46/255))

    /// A primary-ink wash with independent light/dark alphas. labelColor resolves
    /// inside the requested appearance; applying alpha outside it can freeze the
    /// system appearance in cached AppKit text and layers.
    static func washNS(light: Double, dark: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            var wash = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance {
                wash = NSColor.labelColor.withAlphaComponent(isDark(appearance) ? dark : light)
            }
            return wash
        }
    }

    static func wash(light: Double, dark: Double) -> Color {
        Color(nsColor: washNS(light: light, dark: dark))
    }
}

extension WorkbenchTheme {
    /// Stable interface roles. Reading zoom changes prose, not navigation or controls.
    /// Titles and secondary labels share the body size; weight and color give hierarchy.
    enum Typography {
        static let body: CGFloat = 14
        static let title: CGFloat = body
        static let secondary: CGFloat = body
        static let caption: CGFloat = 12
    }
    /// PI composer-menus.css: compact rows, source rail and reasoning track.
    enum Composer {
        static let text: CGFloat = 12
        static let metadata: CGFloat = 11
        static let rowHeight: CGFloat = 28
        static let railWidth: CGFloat = 116
        static let paneMaximum: CGFloat = 264
        static let sliderHeight: CGFloat = 24
        static let motion = 0.2
        static let raised = WorkbenchTheme.color(light: (1, 1, 1), dark: (40/255, 40/255, 40/255))
        /// PI composer.css .composer-chip and tokens.css radius-md/text-xs-plus.
        enum Citation {
            static let cornerRadius: CGFloat = 12
            static let height: CGFloat = 20
            static let maximumWidth: CGFloat = 240
            static let textSize: CGFloat = 11.5
            static let fill = WorkbenchTheme.nsColor(
                light: NSColor(srgbRed: 26/255, green: 28/255, blue: 31/255, alpha: 0.08),
                dark: NSColor(white: 1, alpha: 0.08))
            static let text = WorkbenchTheme.nsColor(
                light: NSColor(srgbRed: 26/255, green: 28/255, blue: 31/255, alpha: 0.74),
                dark: NSColor(white: 1, alpha: 0.70))
            static let muted = WorkbenchTheme.nsColor(
                light: NSColor(srgbRed: 93/255, green: 93/255, blue: 93/255, alpha: 1),
                dark: NSColor(white: 1, alpha: 0.52))
        }
        /// PI's radius-2xs: model/source rows and the raised reasoning segment.
        enum CompactShape {
            static let cornerRadius: CGFloat = 6
        }
        /// PI's radius-xs: the reasoning range track.
        enum ThinkingTrackShape {
            static let cornerRadius: CGFloat = 8
        }
        static func contextLabel(_ tokens: Int) -> String {
            guard tokens > 0 else { return "—" }
            guard tokens >= 1000 else { return String(tokens) }
            let thousands = Double(tokens) / 1000
            let millions = (thousands * 10).rounded() / 10 >= 1000
            var value = String(format: millions ? "%.2f" : "%.1f", millions ? Double(tokens) / 1_000_000 : thousands)
            while value.hasSuffix("0") { value.removeLast() }
            if value.hasSuffix(".") { value.removeLast() }
            return value + (millions ? "M" : "K")
        }
    }
}

extension WorkbenchTheme {
    /// Shared by the window title and the conversation's reading controls.
    enum Reading {
        static let inset: CGFloat = 24
        /// A fixed breathing space above the scrolling reader, inside the sheet.
        static let topGutter: CGFloat = 12
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


}

extension WorkbenchTheme {
    /// Row and control highlights on opaque surfaces: pressed > selected > hovered.
    /// Each token is a primary-ink wash with its own light/dark alpha: at night,
    /// separation comes from lighter surfaces, so the dark washes are a step
    /// stronger than the light ones. Keyboard selection is `selected`, so it never
    /// reads as a hover. Sidebar rows on the window glass use `rowCard` instead.
    enum Fill {
        static let hover = wash(light: 0.045, dark: 0.055)
        static let selected = wash(light: 0.08, dark: 0.10)
        static let pressed = wash(light: 0.11, dark: 0.14)
        /// A grouped, static surface behind content (cards, chips).
        static let surface = wash(light: 0.035, dark: 0.05)
    }
    enum Stroke {
        /// Hairline borders of panels and cards. At night the hairline carries
        /// more of the region separation than the shadow does, so it is stronger.
        static let hairline = wash(light: 0.08, dark: 0.14)
        /// AppKit layers (CALayer borders) resolve the same token as an NSColor.
        static let hairlineNS = washNS(light: 0.08, dark: 0.14)
    }
    enum Elevation {
        /// Floating-panel shadow color. Light separates with shadow; dark keeps
        /// only a soft contact shadow while hairlines mark the edges.
        static let panelShadow = NSColor(name: nil) { appearance in
            NSColor.black.withAlphaComponent(
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 0.45 : 0.16)
        }
    }
    /// Corner radii of highlights and containers. Glass surfaces and reply blocks keep their own.
    enum Radius {
        static let row: CGFloat = 10
        static let chip: CGFloat = 5
        static let card: CGFloat = 10
        /// The composer's own radius (the message bubble is 20); contains the 36 pt send circle.
        static let composer: CGFloat = 18
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

/// Window-glass strength from Settings › 界面 › 窗口玻璃. One setting tunes both
/// appearances: the light underlay is white at the given alpha, the dark one the
/// canvas's blue-graphite. Higher alpha means calmer, more matte chrome.
enum WorkbenchGlassIntensity: String, CaseIterable, Identifiable {
    case clear
    case light
    case standard
    case muted

    static let defaultsKey = "perch.glassIntensity"
    var id: String { rawValue }

    var lightAlpha: Double {
        switch self {
        case .clear: return 0
        case .light: return 0.30
        case .standard: return 0.45
        case .muted: return 0.70
        }
    }
    var darkAlpha: Double {
        switch self {
        case .clear: return 0.55
        case .light: return 0.70
        case .standard: return 0.85
        case .muted: return 0.95
        }
    }
    var title: LocalizedStringKey {
        switch self {
        case .clear: return "通透"
        case .light: return "轻透"
        case .standard: return "标准"
        case .muted: return "克制"
        }
    }
}

/// Appearance override from settings; `system` leaves the scheme to macOS.
enum AppAppearance: String, CaseIterable, Identifiable {    case system
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
    /// Match the interface by default; retain any explicit reader preference.
    static let standard: CGFloat = WorkbenchTheme.Typography.body
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

/// Reading roles follow the DSH markdown ladder (deepseek-harness 0.2.2, MIT;
/// see docs/2026-11-08-perch-dsh-prose/SOURCE-NOTES.md): the body size carries a
/// constant 10 pt leading (14/24 by default), headings step up through a real
/// ramp, and a secondary tier one step below the body carries thoughts, process
/// rows and tables. Line heights are size + constant leading, not a fixed ratio.
struct ReadingScale: Equatable {
    let body: CGFloat
    var unit: CGFloat { body / ReadingBodySize.standard }
    /// Body line height: 24 pt at the default size, growing one-for-one with it.
    var bodyLine: CGFloat { body + 10 }
    var heading1: CGFloat { body + 7 }
    var heading2: CGFloat { body + 5 }
    var heading3: CGFloat { body + 4 }
    /// Heading line heights keep DSH's constant leading per level.
    var heading1Line: CGFloat { body + 16 }
    var heading2Line: CGFloat { body + 14 }
    var heading3Line: CGFloat { body + 12 }
    /// Secondary tier: −1 through the default size, then −2 (14→13, 18→16).
    var secondary: CGFloat { min(body - 1, max(13, body - 2)) }
    /// Secondary text on a 20 pt line at the default size (13/20).
    var secondaryLine: CGFloat { secondary + 7 }
    var label: CGFloat { secondary }
    var caption: CGFloat { max(WorkbenchTheme.Typography.caption, body - 2) }
    /// Code blocks sit one tier below the body (11 pt by default, DSH's code
    /// setting default); inline code uses 0.875 em at its surrounding size.
    var code: CGFloat { max(11, body - 3) }
    /// Code line pitch: 19 pt at the default size.
    var codeLine: CGFloat { code + 8 }
    /// Preserve the default vertical rhythm; enlarge it with reading zoom.
    func spacing(_ points: CGFloat) -> CGFloat { (points * unit).rounded() }
}
