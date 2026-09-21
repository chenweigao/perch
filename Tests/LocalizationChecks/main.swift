import Foundation

let defaults = UserDefaults.standard
let savedLanguage = defaults.object(forKey: AppLanguage.defaultsKey)
let savedAppleLanguages = defaults.object(forKey: "AppleLanguages")
defer {
    defaults.set(savedLanguage, forKey: AppLanguage.defaultsKey)
    defaults.set(savedAppleLanguages, forKey: "AppleLanguages")
}
// Exercise both resource lookup and interpolation while Foundation's initial
// preferred language differs from the in-app choice.
defaults.set(["zh-Hans"], forKey: "AppleLanguages")
for language in [AppLanguage.en, .zhHans, .en] {
    defaults.set(language.rawValue, forKey: AppLanguage.defaultsKey)
    let count = 3
    precondition(L("工作台") == (language == .en ? "Workspace" : "工作台"))
    precondition(L("\(count) 个 SSH") == (language == .en ? "3 SSH" : "3 个 SSH"))
    precondition(L("\(count) 秒后重连") == (language == .en ? "Reconnecting in 3 s" : "3 秒后重连"))
    precondition(L("About Perch") == (language == .en ? "About Perch" : "关于 Perch"))
    precondition(L(key: "运行中") == (language == .en ? "Running" : "运行中"))
    let title = "A 100% 项目"
    let confirmation = L("将从 Kimi 服务删除「\(title)」及其历史，无法撤销。只想收起时，请使用归档。")
    precondition(confirmation.contains(title))
    precondition(confirmation.hasPrefix(language == .en ? "This deletes" : "将从 Kimi"))
    print("PASS: \(language.rawValue) literals, dynamic keys, integer/string interpolation and round-trip switching")
}
precondition(AppLanguage.resolveSystemLanguage(["en-GB", "zh-Hans"]) == "en")
precondition(AppLanguage.resolveSystemLanguage(["zh-Hans-CN", "en"]) == "zh-Hans")
AppLanguage.applyToSystem(.system)
precondition(defaults.persistentDomain(forName: Bundle.main.bundleIdentifier!)?["AppleLanguages"] == nil)
print("PASS: system language selection and removal of the per-app override")
