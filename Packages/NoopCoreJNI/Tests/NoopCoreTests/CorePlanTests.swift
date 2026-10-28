import Foundation
import XCTest
import StrandCore
@testable import NoopCore

/// The plan book's wording on Android is `CoachPlanView`'s: relative day names and neutral status lines.
/// Only the pure wording is tested here; the store writes the wearer's real plan file.
@MainActor
final class CorePlanTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-28T12:00:00Z")!

    private func day(_ offset: Int) -> String {
        StoreReader.localDayKey(now.addingTimeInterval(Double(offset) * 86_400))
    }

    func testRelativeDayNames() {
        XCTAssertEqual(CorePlan.dayLabel(day(0), now: now), "Today")
        XCTAssertEqual(CorePlan.dayLabel(day(1), now: now), "Tomorrow")
        XCTAssertEqual(CorePlan.dayLabel(day(-1), now: now), "Yesterday")
        XCTAssertEqual(CorePlan.dayLabel("not a day", now: now), "not a day")
    }

    func testStatusLinesStayNeutral() {
        var p = PlanProposal(day: day(-2), sport: "Run", intent: .easy, status: .skipped, skipReason: .pain)
        XCTAssertEqual(CorePlan.statusLine(p, now: now), "didn't happen — Pain")
        p.status = .completed
        XCTAssertEqual(CorePlan.statusLine(p, now: now), "completed — effect not rated")
        p.effectFeedback = .helpful
        XCTAssertEqual(CorePlan.statusLine(p, now: now), "completed — Helpful")
        p.status = .declined
        XCTAssertEqual(CorePlan.statusLine(p, now: now), "you passed on this one")
        p.status = .rescheduled
        p.rescheduledFrom = day(-1)
        XCTAssertEqual(CorePlan.statusLine(p, now: now), "moved from Yesterday")
    }
}
