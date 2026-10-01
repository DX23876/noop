#if os(iOS)
import XCTest
@testable import NOOP_Staging

/// The More tab's rows moved out of the view into `MoreCatalog` so the search could read them. That
/// makes two things worth pinning: every final destination must remain reachable or searchable, and the
/// compact root must keep the approved category order.
final class MoreCatalogTests: XCTestCase {

    func testCompactRootCategoryOrder() {
        XCTAssertEqual(MoreCatalog.groups.map(\.category),
                       [.analysis, .healthBody, .tools, .data, .app])
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
            .momentum, .insightsHub, .intelligence, .goalJourney, .insights, .explore, .compare, .coachSettings,
            .training, .live, .workouts, .strength, .cardio, .trainingLoad, .body, .energyPlan,
            .health, .labBook, .stress, .breathe, .intervals, .rhythm,
            .fusedRecord, .appleHealth, .miBand, .dataSources, .backupSync, .shortcutsExport, .noopLimitations,
            .alarms, .automations, .testCentre, .siriShortcuts, .powerSaving, .settings,
        ]
        XCTAssertEqual(Set(MoreCatalog.allEntries.map(\.route)), expected)
    }

    func testRootKeepsSettingsAndTestCentreOneTapAway() {
        XCTAssertEqual(MoreCatalog.rootEntries.map(\.route), [.settings, .testCentre])
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
