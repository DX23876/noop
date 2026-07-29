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
        resolve(preferredLocalizations: Bundle.main.preferredLocalizations)
    }

    /// Pure resolver used by tests and by `current`. The supported set intentionally mirrors the
    /// Apple String Catalog in the ryanbr/noop upstream.
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
