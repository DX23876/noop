import Foundation

/// The languages the app offers, declared once for every platform and every reader.
///
/// There were three readers of this one fact and no authority over them: the Apple picker
/// (`AppLanguage`), the Android picker (`com.noop.ui.AppLanguage`) and the coach's reply language
/// (`CoachReplyLanguage`). All three were hand-maintained lists, and by 2026-11-22 all three
/// disagreed. Russian is translated on Android down to the core's own table and the Android picker
/// did not offer it. Polish is offered by both pickers and the coach had no case for it, so a Polish
/// wearer was promised Polish by the app and answered in English by the coach. Traditional Chinese is
/// offered on Apple and has no Android translation at all. Nothing failed anywhere, because nothing
/// compared them.
///
/// So this is the list, and the readers are held to it: `Tools/gen_app_languages.py` GENERATES the
/// Android enum from it, and tests assert the Apple picker and the coach cover it. The one thing this
/// file does not decide is which languages a given platform has a translated UI for — that is read
/// from the tree by the generator, so a language becomes available on Android the moment its
/// `values-…` strings exist and not a release later.
public enum AppLanguageCatalog {

    /// One offered language. `tag` is what is stored, what the OS is asked for, and what the coach
    /// resolves, so it is the identity; everything else hangs off it.
    public struct Language: Equatable, Sendable {
        /// The BCP-47 tag, as Apple's `AppleLanguages` and Android's `Locale.forLanguageTag` take it.
        public let tag: String
        /// Shown in the picker. An autonym on purpose, so the list stays readable while changing away
        /// from a language you cannot read.
        public let autonym: String
        /// The language's name in English, for the instruction the coach gives the model and for the
        /// generated Kotlin case name.
        public let englishName: String
        /// How the Apple String Catalog spells this language, which is also the identifier the coach
        /// names to the model. Equal to `tag` for all but simplified Chinese, where the picker stores
        /// the generic `zh` and the catalogue holds `zh-Hans`.
        public let appleCatalogCode: String
        /// The Android resource qualifier holding this language's UI (`values-<qualifier>`), or nil for
        /// English, which lives in `values/`. Declared rather than derived from the tag because the two
        /// spellings differ: `pt-PT` is `pt-rPT`, and simplified Chinese is plain `zh`.
        public let androidQualifier: String?

        public init(tag: String, autonym: String, englishName: String,
                    appleCatalogCode: String? = nil, androidQualifier: String?) {
            self.tag = tag
            self.autonym = autonym
            self.englishName = englishName
            self.appleCatalogCode = appleCatalogCode ?? tag
            self.androidQualifier = androidQualifier
        }
    }

    /// Every language the app offers, in the order a picker shows them: English first, then the rest as
    /// they were added. "Follow the phone" is not in here — it is an affordance, not a language.
    public static let offered: [Language] = [
        .init(tag: "en", autonym: "English", englishName: "English", androidQualifier: nil),
        .init(tag: "de", autonym: "Deutsch", englishName: "German", androidQualifier: "de"),
        .init(tag: "es", autonym: "Español", englishName: "Spanish", androidQualifier: "es"),
        .init(tag: "fr", autonym: "Français", englishName: "French", androidQualifier: "fr"),
        .init(tag: "it", autonym: "Italiano", englishName: "Italian", androidQualifier: "it"),
        .init(tag: "pt-PT", autonym: "Português", englishName: "Portuguese (Portugal)",
              androidQualifier: "pt-rPT"),
        .init(tag: "pl", autonym: "Polski", englishName: "Polish", androidQualifier: "pl"),
        .init(tag: "ru", autonym: "Русский", englishName: "Russian", androidQualifier: "ru"),
        .init(tag: "zh", autonym: "简体中文", englishName: "Chinese (Simplified)",
              appleCatalogCode: "zh-Hans", androidQualifier: "zh"),
        // `b+zh+Hant`, not `zh-rTW`: the region form would match Taiwan only, leaving Hong Kong and
        // Macau on the simplified strings, which is the fallback a reader of `zh-rTW` would not expect.
        // Apple's own resolver sends tw, hk and mo to Hant, and this keeps Android doing the same.
        .init(tag: "zh-Hant", autonym: "繁體中文", englishName: "Chinese (Traditional)",
              androidQualifier: "b+zh+Hant"),
    ]

    /// The offered language with this exact tag, or nil. Not a fuzzy match: an OS tag like `de-DE` or
    /// `zh-Hans-CN` is resolved by `CoachReplyLanguage`, which knows the script and region rules.
    public static func language(tag: String) -> Language? {
        offered.first { $0.tag == tag }
    }

    /// The offered language the Apple String Catalog spells this way, or nil. This is the key the
    /// coach's reply language joins on, so that the English name a wearer's model is told lives here
    /// and not in a second list beside it.
    public static func language(appleCatalogCode code: String) -> Language? {
        offered.first { $0.appleCatalogCode == code }
    }
}
