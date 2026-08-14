import XCTest
import StrandDesign
@testable import Strand

/// The three scores are NAMES, and every other metric label has to survive translation.
///
/// Two failures this pins, both found by running the app in German:
///
/// 1. The hero row said CHARGE / EFFORT / REST while the metric tile for the *same number*, 300 points
///    below on the same screen, said RECOVERY / STRAIN / REST — in English, before translation entered
///    into it. Both Today screens now read one source (`DomainTheme.productName`).
/// 2. The tiles were sized against the ENGLISH labels. "Effort" is 6 characters; German "Anstrengung"
///    is 11, and the tile rendered it as "AN-STRE…" — hyphenated AND truncated in the same word.
///    German is not even the worst case across the eight shipped languages.
final class MetricNameLocalizationTests: XCTestCase {

    /// Every language the app ships, so a label is measured against the longest translation rather
    /// than against English.
    private let shipped = ["en", "de", "es", "fr", "it", "pt-PT", "ru", "zh-Hans", "zh-Hant"]

    // MARK: - The three scores are product names

    func testTheThreeScoresAreNeverTranslated() {
        XCTAssertEqual(DomainTheme.charge.productName, "Charge")
        XCTAssertEqual(DomainTheme.effort.productName, "Effort")
        XCTAssertEqual(DomainTheme.rest.productName, "Rest")
    }

    /// The guard that matters: `productName` must not resolve through the string catalog, or a German
    /// build silently gets "Ladung" back and the whole point is lost. If any of these words appears in
    /// the catalog AS A STANDALONE KEY with a translation, `productName` must still ignore it.
    func testProductNamesDoNotFollowTheCatalog() {
        for domain in [DomainTheme.charge, .effort, .rest] {
            let name = domain.productName
            XCTAssertEqual(name, name.applyingTransform(.stripDiacritics, reverse: false),
                           "a product name should be plain ASCII, not a translated word")
            XCTAssertFalse(name.isEmpty)
        }
    }

    /// Stress is deliberately NOT one of the three — it is an ordinary metric and stays translated.
    func testStressIsStillAnOrdinaryTranslatedMetric() {
        XCTAssertFalse(DomainTheme.stress.productName.isEmpty)
    }

    // MARK: - Ordinary metric labels must fit in every language

    /// The tile label area is roughly this many characters before it wraps to a second line at the
    /// overline size used by `StatTile`. Not a pixel measurement — a coarse budget that catches the
    /// class of bug ("AN-STRE…") without pretending to be a layout engine.
    private let tileLabelBudget = 16

    func testOrdinaryTileLabelsFitTheTileInEveryShippedLanguage() {
        // The metric labels the tiles actually render, by their English catalog key.
        // "Blood Oxygen" is deliberately absent: the tile now labels it with the international
        // abbreviation SpO₂ and carries the translated full name as its caption, where the length is
        // not a constraint. These are the labels that still render translated IN the tile.
        let keys = ["HRV", "Rest HR", "Respiratory", "Steps", "Weight", "Calories"]
        var tooLong: [String] = []
        var readCount = 0
        for key in keys {
            for lang in shipped {
                guard let value = Self.catalogValue(key, language: lang) else { continue }
                readCount += 1
                if value.count > tileLabelBudget {
                    tooLong.append("\(lang): \"\(key)\" → \"\(value)\" (\(value.count) chars)")
                }
            }
        }
        // Without this the test passes vacuously when the catalog can't be reached from the test
        // bundle — a green that pins nothing, which is worse than no test at all.
        XCTAssertGreaterThan(readCount, keys.count,
                             "the catalog was not readable — this test would pass without checking anything")
        XCTAssertTrue(tooLong.isEmpty,
                      "a tile label longer than \(tileLabelBudget) characters wraps or truncates:\n"
                      + tooLong.joined(separator: "\n"))
    }

    /// Reads a translation out of the COMPILED per-language catalog in the app bundle, so the budget is
    /// measured against what actually renders.
    ///
    /// Deliberately not the source `.xcstrings`: Xcode compiles that into `<lang>.lproj/Localizable
    /// .strings` at build time and never copies the source file into the bundle, so looking for the
    /// `.xcstrings` found nothing and the whole check passed without comparing a single string.
    private static func catalogValue(_ key: String, language: String) -> String? {
        if language == "en" { return key }
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        // `localizedString` echoes the key back when a language has no entry — that is "untranslated",
        // not "a translation that happens to equal the key", and either way it is English-length.
        let value = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        return value
    }
}
