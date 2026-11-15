import Foundation
import WorkbenchCore

/// Round 20: pins for the L()/AppLanguage resolution chain, created during the
/// rejected lean-chain exploration (v2 — reverted: Mac in-context screening
/// showed no separation). They pin the invariants any future optimization of
/// this chain must preserve, in CI on both platforms (the .app-based
/// scripts/check-localization-runtime.sh cannot run on the measurement mini —
/// bare-swiftc and relocated binaries are SIGKILLed there, documented in
/// WORKSPACE-DESIGN.md — so WorkbenchChecks is the enforceable carrier).
///
/// `Bundle.preferredLocalizations` legitimately diverges per platform, so the
/// resolution semantics are pinned per platform (round-17 precedent for
/// platform-conditional legacy behavior):
/// - Darwin (where the product's L() actually resolves locales): canonical
///   identifiers resolve to themselves — the exact-match premise any
///   "skip the second ICU resolve" shortcut relies on — and region-mapped
///   preferences fall back to the supported pair.
/// - Linux corelibs (measured): preferences are IGNORED and the first
///   supported localization is always returned. The product never depends on
///   this — the non-Darwin L() path returns `value.resolved` without ever
///   touching the locale chain — so the pin only freezes the legacy behavior
///   against silent drift.
func checkLocalizationResolutionChain() {
#if canImport(Darwin)
    precondition(AppLanguage.resolveSystemLanguage(["zh-Hans"]) == "zh-Hans",
                 "canonical zh-Hans resolves to itself")
    precondition(AppLanguage.resolveSystemLanguage(["en"]) == "en",
                 "canonical en resolves to itself")
    precondition(AppLanguage.resolveSystemLanguage(["en-GB", "zh-Hans"]) == "en",
                 "region-mapped preference falls back to en")
    precondition(AppLanguage.resolveSystemLanguage(["zh-Hans-CN", "en"]) == "zh-Hans",
                 "region-mapped preference falls back to zh-Hans")
    // Equivalence premise of the rejected CFPreferencesCopyValue substitution:
    // the single-key global-domain read agrees with the whole-domain read, so
    // a retry does not have to re-derive it.
    let viaDomain = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
    let viaKey = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                        kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
    precondition(viaDomain == viaKey, "global AppleLanguages reads must agree")
#else
    // Measured corelibs behavior (probe archived in round-20/checks/): every
    // preference list resolves to the first supported localization.
    for preferences in [["zh-Hans"], ["en"], ["en-GB", "zh-Hans"], ["zh-Hans-CN", "en"], ["fr"], []] {
        precondition(AppLanguage.resolveSystemLanguage(preferences) == "zh-Hans",
                     "corelibs ignores preferences and returns the first localization: \(preferences)")
    }
#endif
    // Platform-neutral: the derived locale for both fixed languages.
    precondition(AppLanguage.zhHans.resolvedLocale == Locale(identifier: "zh-Hans"),
                 "resolved locale equals the derived locale (zh-Hans)")
    precondition(AppLanguage.en.resolvedLocale == Locale(identifier: "en"),
                 "resolved locale equals the derived locale (en)")
    print("PASS: localization resolution chain — per-platform resolution semantics, locale derivation, global-read agreement (Darwin)")
}
