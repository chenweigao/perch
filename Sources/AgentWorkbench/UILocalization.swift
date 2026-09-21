import SwiftUI
import WorkbenchCore

/// Dynamic labels must depend on the same environment as SwiftUI literal labels.
/// Reading UserDefaults during body evaluation can see the previous selection.
@propertyWrapper struct UILocalization: DynamicProperty {
    @Environment(\.locale) private var locale
    var wrappedValue: LocalizedUIStrings { LocalizedUIStrings(locale: locale) }
}
struct LocalizedUIStrings {
    let locale: Locale
    func callAsFunction(_ value: String.LocalizationValue) -> String {
        WorkbenchCore.L(value, locale: locale)
    }
    func callAsFunction(key: String) -> String {
        WorkbenchCore.L(String.LocalizationValue(key), locale: locale)
    }
}
