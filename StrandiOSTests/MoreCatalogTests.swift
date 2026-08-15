#if os(iOS)
import XCTest
@testable import NOOP_Staging

/// The More tab's rows moved out of the view into `MoreCatalog` so the search could read them. That
/// makes two things worth pinning: the index must still contain every row it used to (a row dropped in
/// the move is a screen that becomes unreachable on iPhone), and the group titles are UserDefaults keys
/// on every existing installation, so they are not free to change.
final class MoreCatalogTests: XCTestCase {

    func testGroupTitlesAreTheKeysAlreadyPersistedOnDevice() {
        // `MoreSectionPrefs` stores the open/closed choice under these exact strings. Renaming or
        // translating one would silently reset that user's expanded groups.
        XCTAssertEqual(MoreCatalog.groups.map(\.title), ["Analysis", "Body", "Data", "App"])
        XCTAssertTrue(MoreSectionPrefs.defaultExpanded.isSubset(of: Set(MoreCatalog.groups.map(\.title))),
                      "a group seeded open by default is not in the catalog")
    }

    func testNoRouteAppearsTwice() {
        let routes = MoreCatalog.allEntries.map(\.route)
        XCTAssertEqual(Set(routes).count, routes.count, "two rows lead to the same screen")
    }

    func testTheIndexStillCarriesEveryRowItShipped() {
        // The list as it stood before the catalog extraction. A row leaving the index is a screen a
        // person can no longer reach from the iPhone, which is exactly the #805/#811 regression that
        // dropped Alarms once already.
        let expected: Set<MoreDestination> = [
            .insightsHub, .intelligence, .goalJourney, .insights, .explore, .compare, .coachSettings,
            .live, .workouts, .health, .labBook, .stress, .breathe, .intervals, .rhythm,
            .fusedRecord, .appleHealth, .miBand, .dataSources, .backupSync, .shortcutsExport, .noopLimitations,
            .alarms, .automations, .testCentre, .siriShortcuts, .settings,
        ]
        XCTAssertEqual(Set(MoreCatalog.allEntries.map(\.route)), expected)
    }

    func testEveryRowCarriesKeywords() {
        for entry in MoreCatalog.allEntries {
            XCTAssertFalse(entry.keywords.isEmpty,
                           "\(String(describing: entry.route)) can only be found by its exact title")
        }
    }

    func testAnEmptyQueryReturnsTheWholeIndex() {
        XCTAssertEqual(MoreCatalog.matching("").count, MoreCatalog.allEntries.count)
    }

    /// The point of the keywords: the words people use are rarely the words on the row.
    ///
    /// This scheme runs its tests under `language: de` (`project.yml`), which is what makes these
    /// assertions worth having: they failed when the keywords were `LocalizedStringResource`, because
    /// "API key" resolved to its German translation and the query "api key" then matched nothing.
    /// Keywords are English aliases for that reason — the row's TITLE is the localized half.
    func testKeywordsReachRowsTheTitleWouldNot() {
        XCTAssertTrue(MoreCatalog.matching("blood pressure").contains { $0.route == .labBook })
        XCTAssertTrue(MoreCatalog.matching("healthkit").contains { $0.route == .appleHealth })
        XCTAssertTrue(MoreCatalog.matching("api key").contains { $0.route == .coachSettings })
        XCTAssertTrue(MoreCatalog.matching("whoop export").contains { $0.route == .dataSources })
    }

    func testTitleSearchStillWorksAndNarrows() {
        let hits = MoreCatalog.matching("workouts")
        XCTAssertTrue(hits.contains { $0.route == .workouts })
        XCTAssertLessThan(hits.count, MoreCatalog.allEntries.count)
    }

    func testNonsenseMatchesNothing() {
        XCTAssertTrue(MoreCatalog.matching("qwertyuiop").isEmpty)
    }
}
#endif
