import Foundation

/// UI language preference. The development language of the app is Simplified
/// Chinese: every user-facing literal in `Sources/` is its own localization
/// key, and `Resources/Localization/en.lproj/Localizable.strings` carries the
/// English translations. Chinese needs no table — a missed lookup falls back
/// to the key itself.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case zhHans = "zh-Hans"
    case en

    public static let defaultsKey = "perch.appLanguage"

    public var id: String { rawValue }

    public static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }

    /// Locale applied to the SwiftUI environment and to `L()`. `nil` means
    /// follow the system; callers then use `.autoupdatingCurrent`.
    public var locale: Locale? {
        switch self {
        case .system: return nil
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .en: return Locale(identifier: "en")
        }
    }

    /// Self-describing name, shown in the language picker regardless of the
    /// active UI language.
    public var displayName: String {
        switch self {
        case .system: return "跟随系统 / System"
        case .zhHans: return "中文"
        case .en: return "English"
        }
    }

    public var resolvedLocale: Locale { locale ?? .autoupdatingCurrent }

    /// Keeps system-level UI (AppKit menus, alerts, next launch) consistent with
    /// the in-app choice. SwiftUI views switch immediately through the
    /// environment locale, so this only matters outside the view hierarchy.
    public static func applyToSystem(_ language: AppLanguage) {
        switch language {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        default: UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }
}

/// Localizes a dynamic string through the app bundle's `Localizable.strings`
/// using the language selected in Settings. SwiftUI literals (`Text("…")`,
/// `Button("…")`, …) already resolve through the environment locale; use `L()`
/// for `String` values that flow into views as data (status labels, error
/// messages, interpolated summaries) so both paths agree on one language.
public func L(_ keyAndValue: String.LocalizationValue) -> String {
    String(localized: keyAndValue, locale: AppLanguage.current.resolvedLocale)
}

public func L(_ key: String) -> String {
    L(String.LocalizationValue(key))
}
