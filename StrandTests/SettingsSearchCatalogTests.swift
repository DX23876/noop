import XCTest
@testable import Strand

/// The Settings search index is hand-written, so the one thing that can silently rot is coverage: a
/// section added to `SettingsView` without a catalog row would still render, but would be unfindable
/// by search — and, worse, a *typo'd* id would make an existing section vanish whenever anyone types.
/// These tests pin completeness and a few real queries a person would actually use.
final class SettingsSearchCatalogTests: XCTestCase {

    func testEverySectionHasExactlyOneCatalogEntry() {
        for id in SettingsSectionID.allCases {
            let matches = SettingsSearchCatalog.entries.filter { $0.id == id }
            XCTAssertEqual(matches.count, 1,
                           "\(id.rawValue) needs exactly one catalog entry, found \(matches.count)")
        }
        XCTAssertEqual(SettingsSearchCatalog.entries.count, SettingsSectionID.allCases.count,
                       "the catalog carries an entry for an id that no longer exists")
    }

    func testEveryEntryCarriesSearchableText() {
        for entry in SettingsSearchCatalog.entries {
            let terms = entry.searchTerms.filter { !$0.isEmpty }
            XCTAssertFalse(terms.isEmpty, "\(entry.id.rawValue) has no searchable text at all")
            // Title-only entries are the trap this catches: the title is usually the ONE word a
            // person does not type, because they are searching for what is inside the section.
            XCTAssertFalse(entry.keywords.isEmpty, "\(entry.id.rawValue) has no keywords")
        }
    }

    func testAnEmptyQueryKeepsEverySection() {
        XCTAssertEqual(SettingsSearchCatalog.matching("").count, SettingsSectionID.allCases.count)
        for id in SettingsSectionID.allCases {
            XCTAssertTrue(SettingsSearchCatalog.section(id, matches: ""))
        }
    }

    /// The queries in the plan's own acceptance list, plus the ones that motivated the keywords.
    func testRealQueriesReachTheirSection() {
        XCTAssertTrue(SettingsSearchCatalog.section(.strap, matches: "live activity"))
        XCTAssertTrue(SettingsSearchCatalog.section(.strap, matches: "bluetooth"))
        XCTAssertTrue(SettingsSearchCatalog.section(.appearance, matches: "dark mode"))
        XCTAssertTrue(SettingsSearchCatalog.section(.appearance, matches: "language"))
        XCTAssertTrue(SettingsSearchCatalog.section(.backup, matches: "restore"))
        XCTAssertTrue(SettingsSearchCatalog.section(.experimentalWhoop5, matches: "ecg"))
        XCTAssertTrue(SettingsSearchCatalog.section(.features, matches: "hydration"))
    }

    func testAQueryNarrowsRatherThanReturningTheWholeScreen() {
        // Power saving moved out of Settings into its own screen (upstream #1431), so "battery" is no
        // longer a Settings query at all — the narrowing property is pinned on a query that still is one.
        let hits = SettingsSearchCatalog.matching("bluetooth")
        XCTAssertTrue(hits.contains { $0.id == .strap })
        XCTAssertLessThan(hits.count, SettingsSectionID.allCases.count,
                          "a specific query that keeps every section is not a filter")
    }

    func testNonsenseMatchesNothing() {
        XCTAssertTrue(SettingsSearchCatalog.matching("qwertyuiop").isEmpty)
    }
}
