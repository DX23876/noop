import XCTest
import StrandCore
@testable import Strand

/// The picker on this phone and the one list in the core say the same thing.
///
/// Three readers of one fact drifted unnoticed until 2026-11-22: this picker, the Android one, and the
/// coach's reply language. The Android enum is now generated from `AppLanguageCatalog`, the coach is
/// held to it in `CoachLanguagePromptTests`, and this is the Apple half. The enum itself stays
/// hand-written, because its raw values are persisted and its `switch` statements are what the
/// compiler checks; what it must not do is offer a different set of languages than the core declares.
final class AppLanguageCatalogTests: XCTestCase {

    /// Every language the catalogue offers, in its order, is what the picker lists after "follow the
    /// phone". Order included: the picker shows them in this sequence and a wearer learns where theirs
    /// sits, so a silent reordering on one platform is a difference worth failing on.
    func testThePickerOffersExactlyWhatTheCoreDeclares() {
        let picker = AppLanguage.allCases.filter { $0 != .system }.map(\.rawValue)
        XCTAssertEqual(picker, AppLanguageCatalog.offered.map(\.tag))
    }

    /// The picker reads its names from the catalogue now, so what is left to check is that every
    /// offered language HAS one. An empty autonym is a blank row a wearer cannot pick on purpose.
    func testEveryOfferedLanguageHasAName() {
        for language in AppLanguageCatalog.offered {
            XCTAssertFalse(language.autonym.isEmpty, "\(language.tag) would show as a blank row")
            XCTAssertFalse(language.englishName.isEmpty, "\(language.tag) has no name for the coach")
            XCTAssertEqual(AppLanguage(rawValue: language.tag)?.autonym, language.autonym,
                           "\(language.tag) is not reachable from the picker's own cases")
        }
    }

    /// "Follow the phone" is an affordance, not a language, so it has no entry and no autonym of its own.
    func testTheSystemChoiceIsNotALanguage() {
        XCTAssertNil(AppLanguageCatalog.language(tag: "system"))
        XCTAssertEqual(AppLanguage.system.autonym, "")
    }

    /// Every tag is one Foundation reads back unchanged, since it is stored, handed to
    /// `AppleLanguages`, and resolved by the coach. A tag the platform rewrites would break all three.
    func testEveryTagSurvivesTheRoundTripThroughFoundation() {
        for language in AppLanguageCatalog.offered {
            XCTAssertEqual(Locale(identifier: language.tag).identifier.replacingOccurrences(of: "_", with: "-"),
                           language.tag, "\(language.tag) is not the spelling Foundation keeps")
        }
    }
}
