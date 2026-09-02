import XCTest
import WhoopStore
@testable import Strand

/// Pins the two reference-matched dashboards' layout contract and the one section rule that is easy to
/// get wrong by eye.
///
/// `TrendsDashboardView` and `OverviewDashboardView` shipped with no test coverage at all, and the
/// layout each renders is decoded from two persisted strings by `DashboardLayoutPrefs`. The decode has
/// three modes that a reader cannot tell apart from the stored value alone — empty means "extras
/// hidden", the `__none__` sentinel means "nothing hidden", and an explicit list means itself — so an
/// off-by-one in any of them silently changes which sections a user sees.
final class DashboardLayoutSectionsTests: XCTestCase {

    // MARK: - Default order

    func testDefaultOrderLeadsWithEachDashboardsOwnReferenceBlocks() {
        // Trends opens on its reference blocks, Overview on its own — the extras trail both. Both lead
        // with Coach: Overview had no Coach surface at all beyond the header icon, which is not where
        // anyone looks for a recommendation.
        XCTAssertEqual(Array(DashboardLayoutSection.defaultOrder(for: "trends").prefix(5)),
                       [.coach, .hero, .trendsChart, .metricStrip, .activity])
        XCTAssertEqual(Array(DashboardLayoutSection.defaultOrder(for: "overview").prefix(4)),
                       [.coach, .overview, .focus, .health])

        // Every optional section is PLACED on both dashboards, and none is placed twice. Placement is
        // checked by identity rather than by counting `isExtra`: Momentum is still a
        // `DashboardExtraSection` case but is no longer flagged extra, because it now starts visible.
        for dashboard in ["trends", "overview"] {
            let order = DashboardLayoutSection.defaultOrder(for: dashboard)
            XCTAssertEqual(Set(order).count, order.count, "\(dashboard) repeats a section")
            for extra in DashboardExtraSection.allCases {
                let section = DashboardLayoutSection(rawValue: extra.rawValue)
                XCTAssertNotNil(section, "\(extra.rawValue) has no layout section")
                XCTAssertTrue(order.contains(section!), "\(dashboard) does not place \(extra.rawValue)")
            }
        }
    }

    // MARK: - Hidden decode

    func testUnsetHiddenMeansExtrasOffSoAnUntouchedDashboardMatchesItsReference() {
        for dashboard in ["trends", "overview"] {
            let hidden = DashboardLayoutPrefs.hidden("", dashboard: dashboard)
            let visible = DashboardLayoutPrefs.order("", dashboard: dashboard).filter { !hidden.contains($0) }
            XCTAssertTrue(visible.allSatisfy { !$0.isExtra },
                          "\(dashboard): an untouched dashboard must show no optional section")
            XCTAssertFalse(visible.isEmpty, "\(dashboard): the reference blocks must survive")
        }
    }

    func testSentinelMeansNothingHiddenWhichIsNotTheSameAsUnset() {
        // Empty and the sentinel are opposite meanings; conflating them would either hide every extra
        // for a user who showed them all, or reveal all thirteen to a user who touched nothing.
        XCTAssertTrue(DashboardLayoutPrefs.hidden(DashboardLayoutPrefs.noneHiddenSentinel,
                                                  dashboard: "trends").isEmpty)
        XCTAssertFalse(DashboardLayoutPrefs.hidden("", dashboard: "trends").isEmpty)
    }

    func testRoundTripPreservesAUserArrangement() {
        let visible: [DashboardLayoutSection] = [.hero, .activity, .goals, .coach]
        let hidden: [DashboardLayoutSection] = [.trendsChart, .metricStrip]

        let order = DashboardLayoutPrefs.order(DashboardLayoutPrefs.encode(visible + hidden), dashboard: "trends")
        let decodedHidden = DashboardLayoutPrefs.hidden(DashboardLayoutPrefs.encodeHidden(hidden), dashboard: "trends")

        // The saved sections keep their saved order, and a hidden one keeps its slot so unhiding
        // restores its position rather than appending it to the end.
        XCTAssertEqual(Array(order.prefix(6)), visible + hidden)
        XCTAssertEqual(decodedHidden, Set(hidden))
        XCTAssertEqual(order.filter { !decodedHidden.contains($0) }.prefix(4).map { $0 }, visible)
    }

