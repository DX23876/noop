import Foundation
import XCTest
@testable import NoopCore

/// The Android translation of text the shared code writes: the key must be the one Apple's String Catalog uses, and
/// the values must land where the translation puts them.
final class CoreLocalizationTests: XCTestCase {
    override func tearDown() {
        CoreLocalization.load(nil, language: nil)
        super.tearDown()
    }

    func testKeysMatchTheAppleCatalogForms() {
        let done = 2, total = 3
        let counted: AndroidLocalizedString = "\(done) of \(total) done"
        XCTAssertEqual(counted.key, "%lld of %lld done")
        let name = "Run"
        let named: AndroidLocalizedString = "“\(name)” measures the same kind of thing."
        XCTAssertEqual(named.key, "“%@” measures the same kind of thing.")
        let percent: AndroidLocalizedString = "Minutes at 40 to 80 % of your heart-rate reserve"
        XCTAssertEqual(percent.key, "Minutes at 40 to 80 % of your heart-rate reserve", "a literal keeps its % sign")
        let mixed: AndroidLocalizedString = "\(done) at 80 %"
        XCTAssertEqual(mixed.key, "%lld at 80 %%", "beside a value the % sign is escaped, as Apple does")
    }

    func testTranslationsFillValuesInOrderAndByPosition() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("l10n-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode([
            "%lld of %lld done": "%1$lld von %2$lld erledigt",
            "Week %lld/%lld on course": "%2$lld Ziele, %1$lld auf Kurs",
            "Needs %@ h a night from here": "Ab jetzt %@ h pro Nacht nötig",
            "Steps": "Schritte",
        ]).write(to: file)
        CoreLocalization.load(file, language: "de")
        let done = 2, total = 3
        XCTAssertEqual(AndroidLocalizedString("\(done) of \(total) done").resolved, "2 von 3 erledigt")
        XCTAssertEqual(AndroidLocalizedString("Week \(done)/\(total) on course").resolved, "3 Ziele, 2 auf Kurs")
        XCTAssertEqual(AndroidLocalizedString("Needs \("7.5") h a night from here").resolved, "Ab jetzt 7.5 h pro Nacht nötig")
        XCTAssertEqual(AndroidLocalizedString("Steps").resolved, "Schritte")
        XCTAssertEqual(AndroidLocalizedString("Not in the table \(done)").resolved, "Not in the table 2")
        CoreLocalization.load(nil, language: nil)
        XCTAssertEqual(AndroidLocalizedString("\(done) of \(total) done").resolved, "2 of 3 done")
    }

    /// The language is a fact the host supplies, and the coach's reply language reads it from here.
    ///
    /// It has to be held beside the table rather than derived from it: the table is keyed by English
    /// source text and carries nothing that says which language it holds, and on Android there is no
    /// bundle to ask. That gap is what let the coach answer a Spanish wearer in English while every
    /// line of UI around it was Spanish (reported 2026-11-22). English ships no table at all, so
    /// "no table" and "nobody told us" have to stay distinguishable.
    func testTheHostsLanguageIsKeptBesideTheTable() throws {
        XCTAssertNil(CoreLocalization.language, "nothing was named yet")
        CoreLocalization.load(nil, language: "en")
        XCTAssertEqual(CoreLocalization.language, "en", "English has no table and is still a named language")
        CoreLocalization.load(nil, language: "")
        XCTAssertNil(CoreLocalization.language, "an empty tag is not a language")

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("l10n-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(["Steps": "Pasos"]).write(to: file)
        CoreLocalization.load(file, language: "es")
        XCTAssertEqual(CoreLocalization.language, "es")
        XCTAssertEqual(AndroidLocalizedString("Steps").resolved, "Pasos", "the table and the tag are one call")
        // What the coach then asks the model for. The resolver is shared with Apple, so this pins the
        // handover rather than the mapping, which `CoachLanguagePromptTests` covers language by language.
        XCTAssertEqual(
            CoachReplyLanguage.resolve(preferredLocalizations: [CoreLocalization.language ?? "en"]).englishName,
            "Spanish")
    }
}
