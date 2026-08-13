import XCTest
import StrandDesign
@testable import Strand

/// The goal summary lines and the health tone — the pieces the goal card and the Today tile now SHARE
/// rather than each keeping their own copy.
///
/// They are tested because the copies are exactly how this feature went wrong twice already: a second
/// progress formula on the journey page, and a second week-colour table. One definition, pinned here.
final class GoalSummaryLinesTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        c.firstWeekday = 2
        c.minimumDaysInFirstWeek = 4
        return c
    }

    private func date(_ value: String) -> Date {
        let p = value.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))!
    }

    private func snapshot(goal: CoachGoal, measurement: GoalMeasurement?) -> GoalTrackingSnapshot {
        GoalTrackingEngine.evaluate(goal: goal, proposals: [], measurement: measurement,
                                    now: date("2026-03-18"), calendar: calendar)
    }

    // MARK: - Health → tone

    func testEveryHealthStateMapsToItsTone() {
        XCTAssertEqual(GoalTrackingSnapshot.Health.onTrack.tone, .positive)
        XCTAssertEqual(GoalTrackingSnapshot.Health.attention.tone, .warning)
        XCTAssertEqual(GoalTrackingSnapshot.Health.atRisk.tone, .critical)
        XCTAssertEqual(GoalTrackingSnapshot.Health.decisionNeeded.tone, .critical)
        XCTAssertEqual(GoalTrackingSnapshot.Health.building.tone, .neutral)
        XCTAssertEqual(GoalTrackingSnapshot.Health.paused.tone, .neutral)
    }

    /// Every case has to be covered — a new health state must not silently fall into a default.
    func testToneCoversEveryCase() {
        for health in GoalTrackingSnapshot.Health.allCases {
            XCTAssertFalse(health.label.isEmpty)
            _ = health.tone
        }
    }

    // MARK: - The lines

    func testMeasurementLineNamesTheCurrentValueAndTheTarget() {
        let goal = CoachGoal(kind: .weight, title: "Lighter", baseline: 80, target: 75,
                             createdAt: date("2026-03-01"))
        let line = snapshot(goal: goal, measurement: .init(value: 78, date: date("2026-03-18")))
            .measurementLine
        XCTAssertEqual(line, "78.0 kg now · target 75.0 kg")
    }

    func testMeasurementLineIsSilentWithoutAMeasurement() {
        let goal = CoachGoal(kind: .weight, title: "Lighter", baseline: 80, target: 75,
                             createdAt: date("2026-03-01"))
        XCTAssertNil(snapshot(goal: goal, measurement: nil).measurementLine)
    }

    /// A goal with no route and no measurement still has to say something — the next step is the
    /// honest fallback, never an invented number.
    func testHeadlineFallsBackToTheNextActionWhenThereIsNothingMeasured() {
        let held = CoachGoal(kind: .custom, title: "Feel good on the hills",
                             createdAt: date("2026-03-01"))
        let s = snapshot(goal: held, measurement: nil)
        XCTAssertNil(s.routeLine)
        XCTAssertNil(s.measurementLine)
        XCTAssertEqual(s.headlineLine, s.nextAction)
    }

    func testDisplayTitleFallsBackToTheKindLabel() {
        let untitled = CoachGoal(kind: .sleep, title: "", createdAt: date("2026-03-01"))
        let s = snapshot(goal: untitled, measurement: nil)
        XCTAssertFalse(s.displayTitle.isEmpty)
        XCTAssertEqual(s.displayTitle, CoachGoal.Kind.sleep.label.localizedCatalogValue)
    }
}
