import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// Pins the lane readings Training Load shows, so the screens that share them can be checked against the
/// exact figures rather than against a second implementation.
final class TrainingLoadLanesTests: XCTestCase {
    /// Midday UTC; every fixture day is an offset from it.
    static let now = 1_757_937_600
    static let today = AnalyticsEngine.dayString(now, offsetSec: 0)

    static func ts(_ dayOffset: Int, hour: Int = 0) -> Int { now + dayOffset * 86_400 + hour * 3_600 }

    static func workout(_ id: String, day: Int, rpes: [Double?]) -> HevyWorkout {
        let sets = rpes.enumerated().map { index, rpe in
            HevySet(index: index, type: .normal, weightKg: 80, reps: 6, distanceM: nil, durationS: nil,
                    rpe: rpe, customMetric: nil)
        }
        let exercise = HevyExercise(index: 0, title: "Bench Press", templateId: "bench", supersetId: nil,
                                    notes: nil, sets: sets)
        return HevyWorkout(id: id, title: "Push", routineId: nil, notes: nil, startTs: ts(day),
                           endTs: ts(day) + 3_600, updatedAtTs: ts(day) + 3_600, createdAtTs: ts(day),
                           exercises: [exercise])
    }

    static func cardio(_ id: String, day: Int, hour: Int = 2) -> UnifiedTrainingSession {
        let start = ts(day, hour: hour)
        let row = WorkoutRow(startTs: start, endTs: start + 3_600, sport: "Running", source: "apple-health",
                             durationS: 3_600, energyKcal: nil, avgHr: 140, maxHr: 165, strain: 10,
                             distanceM: 8_000, zonesJSON: nil, notes: nil, steps: nil)
        return UnifiedTrainingSession(id: id, kind: .endurance, row: row,
                                      components: [TrainingSessionComponent(id: id, row: row, metadata: nil)],
                                      fusionOrigin: "automatic")
    }

    /// Sixty days of history: lifting every third day with a mix of rated and unrated sets, running every
    /// second day with one long unpriced run (an unknown day), one duplicate awaiting review, and session
    /// ratings including a rated-twice session.
    struct Fixture {
        let strength: ResolvedStrengthHistory
        let sessions: [UnifiedTrainingSession]
        let cardio: TrainingCardioLoadResolution
        let ratings: [SessionRPEEntry]
    }

    static func fixture(days: Int = 60, unpricedDay: Int = -4) -> Fixture {
        var workouts: [HevyWorkout] = []
        for day in stride(from: -(days - 1), through: 0, by: 3) {
            let heavy = day > -10
            workouts.append(workout("w\(-day)", day: day,
                                    rpes: heavy ? [8, 9, nil, 9, 8] : [7, nil, 8]))
        }
        var sessions: [UnifiedTrainingSession] = []
        var resolution = TrainingCardioLoadResolution()
        for day in stride(from: -(days - 2), through: 0, by: 2) {
            let session = cardio("c\(-day)", day: day)
            sessions.append(session)
            guard day != unpricedDay else { continue }
            let trimp = 60 + Double((-day) % 7) * 9 + (day > -8 ? 40 : 0)
            resolution.loads[session.id] = TrainingCardioLoad(sessionId: session.id, trimp: trimp, effort: 10,
                                                              source: .noopBand, coveredMinutes: 60,
                                                              possibleMinutes: 60)
        }
        let twin = cardio("twin", day: -2, hour: 2)
        sessions.append(UnifiedTrainingSession(id: "twin", kind: twin.kind,
                                               row: WorkoutRow(startTs: twin.row.startTs + 300,
                                                               endTs: twin.row.endTs + 300,
                                                               sport: "Running", source: "noop",
                                                               durationS: 3_600, energyKcal: nil, avgHr: 141,
                                                               maxHr: 166, strain: 10, distanceM: nil,
                                                               zonesJSON: nil, notes: nil, steps: nil),
                                               components: twin.components, fusionOrigin: "automatic"))
        resolution.duplicateSessionIds = ["twin"]

        var ratings: [SessionRPEEntry] = []
        for day in stride(from: -20, through: 0, by: 2) where day % 4 == 0 {
            ratings.append(SessionRPEEntry(id: "r\(-day)", sessionId: "c\(-day)", startTs: ts(day, hour: 2),
                                           rpe: 6, sport: "Running", ratedAtTs: ts(day, hour: 3)))
        }
        ratings.append(SessionRPEEntry(id: "r0-again", sessionId: "c0", startTs: ts(0, hour: 2), rpe: 8,
                                       sport: "Running", ratedAtTs: ts(0, hour: 5)))
        let strength = ResolvedStrengthHistory(sessions: [], workouts: workouts, templates: [:],
                                               historyAvailableFrom: ts(-(days - 1)))
        return Fixture(strength: strength, sessions: sessions, cardio: resolution, ratings: ratings)
    }

