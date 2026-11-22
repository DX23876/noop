import Foundation
import StrandCore

/// The language NOOP uses for app-owned copy. Region-specific measurement and clock preferences remain
/// separate: this changes words, not the user's unit-system choice or time zone.
///
/// Apple chooses a bundle's localization once, when the process launches. `apply(_:)` therefore writes
/// the standard `AppleLanguages` override and Settings tells the user to reopen NOOP. Applying only a
/// SwiftUI `locale` live would be incorrect: `Text` would switch immediately while `String(localized:)`
/// messages, notifications, and strings owned by `StrandDesign.module` stayed in the old language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english = "en"
    case german = "de"
    case spanish = "es"
    case french = "fr"
    case italian = "it"
    case portuguese = "pt-PT"
    case polish = "pl"
    case russian = "ru"
    /// Generic Chinese is retained for existing installs and resolves to the Simplified catalog.
    case chinese = "zh"
    case traditionalChinese = "zh-Hant"

    static let storageKey = "noop.appLanguage"

    var id: String { rawValue }

    /// Language names are autonyms on purpose, so the picker remains understandable while changing from
    /// an unfamiliar language. The system choice is localized at its call site, so it has none here.
    ///
    /// Read from `AppLanguageCatalog` rather than listed again: the names were a second copy of the
    /// core's list, kept in step by a test instead of by there being one of them, and the Android
    /// picker showed a third spelling of Chinese for exactly that reason (2026-11-22). The cases
    /// themselves stay, because their raw values are what is persisted and what the compiler checks
    /// every `switch` in the app against.
    var autonym: String {
        AppLanguageCatalog.language(tag: rawValue)?.autonym ?? ""
    }

    static func resolve(_ raw: String) -> AppLanguage {
        AppLanguage(rawValue: raw) ?? .system
    }

    /// Persist the bundle-language override. Foundation observes it on the next process launch.
    static func apply(_ raw: String, defaults: UserDefaults = .standard) {
        let language = resolve(raw)
        if language == .system {
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    /// Locale used by SwiftUI format styles for the language that the currently-running bundles chose.
    /// This deliberately follows `Bundle`, not the pending picker value, so changing the setting cannot
    /// produce a half-new/half-old UI before the requested reopen.
    static var activeLocale: Locale {
        let bundleLanguage = Bundle.main.preferredLocalizations.first ?? "en"
        let language = bundleLanguage.split(separator: "-").first.map(String.init) ?? bundleLanguage
        // Preserve the device's regional conventions (24-hour clock, date order, decimal separator) while
        // taking month/weekday words from the app language: English on a German device becomes `en_DE`.
        if let region = Locale.autoupdatingCurrent.region?.identifier {
            return Locale(identifier: "\(language)_\(region)")
        }
        return Locale(identifier: language)
    }
}
