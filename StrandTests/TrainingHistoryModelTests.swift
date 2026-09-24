import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// P5: the history view reads the Training Load screen's own series and bands, and a jump keeps the
/// chosen day in view without running past today.
final class TrainingHistoryModelTests: XCTestCase {
    private typealias F = TrainingLoadLanesTests

    private func source(_ fixture: F.Fixture) -> TrainingHistoryModel.Source {
        TrainingHistoryModel.source(workouts: fixture.strength.workouts, templates: fixture.strength.templates,
                                    sessions: fixture.sessions, resolution: fixture.cardio,
                                    ratings: fixture.ratings, vo2Estimates: [], vo2Apple: [],
                                    today: F.today, offset: 0).0
    }

    /// The current period's band is the band the Training Load hero shows today.
    func testTheLastPeriodReadsTheScreensBand() {
        let fixture = F.fixture(days: 120)
        let screen = F.prepared(fixture)
        let built = TrainingHistoryModel.build(source: source(fixture), span: .threeMonths, end: F.today,
                                               chosenLifts: [])
        XCTAssertEqual(built.range.resolution, .day)
        let strengthDay = screen.strength.reading?.day
        let cardioDay = screen.cardio.reading?.day
        XCTAssertEqual(built.strength.first { $0.period.start == strengthDay }?.band, screen.strength.reading?.band)
        XCTAssertEqual(built.cardio.first { $0.period.start == cardioDay }?.band, screen.cardio.reading?.band)
    }

    /// The last seven days summed from the history equal the screen's seven-day totals.
    func testTheLastWeekSumsToTheScreensTotals() {
        let fixture = F.fixture(days: 120)
        let screen = F.prepared(fixture)
        let built = TrainingHistoryModel.build(source: source(fixture), span: .threeMonths, end: F.today,
                                               chosenLifts: [])
        func lastSeven(_ lane: [TrainingHistoryLanePeriod], through day: String?) -> Double {
            guard let day else { return 0 }
            let first = WeeklyDigestEngine.addDays(day, -6)
            return lane.filter { $0.period.start >= first && $0.period.start <= day }.compactMap(\.total).reduce(0, +)
        }
        XCTAssertEqual(lastSeven(built.strength, through: screen.strength.reading?.day),
                       screen.strength.sevenDayTotal, accuracy: 1e-9)
        XCTAssertEqual(lastSeven(built.cardio, through: screen.cardio.reading?.day),
                       screen.cardio.sevenDayTotal, accuracy: 1e-9)
    }

    /// Session Load's quota adds up to the sessions there were and the ones rated.
    func testSessionQuotaCountsRatedSessions() {
        let fixture = F.fixture(days: 60)
        let built = TrainingHistoryModel.build(source: source(fixture), span: .threeMonths, end: F.today,
                                               chosenLifts: [])
        let rated = built.session.compactMap(\.measured).reduce(0, +)
        XCTAssertGreaterThan(rated, 0)
        XCTAssertLessThanOrEqual(rated, built.session.compactMap(\.possible).reduce(0, +))
    }

    func testChosenLiftsWinAndUnknownOnesFallBack() {
        let fixture = F.fixture(days: 60)
        let built = TrainingHistoryModel.build(source: source(fixture), span: .threeMonths, end: F.today,
                                               chosenLifts: ["bench"])
        XCTAssertEqual(built.lifts.map(\.id), ["bench"])
        XCTAssertTrue(built.lifts[0].values.contains { $0.value != nil })
        let fallback = TrainingHistoryModel.build(source: source(fixture), span: .threeMonths, end: F.today,
                                                  chosenLifts: ["gone"])
        XCTAssertEqual(fallback.lifts.map(\.id), ["bench"], "a lift no longer in the history falls back to the most trained")
    }

    func testAJumpCentresTheDayButNeverPassesToday() {
        XCTAssertEqual(TrainingHistoryModel.end(for: .threeMonths, jumpedTo: "2025-03-01", today: "2026-09-24"),
                       "2025-04-16")
        XCTAssertEqual(TrainingHistoryModel.end(for: .oneYear, jumpedTo: "2026-09-01", today: "2026-09-24"),
                       "2026-09-24")
        XCTAssertEqual(TrainingHistoryModel.end(for: .all, jumpedTo: "2020-01-01", today: "2026-09-24"),
                       "2026-09-24")
        XCTAssertEqual(TrainingHistoryModel.end(for: .fiveYears, jumpedTo: nil, today: "2026-09-24"), "2026-09-24")
    }
}
