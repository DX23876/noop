#if os(iOS)
import XCTest
@testable import NOOP_Staging

/// The More tab's rows moved out of the view into `MoreCatalog` so the search could read them. That
/// makes two things worth pinning: every final destination must remain reachable or searchable, and the
/// compact root must keep the approved category order.
///
/// The 2026-10 reorganisation moved the settings-like screens (Coach, Apple Health and imports, backup,
/// Automations, Power saving, Siri, Test Centre) into Settings pages. The More search still reaches them
/// through `SettingsSearchCatalog`, which is what the keyword test below asserts for those words.
final class MoreCatalogTests: XCTestCase {

    func testCompactRootCategoryOrder() {
        XCTAssertEqual(MoreCatalog.groups.map(\.category),
                       [.analysis, .healthBody, .tools])
    }

    func testNoRouteAppearsTwice() {
        let routes = MoreCatalog.allEntries.map(\.route)
        XCTAssertEqual(Set(routes).count, routes.count, "two rows lead to the same screen")
    }

    func testTheIndexStillCarriesEveryRowItShipped() {
        // The list as it stands after the 2026-10 reorganisation. A row leaving the index is a screen a
        // person can no longer reach from the iPhone, which is exactly the #805/#811 regression that
        // dropped Alarms once already. A screen moving into Settings belongs in the keyword test below.
        let expected: Set<MoreDestination> = [
            .momentum, .insightsHub, .intelligence, .goalJourney, .insights, .explore, .compare, .fusedRecord,
            .training, .body, .energyPlan, .health, .ageless, .rhythmAge, .labBook, .stress, .rhythm, .ecg,
            .live, .breathe, .intervals,
            .settings, .alarms,
            .workouts, .strength, .cardio, .trainingLoad, .miBand,
        ]
        XCTAssertEqual(Set(MoreCatalog.allEntries.map(\.route)), expected)
    }

    func testRootKeepsSettingsAndAlarmsOneTapAway() {
        XCTAssertEqual(MoreCatalog.rootEntries.map(\.route), [.settings, .alarms])
    }

    func testEveryRowCarriesKeywords() {
        for entry in MoreCatalog.allEntries {
            XCTAssertFalse(entry.keywords.isEmpty,
                           "\(String(describing: entry.route)) can only be found by its exact title")
        }
    }

    func testAnEmptyQueryReturnsTheWholeIndex() {
        // Lab rows (AgeLess, Daily rhythm) are listed only while their switch is on, in search as well.
        XCTAssertEqual(MoreCatalog.matching("").count, MoreCatalog.allEntries.filter(\.isAvailable).count)
    }

    /// The point of the keywords: the words people use are rarely the words on the row.
    ///
    /// This scheme runs its tests under `language: de` (`project.yml`), which is what makes these
    /// assertions worth having: they failed when the keywords were `LocalizedStringResource`, because
    /// "API key" resolved to its German translation and the query "api key" then matched nothing.
    /// Keywords are English aliases for that reason — the row's TITLE is the localized half.
    func testKeywordsReachRowsTheTitleWouldNot() {
        XCTAssertTrue(MoreCatalog.matching("blood pressure").contains { $0.route == .labBook })
        // Screens that moved into Settings are found through its index, shown in the same result list.
        XCTAssertTrue(SettingsSearchCatalog.matching("healthkit").contains { $0.id == .dataConnections })
        XCTAssertTrue(SettingsSearchCatalog.matching("api key").contains { $0.id == .coach })
        XCTAssertTrue(SettingsSearchCatalog.matching("whoop export").contains { $0.id == .dataConnections })
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
