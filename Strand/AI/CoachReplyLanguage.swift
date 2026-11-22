import Foundation

/// The language used for every user-visible Coach completion.
///
/// `Locale.current` describes formatting conventions and can disagree with the language selected for
/// this app. `Bundle.preferredLocalizations` is already resolved by the OS against the localizations the
/// app actually ships, so an unsupported phone language naturally falls back to English and an
/// app-specific language choice wins.
struct CoachReplyLanguage: Equatable, Sendable {
    let identifier: String
    let englishName: String

    static let english = CoachReplyLanguage(identifier: "en", englishName: "English")

    static var current: CoachReplyLanguage {
        #if os(Android)
        // On Android the app's language is not something this process can read: `Bundle.main` describes
        // an executable with no localizations in it, so asking it answered English for every wearer and
        // the coach told a Spanish wearer with a Spanish app, in English, that English was the app's
        // language (reported 2026-11-22). The host names it in the same call that installs the core's
        // translation table, so the text the core writes and the language it asks the model for are one
        // fact resolved in one place. A host that never named it still falls back to the bundle.
        return resolve(preferredLocalizations: CoreLocalization.language.map { [$0] }
            ?? Bundle.main.preferredLocalizations)
        #else
        return resolve(preferredLocalizations: Bundle.main.preferredLocalizations)
        #endif
    }

    /// Pure resolver used by tests and by `current`. The supported set is the app's OWN language list
    /// (`AppLanguage`), which `CoachLanguagePromptTests` holds it to. It used to be described as
    /// mirroring the upstream String Catalog, and drifted: this fork offers Polish in Settings while
    /// the coach had no case for it, so a Polish wearer was promised Polish by the app and answered in
    /// English by the coach, on both phones.
    static func resolve(preferredLocalizations: [String]) -> CoachReplyLanguage {
        guard let raw = preferredLocalizations.first else { return .english }
        let tag = raw.replacingOccurrences(of: "_", with: "-")
        let parts = tag.split(separator: "-").map { String($0).lowercased() }
        guard let language = parts.first else { return .english }

        switch language {
        case "en": return .english
        case "de": return CoachReplyLanguage(identifier: "de", englishName: "German")
        case "es": return CoachReplyLanguage(identifier: "es", englishName: "Spanish")
        case "fr": return CoachReplyLanguage(identifier: "fr", englishName: "French")
        case "it": return CoachReplyLanguage(identifier: "it", englishName: "Italian")
        case "pl": return CoachReplyLanguage(identifier: "pl", englishName: "Polish")
        case "ru": return CoachReplyLanguage(identifier: "ru", englishName: "Russian")
        case "pt":
            return parts.dropFirst().first == "pt"
                ? CoachReplyLanguage(identifier: "pt-PT", englishName: "Portuguese (Portugal)")
                : .english
        case "zh":
            let subtags = Set(parts.dropFirst())
            if subtags.contains("hant") || !subtags.isDisjoint(with: ["tw", "hk", "mo"]) {
                return CoachReplyLanguage(identifier: "zh-Hant", englishName: "Chinese (Traditional)")
            }
            if subtags.contains("hans") || subtags.isEmpty
                || !subtags.isDisjoint(with: ["cn", "sg"]) {
                return CoachReplyLanguage(identifier: "zh-Hans", englishName: "Chinese (Simplified)")
            }
            return .english
        default:
            return .english
        }
    }

    /// Kept in English because this is an instruction to the model, not UI text. It is deliberately
    /// strict: the selected app language wins over the language of the latest message or old history.
    var promptClause: String {
        """
        Always reply in \(englishName) (\(identifier)), the app's active UI language. Do not switch \
        languages because the user writes in another language or because earlier messages use another \
        language. If the user explicitly requests a translation or quotation, only that requested \
        passage may use the requested language; keep the explanation in \(englishName).
        """
    }
}