    static func describe(_ lane: TrainingLoadModel.Lane?) -> String {
        guard let lane else { return "nil" }
        func f(_ value: Double?) -> String { value.map { String(format: "%.6f", $0) } ?? "nil" }
        return [
            "total=\(f(lane.sevenDayTotal))",
            "sets=\(lane.sevenDayWorkingSets)",
            "ratio=\(f(lane.trend?.ratio))",
            "pct=\(f(lane.trend?.percentChange))",
            "maturity=\(lane.relative.maturity)",
            "band=\(lane.relative.band.map { "\($0)" } ?? "nil")",
            "lower=\(lane.isLowerBound)",
            "monotony=\(f(lane.distribution?.monotony))",
            "strain=\(f(lane.distribution?.strain))",
            "wow=\(f(lane.weekOverWeek))",
            "measured=\(lane.measuredCount)/\(lane.possibleCount)",
            "status=\(lane.status.map { "\($0.band)" } ?? "nil")",
        ].joined(separator: " ")
    }

    static func describe(_ ratios: [TrainingLoadModel.RatioPoint]) -> String {
        func f(_ value: Double?) -> String { value.map { String(format: "%.6f", $0) } ?? "nil" }
        return "count=\(ratios.count) " + ratios.suffix(3)
            .map { "\($0.day):\(f($0.strength)),\(f($0.cardio))" }.joined(separator: " ")
    }

    static func prepared(_ fixture: Fixture) -> TrainingLoadModel.Prepared {
        TrainingLoadModel.prepare(strengthHistory: fixture.strength, unified: fixture.sessions,
                                  cardioResolution: fixture.cardio, rpeEntries: fixture.ratings,
                                  dailyRows: [], vo2: [], today: today, now: now, offset: 0)
    }

    /// Captured from the computation as it stood before the lanes were shared; a change here is a change
    /// to what Training Load shows.
    func testTodayReadingsMatchThePinnedOracle() {
        let prepared = Self.prepared(Self.fixture())
        XCTAssertEqual(Self.describe(prepared.strength),
                       "total=7.440000 sets=10 ratio=1.649667 pct=64.966741 maturity=baselineGrowing band=nil lower=false monotony=0.632456 strain=4.705469 wow=36.764706 measured=8/10 status=above")
        XCTAssertEqual(Self.describe(prepared.cardio),
                       "total=372.000000 sets=0 ratio=nil pct=nil maturity=baselineGrowing band=nil lower=true monotony=nil strain=nil wow=nil measured=3/4 status=nil")
        XCTAssertEqual(Self.describe(prepared.session),
                       "total=840.000000 sets=0 ratio=nil pct=nil maturity=earlyEstimate band=nil lower=true monotony=nil strain=nil wow=nil measured=2/7 status=nil")
        XCTAssertEqual(Self.describe(prepared.ratios),
                       "count=56 2025-09-13:2.735802,1.306513 2025-09-14:1.500000,1.042146 2025-09-15:1.649667,1.425287")
        XCTAssertNil(prepared.provisionalStrengthRing)
        XCTAssertTrue(prepared.cardioMeasured)
    }

    func testAnUnknownDayOutsideTheWindowLeavesTheCardioComparisonIntact() {
        let prepared = Self.prepared(Self.fixture(unpricedDay: -40))
        XCTAssertEqual(Self.describe(prepared.cardio),
                       "total=508.000000 sets=0 ratio=1.668309 pct=66.830870 maturity=baselineGrowing band=nil lower=false monotony=1.122291 strain=570.123789 wow=94.636015 measured=4/4 status=above")
    }
}
