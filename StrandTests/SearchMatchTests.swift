import XCTest
@testable import Strand

/// `SearchMatch` is the one matcher behind the More index and the Settings filter. These pin the four
/// rules that decide whether a filter feels broken to the person typing: folding (case + diacritics),
/// AND across query words, substring rather than prefix, and "empty query means no filter".
final class SearchMatchTests: XCTestCase {

    func testEmptyAndWhitespaceQueriesMatchEverything() {
        XCTAssertTrue(SearchMatch.matches(query: "", in: ["Strap"]))
        XCTAssertTrue(SearchMatch.matches(query: "   ", in: ["Strap"]))
        XCTAssertTrue(SearchMatch.matches(query: "\n\t", in: ["Strap"]))
        // …and the caller's "am I searching?" check must agree, or the screen filters to nothing
        // while showing an empty field.
        XCTAssertTrue(SearchMatch.tokens("   ").isEmpty)
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(SearchMatch.matches(query: "hrv", in: ["HRV window"]))
        XCTAssertTrue(SearchMatch.matches(query: "HRV", in: ["hrv window"]))
    }

    func testMatchingIgnoresDiacritics() {
        // The reason this matters: the app ships German, French and Spanish, and nobody reaches for
        // the umlaut key mid-filter.
        XCTAssertTrue(SearchMatch.matches(query: "warmemessung", in: ["Wärmemessung"]))
        XCTAssertTrue(SearchMatch.matches(query: "Wärme", in: ["warmemessung"]))
        XCTAssertTrue(SearchMatch.matches(query: "batterie", in: ["Batteriestand"]))
    }

    func testEveryQueryWordMustLandSomewhere() {
        let haystack = ["Strap", "live activity", "lock screen"]
        // Words may come from DIFFERENT haystack entries — a title plus a keyword.
        XCTAssertTrue(SearchMatch.matches(query: "strap activity", in: haystack))
        // Adding a word narrows: one unmatched word rejects the whole entry.
        XCTAssertFalse(SearchMatch.matches(query: "strap bicycle", in: haystack))
    }

    func testSubstringNotPrefix() {
        XCTAssertTrue(SearchMatch.matches(query: "cover", in: ["Recovery"]))
        XCTAssertTrue(SearchMatch.matches(query: "board", in: ["Dashboard"]))
    }

    func testNoMatchIsReportedAsNoMatch() {
        // The matcher is deliberately not fuzzy: a typo must fail rather than land somewhere
        // plausible-but-wrong, which is what makes an unranked result list trustworthy.
        XCTAssertFalse(SearchMatch.matches(query: "recovry", in: ["Recovery"]))
        XCTAssertFalse(SearchMatch.matches(query: "zzz", in: ["Recovery", "Strap"]))
    }
}
