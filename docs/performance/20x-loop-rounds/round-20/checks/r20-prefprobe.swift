import Foundation
for prefs in [["zh-Hans"], ["en"], ["en-GB", "zh-Hans"], ["zh-Hans-CN", "en"], ["fr"], []] {
    let r = Bundle.preferredLocalizations(from: ["zh-Hans", "en"], forPreferences: prefs)
    print("prefs=\(prefs) -> \(r) first=\(r.first ?? "nil")")
}
