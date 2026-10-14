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

    func testEverySectionBelongsToExactlyOneSettingsPage() {
        let mapped = SettingsPage.allCases.flatMap(\.sectionIDs)
        XCTAssertEqual(mapped.count, SettingsSectionID.allCases.count)
        XCTAssertEqual(Set(mapped), Set(SettingsSectionID.allCases))
        for id in SettingsSectionID.allCases {
            XCTAssertEqual(mapped.filter { $0 == id }.count, 1,
                           "\(id.rawValue) must appear on exactly one Settings page")
        }
    }

    func testSettingsHubListsEveryPageExactlyOnceInStableOrder() {
        XCTAssertEqual(SettingsHubLayout.allPages, [
            .profile, .goals,
            .strap, .batteryRecording, .strapActions,
            .training, .todayTrends, .notifications, .coach, .siri,
            .languageUnits, .appearance,
            .calculations, .dataBackup,
            .help, .lab, .about,
        ])
        XCTAssertEqual(Set(SettingsHubLayout.allPages), Set(SettingsPage.allCases))
    }

    /// The six pages that are complete screens of their own carry exactly one section each, so a search
    /// hit on them names the screen it opens and never a card that page does not draw.
    func testStandaloneScreensAreExactlyTheSixScreenPages() {
        let standalone = SettingsPage.allCases.filter(\.isStandaloneScreen)
        XCTAssertEqual(standalone, [.goals, .batteryRecording, .strapActions, .notifications, .coach, .siri])
        for page in standalone {
            XCTAssertEqual(page.sectionIDs.count, 1, "\(page.rawValue) is one screen, so one section")
        }
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
        XCTAssertTrue(SettingsSearchCatalog.section(.notifications, matches: "live activity"))
        XCTAssertTrue(SettingsSearchCatalog.section(.strap, matches: "bluetooth"))
        XCTAssertTrue(SettingsSearchCatalog.section(.design, matches: "dark mode"))
        XCTAssertTrue(SettingsSearchCatalog.section(.language, matches: "language"))
        XCTAssertTrue(SettingsSearchCatalog.section(.language, matches: "week start"))
        XCTAssertTrue(SettingsSearchCatalog.section(.backup, matches: "restore"))
        XCTAssertTrue(SettingsSearchCatalog.section(.labWhoop5, matches: "ecg"))
        XCTAssertTrue(SettingsSearchCatalog.section(.todayCards, matches: "hydration"))
        XCTAssertTrue(SettingsSearchCatalog.section(.training, matches: "rest timer"))
        XCTAssertTrue(SettingsSearchCatalog.section(.training, matches: "keep screen on"))
        XCTAssertTrue(SettingsSearchCatalog.section(.training, matches: "exercise media"))
        XCTAssertTrue(SettingsSearchCatalog.section(.batteryRecording, matches: "battery"))
        XCTAssertTrue(SettingsSearchCatalog.section(.heartRateSharing, matches: "zwift"))
        XCTAssertTrue(SettingsSearchCatalog.section(.calculation, matches: "day start"))
        XCTAssertTrue(SettingsSearchCatalog.section(.lab, matches: "ageless"))
        XCTAssertTrue(SettingsSearchCatalog.section(.coach, matches: "api key"))
    }

    func testAQueryNarrowsRatherThanReturningTheWholeScreen() {
        let hits = SettingsSearchCatalog.matching("bluetooth")
        XCTAssertTrue(hits.contains { $0.id == .strap })
        XCTAssertLessThan(hits.count, SettingsSectionID.allCases.count,
                          "a specific query that keeps every section is not a filter")
    }

    func testNonsenseMatchesNothing() {
        XCTAssertTrue(SettingsSearchCatalog.matching("qwertyuiop").isEmpty)
    }
}
