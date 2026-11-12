import Foundation

/// UI language, independent of connection state and the user's region format.
public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case zhHans = "zh-Hans"
    case en
    public static let defaultsKey = "perch.appLanguage"
    public var id: String { rawValue }
    public static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system
    }
    /// Each language names itself, so these labels read the same in either UI.
    public var displayName: String {
        switch self {
        case .system: return "跟随系统 / System" // l10n-ignore
        case .zhHans: return "中文" // l10n-ignore
        case .en: return "English" // l10n-ignore
        }
    }
    public var localization: String {
        guard self == .system else { return rawValue }
        // Read system language preferences, not an AppleLanguages override left
        // by a previous in-app choice. Region settings are not UI languages.
        let preferences = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? Locale.preferredLanguages
        return Self.resolveSystemLanguage(preferences)
    }
    public static func resolveSystemLanguage(_ preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: ["zh-Hans", "en"], forPreferences: preferences).first ?? "zh-Hans"
    }
    public var resolvedLocale: Locale { Locale(identifier: localization) }
    public static func applyToSystem(_ language: AppLanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: defaultsKey)
        if language == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages") }
    }
}

/// Choose the resource bundle explicitly: String(localized:locale:) uses its
/// locale for formatting, but does not select the language of the resource table.
public func L(_ value: String.LocalizationValue, locale: Locale = AppLanguage.current.resolvedLocale) -> String {
#if canImport(Darwin)
    let language = AppLanguage.resolveSystemLanguage([locale.identifier])
    let bundle = LocalizationBundles.values[language] ?? .main
    return String(localized: value, bundle: bundle, locale: locale)
#else
    return value.resolved
#endif
}

/// Label dynamic keys explicitly so interpolated literals retain placeholders.
public func L(key: String) -> String { L(String.LocalizationValue(key)) }

// Resource bundles are immutable; resolve the user's language on each call above.
private enum LocalizationBundles {
    static let values: [String: Bundle] = Dictionary(uniqueKeysWithValues:
        ["zh-Hans", "en"].compactMap { language in
            Bundle.main.url(forResource: language, withExtension: "lproj")
                .flatMap(Bundle.init(url:)).map { (language, $0) }
        })
}