    func testUnknownAndMissingSectionsAreHealedRatherThanDropped() {
        // A section added in a later build (absent from a stored order) must still appear, and a stale
        // id from an older build must not survive as a phantom entry.
        let order = DashboardLayoutPrefs.order("hero,notASection", dashboard: "trends")

        XCTAssertEqual(order.first, .hero)
        XCTAssertEqual(Set(order), Set(DashboardLayoutSection.defaultOrder(for: "trends")))
    }

    /// Coach and Momentum are reference blocks, not optional extras, so an untouched dashboard actually
    /// shows them. Leaving either flagged `isExtra` would hide it by default and reproduce the very gap
    /// each one closes — for Momentum that was half the reason it never appeared here at all.
    func testCoachAndMomentumAreVisibleByDefaultOnBothDashboards() {
        XCTAssertFalse(DashboardLayoutSection.coach.isExtra)
        XCTAssertFalse(DashboardLayoutSection.momentum.isExtra)
        for dashboard in ["trends", "overview"] {
            let hidden = DashboardLayoutPrefs.hidden("", dashboard: dashboard)
            XCTAssertFalse(hidden.contains(.coach), "\(dashboard): Coach must not start hidden")
            XCTAssertFalse(hidden.contains(.momentum), "\(dashboard): Momentum must not start hidden")
        }
    }

    /// One hint per dashboard, not one per app: someone who has used Trends for months and then tries
    /// Overview has not been told about Overview's wordmark.
    func testArrangeHintIsRememberedPerDashboard() {
        XCTAssertNotEqual(DashboardArrangeHint.seenKey("trends"), DashboardArrangeHint.seenKey("overview"))
    }

    // MARK: - What the load gating rests on

    /// `load()` on both dashboards now SKIPS the reads that only feed a hidden section — `workoutRows`
    /// (~750 ms on a large library in a field log) and the journal lookup. That is only a win because
    /// those sections are hidden by default, and it is only correct because the sections that ARE shown
    /// by default still have their data loaded. Pin both halves: flipping a default here silently
    /// changes what every launch reads.
    func testDefaultVisibilityMatchesWhatTheLoadGatingAssumes() {
        for dashboard in ["trends", "overview"] {
            let hidden = DashboardLayoutPrefs.hidden("", dashboard: dashboard)
            XCTAssertTrue(hidden.contains(.workoutsList), "\(dashboard): gating assumes this is off by default")
            XCTAssertTrue(hidden.contains(.journal), "\(dashboard): gating assumes this is off by default")
        }
        // Trends shows "Recent activity" by default, so its workout read must still happen there.
        XCTAssertFalse(DashboardLayoutPrefs.hidden("", dashboard: "trends").contains(.activity))
        // Overview has no `.activity` block at all, which is why it can skip workouts entirely.
        XCTAssertFalse(DashboardLayoutSection.defaultOrder(for: "overview").contains(.activity))
    }

    // MARK: - "More workouts"

    /// WorkoutRow takes every field on purpose (#1444), so spell them all out.
    private func row(startingAt ts: Int) -> WorkoutRow {
        WorkoutRow(startTs: ts, endTs: ts + 1_800, sport: "Running", source: "whoop",
                   durationS: 1_800, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                   distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    func testMoreWorkoutsKeepsTheNewestRowWhenRecentActivityIsHidden() {
        let workouts = [row(startingAt: 300), row(startingAt: 200), row(startingAt: 100)]

        // `.activity` visible: it already shows the newest, so "More workouts" is the remainder.
        XCTAssertEqual(TrendsDashboardView.moreWorkouts(workouts, activityVisible: true),
                       Array(workouts.dropFirst()))

        // `.activity` hidden: dropping the first would make the MOST RECENT workout disappear from the
        // screen entirely — the one row someone enabling this section is most likely looking for.
        XCTAssertEqual(TrendsDashboardView.moreWorkouts(workouts, activityVisible: false), workouts)
    }

    func testMoreWorkoutsIsEmptyWhenActivityAlreadyShowsTheOnlyOne() {
        XCTAssertTrue(TrendsDashboardView.moreWorkouts([row(startingAt: 300)], activityVisible: true).isEmpty)
        XCTAssertTrue(TrendsDashboardView.moreWorkouts([], activityVisible: false).isEmpty)
    }
}
