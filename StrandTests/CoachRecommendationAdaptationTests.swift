import XCTest
@testable import Strand

final class CoachRecommendationAdaptationTests: XCTestCase {
    func testRepeatedRecentNegativeFeedbackCreatesCooldown() {
        let now = date("2026-07-28 12:00")
        let history = [
            proposal(day: "2026-07-27", status: .declined, decidedAt: now.addingTimeInterval(-86_400)),
            proposal(day: "2026-07-26", status: .skipped,
                     decidedAt: now.addingTimeInterval(-2 * 86_400)),
        ]

        let advice = CoachRecommendationAdaptation.advice(
            sport: "Jogging", intent: .easy, day: "2026-07-29",
            proposedTime: nil, history: history, now: now
        )
        XCTAssertNotNil(advice.blockReason)
        XCTAssertTrue(advice.blockReason?.contains("different activity") == true)
    }

    func testRepeatedHelpfulTimeBecomesUntimedProposalDefault() {
        let history = [
            proposal(day: "2026-07-20", status: .completed,
                     time: date("2026-07-20 08:01"), effect: .helpful),
            proposal(day: "2026-07-22", status: .completed,
                     time: date("2026-07-22 07:59"), effect: .helpful),
        ]
        let advice = CoachRecommendationAdaptation.advice(
            sport: "Cycling", intent: .easy, day: "2026-07-30",
            proposedTime: nil, history: history, now: date("2026-07-28 12:00")
        )

        let components = Calendar.current.dateComponents([.hour, .minute],
                                                         from: try! XCTUnwrap(advice.preferredTime))
        XCTAssertEqual(components.hour, 8)
        XCTAssertEqual(components.minute, 0)
        XCTAssertTrue(advice.evidenceNote?.contains("helpful completions") == true)
    }

    func testExplicitProposalTimeIsNeverOverwritten() {
        let explicit = date("2026-07-30 18:30")
        let history = [
            proposal(day: "2026-07-20", status: .completed,
                     time: date("2026-07-20 08:00"), effect: .helpful),
            proposal(day: "2026-07-22", status: .completed,
                     time: date("2026-07-22 08:00"), effect: .helpful),
        ]
        let advice = CoachRecommendationAdaptation.advice(
            sport: "Cycling", intent: .easy, day: "2026-07-30",
            proposedTime: explicit, history: history, now: date("2026-07-28 12:00")
        )
        XCTAssertNil(advice.preferredTime)
    }

    private func proposal(day: String,
                          status: PlanProposal.Status,
                          time: Date? = nil,
                          effect: PlanProposal.EffectFeedback? = nil,
                          decidedAt: Date? = nil) -> PlanProposal {
        PlanProposal(day: day, time: time, sport: status == .declined || status == .skipped
                     ? "Jogging" : "Cycling",
                     intent: .easy, status: status,
                     decidedAt: decidedAt ?? time,
                     effectFeedback: effect)
    }

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: value)!
    }
}
