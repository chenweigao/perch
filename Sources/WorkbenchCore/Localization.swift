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
#if canImport(Darwin)
        // Single-key read of the same global-domain value; every call still
        // reads it live, but without materializing the entire global
        // preferences dictionary and bridging it to [String: Any] first —
        // that per-call materialization dominated L()'s default-argument
        // chain (round-20 attribution: the chain was ~29% of the narrative
        // projection stage at bench scale, tryCast alone 16.45%).
        if let value = CFPreferencesCopyValue("AppleLanguages" as CFString,
                                              kCFPreferencesAnyApplication,
                                              kCFPreferencesCurrentUser,
                                              kCFPreferencesAnyHost) as? [String] {
            return Self.resolveSystemLanguage(value)
        }
        return Self.resolveSystemLanguage(Locale.preferredLanguages)
#else
        let preferences = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String] ?? Locale.preferredLanguages
        return Self.resolveSystemLanguage(preferences)
#endif
    }
    public static func resolveSystemLanguage(_ preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: ["zh-Hans", "en"], forPreferences: preferences).first ?? "zh-Hans"
    }
    /// The two supported UI languages have fixed locales; deriving one per
    /// call re-parses the identifier for the same immutable value. Pure
    /// table of deterministic derivations — no state, no invalidation.
    private static let resolvedLocales: [String: Locale] = [
        "zh-Hans": Locale(identifier: "zh-Hans"),
        "en": Locale(identifier: "en"),
    ]
    public var resolvedLocale: Locale {
        let language = localization
        return Self.resolvedLocales[language] ?? Locale(identifier: language)
    }
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
    // A canonical identifier is an exact preference match against itself in
    // preferredLocalizations(from: ["zh-Hans", "en"]), so it resolves to
    // itself — skip the second ICU parse for it (pinned by the identity
    // preconditions in LocalizationChecks). Anything else resolves as before.
    let language: String
    switch locale.identifier {
    case "zh-Hans", "en": language = locale.identifier
    default: language = AppLanguage.resolveSystemLanguage([locale.identifier])
    }
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
