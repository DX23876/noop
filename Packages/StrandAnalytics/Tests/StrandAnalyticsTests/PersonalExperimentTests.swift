import XCTest
@testable import StrandAnalytics

/// The Personal Experiment contrast (Refs #2923). The Kotlin twin
/// (`PersonalExperimentBaselineTest`) asserts the SAME cases against the numbers this suite pins, so the
/// two cards cannot drift apart.
final class PersonalExperimentTests: XCTestCase {
    /// Outcome days around a start on 2026-11-05, with the unanswered days placed AFTER the explicit NO
    /// days so a baseline that took "every day that is not a logged yes" lands on different days.
    private let outcomes: [String: Double] = [
        "2026-11-01": 60,   // answered NO
        "2026-11-02": 80,   // answered NO
        "2026-11-03": 10,   // never answered
        "2026-11-04": 20,   // never answered
        "2026-11-05": 90,   // start, logged YES
        "2026-11-06": 100,  // logged YES
        "2026-11-07": 30,   // inside the window, never answered
    ]
    private let logged: Set<String> = ["2026-11-05", "2026-11-06"]
    private let controls: Set<String> = ["2026-11-01", "2026-11-02"]

    /// The baseline is the explicit NO days, not the silence next to them: with a two-day window it is
    /// 60 and 80 (mean 70), where the old "not a logged yes" rule took the two unanswered days (mean 15)
    /// and reported a 80-point effect that was an artefact of never logging.
    func testTheBaselineIsExplicitNoDaysOnly() throws {
        let snap = try XCTUnwrap(PersonalExperiment.snapshot(
            outcomeByDay: outcomes, loggedDays: logged, controlDays: controls,
            startedDay: "2026-11-05", today: "2026-11-07", durationDays: 3, baselineWindowDays: 2))
        XCTAssertEqual(snap.baselineDays, ["2026-11-01", "2026-11-02"])
        XCTAssertEqual(try XCTUnwrap(snap.baselineMean), 70, accuracy: 1e-9)
        XCTAssertEqual(snap.baselineCount, 2)
        XCTAssertEqual(snap.interventionDays, ["2026-11-05", "2026-11-06"])
        XCTAssertEqual(try XCTUnwrap(snap.interventionMean), 95, accuracy: 1e-9)
        XCTAssertEqual(snap.interventionCount, 2)
        XCTAssertEqual(try XCTUnwrap(snap.delta), 25, accuracy: 1e-9)
        XCTAssertEqual(snap.daysElapsed, 3)
        XCTAssertEqual(snap.compliancePct, 200.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(snap.pairedCount, 2)
    }

    /// Without a single NO day before the start there is no baseline to read, so the card has to say so
    /// rather than print a number taken from days nobody answered.
    func testNoControlDaysMeansNoBaseline() throws {
        let snap = try XCTUnwrap(PersonalExperiment.snapshot(
            outcomeByDay: outcomes, loggedDays: logged, controlDays: [],
            startedDay: "2026-11-05", today: "2026-11-07", durationDays: 3, baselineWindowDays: 2))
        XCTAssertTrue(snap.baselineDays.isEmpty)
        XCTAssertNil(snap.baselineMean)
        XCTAssertEqual(snap.baselineCount, 0)
        XCTAssertNil(snap.delta)
        XCTAssertEqual(snap.pairedCount, 0)
        XCTAssertEqual(try XCTUnwrap(snap.interventionMean), 95, accuracy: 1e-9)
    }

    /// The window: the intervention side takes the first `durationDays` outcome days from the start and
    /// keeps the logged ones, days elapsed is inclusive and capped by the duration, and an experiment
    /// that has not started has no snapshot at all.
    func testTheWindowAndTheElapsedCount() throws {
        let short = try XCTUnwrap(PersonalExperiment.snapshot(
            outcomeByDay: outcomes, loggedDays: logged, controlDays: controls,
            startedDay: "2026-11-05", today: "2026-11-05", durationDays: 14, baselineWindowDays: 7))
        XCTAssertEqual(short.interventionDays, ["2026-11-05"])
        XCTAssertEqual(short.daysElapsed, 1)
        XCTAssertEqual(short.compliancePct, 100, accuracy: 1e-9)
        XCTAssertEqual(short.baselineDays, ["2026-11-01", "2026-11-02"], "a wider window cannot invent baseline days")

        let capped = try XCTUnwrap(PersonalExperiment.snapshot(
            outcomeByDay: outcomes, loggedDays: logged, controlDays: controls,
            startedDay: "2026-11-05", today: "2026-11-07", durationDays: 1, baselineWindowDays: 7))
        XCTAssertEqual(capped.interventionDays, ["2026-11-05"])
        XCTAssertEqual(capped.daysElapsed, 1, "elapsed never exceeds the chosen duration")

        XCTAssertNil(PersonalExperiment.snapshot(
            outcomeByDay: outcomes, loggedDays: logged, controlDays: controls,
            startedDay: "", today: "2026-11-07", durationDays: 3, baselineWindowDays: 2))
    }
}
