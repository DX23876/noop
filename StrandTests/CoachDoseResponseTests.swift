import XCTest
import StrandAnalytics
@testable import Strand

/// Pins T3.4 of Etappe T: `get_personal_patterns` gained a dose-response section
/// (`AICoachEngine.doseResponseLines`) — a prior-shrunk "each extra drink/cup ≈ Δ for you" read for
/// alcohol/caffeine, the SAME engine + documented priors the Insights Dose cards use. Pure (no store).
@MainActor
final class CoachDoseResponseTests: XCTestCase {

    func testNoDoseDataProducesNoLines() {
        let lines = AICoachEngine.doseResponseLines(
            byBehaviour: [:], doseRowsByBehavior: [:], recoveryByDay: [:], hrvByDay: [:])
        XCTAssertTrue(lines.isEmpty)
    }

    /// A journal "yes" day for a question that matches a dosed behaviour back-fills dose = 1
    /// (`InsightsHubViewModel.matches`), which is enough for the engine to return its prior-dominated
    /// read (below `DoseResponseEngine.minDoseDays`, so it's honest about being "typical, not yet yours").
    func testJournalYesDayBackfillsDoseForAlcohol() {
        let byBehaviour = ["Did you drink alcohol?": Set(["2026-01-01"])]
        let lines = AICoachEngine.doseResponseLines(
            byBehaviour: byBehaviour, doseRowsByBehavior: [:], recoveryByDay: [:], hrvByDay: [:])
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("Alcohol:"), "got: \(lines)")
        XCTAssertTrue(lines[0].contains("typical patterns, not yet yours"), "got: \(lines)")
    }

    /// An explicit dose row (no journal match needed) is enough on its own to produce a line.
    func testExplicitDoseRowAloneProducesALine() {
        let doseRows: [DosedBehavior: [(day: String, value: Double)]] = [
            .caffeine: [(day: "2026-01-01", value: 2)]
        ]
        let lines = AICoachEngine.doseResponseLines(
            byBehaviour: [:], doseRowsByBehavior: doseRows, recoveryByDay: [:], hrvByDay: [:])
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("Caffeine:"), "got: \(lines)")
    }

    /// A journal question that doesn't match any dosed behaviour contributes no dose data at all.
    func testUnmatchedJournalQuestionProducesNoLine() {
        let byBehaviour = ["Did you meditate?": Set(["2026-01-01"])]
        let lines = AICoachEngine.doseResponseLines(
            byBehaviour: byBehaviour, doseRowsByBehavior: [:], recoveryByDay: [:], hrvByDay: [:])
        XCTAssertTrue(lines.isEmpty)
    }

    /// Both dosed behaviours with data produce their own line, in `DosedBehavior.allCases` order.
    func testBothBehavioursProduceOneLineEach() {
        let byBehaviour = ["Did you drink alcohol?": Set(["2026-01-01"]),
                           "Had caffeine after 2pm?": Set(["2026-01-02"])]
        let lines = AICoachEngine.doseResponseLines(
            byBehaviour: byBehaviour, doseRowsByBehavior: [:], recoveryByDay: [:], hrvByDay: [:])
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("Alcohol:"))
        XCTAssertTrue(lines[1].contains("Caffeine:"))
    }
}
