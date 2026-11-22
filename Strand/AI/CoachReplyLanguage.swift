import Foundation
import StrandCore

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
        // No bundle fallback here. `Bundle.main` is the very thing that cannot answer on this
        // platform, so reading it would look like a resolution and only ever yield English. A host
        // that has not named a language is told so in plain English instead.
        return CoreLocalization.language.map { resolve(preferredLocalizations: [$0]) } ?? .english
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
        // One line, because there is nothing to decide: the OS tag's language subtag already names
        // these, and what they are CALLED comes from the catalogue.
        case "de", "es", "fr", "it", "pl", "ru": return named(language)
        // Portuguese only as European Portuguese. Brazilian is a different language to write in and
        // the app does not have it, so it falls to English rather than being answered in the wrong one.
        case "pt": return parts.dropFirst().first == "pt" ? named("pt-PT") : .english
        case "zh":
            let subtags = Set(parts.dropFirst())
            if subtags.contains("hant") || !subtags.isDisjoint(with: ["tw", "hk", "mo"]) {
                return named("zh-Hant")
            }
            if subtags.contains("hans") || subtags.isEmpty
                || !subtags.isDisjoint(with: ["cn", "sg"]) {
                return named("zh-Hans")
            }
            return .english
        default:
            return .english
        }
    }

    /// The offered language the catalogue spells this way, named as the catalogue names it.
    ///
    /// The switch above decides WHICH language an OS tag means, which is Apple's script and region
    /// rules and belongs here; it no longer decides what that language is called, which was a second
    /// list of names beside the core's and drifted from it (Polish was in one and not the other).
    /// A code with no entry can only mean the two have come apart, which
    /// `CoachLanguagePromptTests` and `Tools/test_coach_reply_language_handover.py` both fail on.
    private static func named(_ appleCatalogCode: String) -> CoachReplyLanguage {
        guard let language = AppLanguageCatalog.language(appleCatalogCode: appleCatalogCode) else {
            return .english
        }
        return CoachReplyLanguage(identifier: appleCatalogCode, englishName: language.englishName)
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
