import XCTest
import WhoopStore
import StrandAnalytics
@testable import StrandCore

/// Which sessions the strength share of Effort counts (#2438) and how much each adds.
final class StrengthEffortTests: XCTestCase {
    private func row(_ start: Int, minutes: Int, sport: String, source: String) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + minutes * 60, sport: sport, source: source,
                   durationS: Double(minutes * 60), energyKcal: nil, avgHr: nil, maxHr: nil,
                   strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    private func rating(_ id: String, start: Int, rpe: Double, ratedAt: Int?, sessionId: String? = nil)
        -> TrainingSessionRating {
        TrainingSessionRating(id: id, sessionId: sessionId, workoutStartTs: start, ratedAtTs: ratedAt,
                              rpe: rpe, sport: nil, source: "manual-session-rpe")
    }

    private func fused(_ rows: [WorkoutRow]) -> [UnifiedTrainingSession] {
        TrainingSessionResolver.resolve(rows: rows, metadata: [], links: [], preferences: []).sessions
    }

    func testARatedStrengthSessionAddsRPETimesMinutes() throws {
        let sessions = StrengthEffort.sessions(
            fused: fused([row(10_000, minutes: 60, sport: "Strength Training", source: "hevy")]),
            ratings: [rating("r", start: 10_000, rpe: 7, ratedAt: 20_000)])
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(session.minutes, 60)
        XCTAssertEqual(session.load, 0.11 * 7 * 60, accuracy: 1e-9)
    }

    /// No rating, no share: there is no assumed value. Yoga is mobility and a run is endurance, rated or not.
    func testUnratedStrengthAndRatedNonStrengthAddNothing() {
        let sessions = StrengthEffort.sessions(
            fused: fused([row(10_000, minutes: 60, sport: "Strength Training", source: "hevy"),
                          row(30_000, minutes: 60, sport: "Yoga", source: "manual"),
                          row(50_000, minutes: 60, sport: "Running", source: "manual")]),
            ratings: [rating("y", start: 30_000, rpe: 6, ratedAt: 31_000),
                      rating("r", start: 50_000, rpe: 8, ratedAt: 51_000)])
        XCTAssertEqual(sessions, [])
    }

    /// The same rule as Training Load: the latest answer wins, also when it was given on another source of
    /// the same session.
    func testTheLatestRatingOfOneSessionWinsAcrossItsSources() throws {
        let hevy = row(10_000, minutes: 60, sport: "Strength Training", source: "hevy")
        let health = row(10_030, minutes: 59, sport: "Strength Training", source: "apple-health")
        let sessions = StrengthEffort.sessions(
            fused: fused([hevy, health]),
            ratings: [rating("old", start: 10_000, rpe: 5, ratedAt: 11_000),
                      rating("new", start: 10_030, rpe: 8, ratedAt: 12_000)])
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(try XCTUnwrap(sessions.first).rpe, 8)
    }

    func testRatingsOutsideOneToTenAreIgnored() {
        let sessions = StrengthEffort.sessions(
            fused: fused([row(10_000, minutes: 60, sport: "Strength Training", source: "hevy")]),
            ratings: [rating("r", start: 10_000, rpe: 0, ratedAt: 20_000)])
        XCTAssertEqual(sessions, [])
    }

    /// A day carries the sessions that start on it; a day without any is left out, so its signature stays.
    func testLoadGoesToTheDayTheSessionStartsOn() {
        let day = 86_400 * 20_000
        let sessions = [StrengthEffort.Session(sessionId: "a", startTs: day + 3_600, rpe: 7, minutes: 60),
                        StrengthEffort.Session(sessionId: "b", startTs: day + 86_400 - 60, rpe: 5, minutes: 30)]
        let byDay = DailyAnalysis.strengthLoadByDay(sessions, tzOffset: 0)
        XCTAssertEqual(byDay.count, 1)
        XCTAssertEqual(byDay[AnalyticsEngine.dayString(day, offsetSec: 0)] ?? 0, 0.11 * (7 * 60 + 5 * 30), accuracy: 1e-9)
        XCTAssertEqual(StrengthEffort.load(sessions, startingIn: day ..< day + 3_600), 0)
        XCTAssertEqual(StrengthEffort.load(sessions, startingIn: day ..< day + 7_200), 0.11 * 7 * 60, accuracy: 1e-9)
    }
}
