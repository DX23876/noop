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

    /// Training days are counted back from today, so a longer fixture only adds older days. Sixty days of history: lifting every third day with a mix of rated and unrated sets, running every
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
        for day in stride(from: -2, through: -(days - 1), by: -3).reversed() {
            let heavy = day > -10
            workouts.append(workout("w\(-day)", day: day,
                                    rpes: heavy ? [8, 9, nil, 9, 8] : [7, nil, 8]))
        }
        var sessions: [UnifiedTrainingSession] = []
        var resolution = TrainingCardioLoadResolution()
        for day in stride(from: 0, through: -(days - 2), by: -2).reversed() {
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
            "status=\(lane.reading?.band.map { "\($0)" } ?? "nil")",
            "guard=\(lane.reading.map { "\($0.guardState)" } ?? "nil")",
            "day=\(lane.reading?.day ?? "nil")",
        ].joined(separator: " ")
    }

    static func describe(_ ratios: [TrainingLoadModel.RatioPoint]) -> String {
        func f(_ value: Double?) -> String { value.map { String(format: "%.6f", $0) } ?? "nil" }
        func b(_ band: RelativeLoadBand?) -> String { band.map { "\($0)" } ?? "nil" }
        return "count=\(ratios.count) " + ratios.suffix(3)
            .map { "\($0.day):\(f($0.strength))/\(b($0.strengthBand)),\(f($0.cardio))/\(b($0.cardioBand))" }
            .joined(separator: " ")
    }

    static func prepared(_ fixture: Fixture) -> TrainingLoadModel.Prepared {
        TrainingLoadModel.prepare(strengthHistory: fixture.strength, unified: fixture.sessions,
                                  cardioResolution: fixture.cardio, rpeEntries: fixture.ratings,
                                  dailyRows: [], vo2: [], today: today, now: now, offset: 0)
    }

    /// Captured from `LaneEngine` when the lanes moved onto it; a change here is a change to what
    /// Training Load shows. No lifting is logged today, so strength reads through yesterday; the run
    /// today puts cardio through today. The unpriced run four days ago withholds every cardio comparison
    /// whose window holds it — the hero, the chart and the strip alike.
    func testTodayReadingsMatchThePinnedOracle() {
        let prepared = Self.prepared(Self.fixture())
        XCTAssertEqual(Self.describe(prepared.strength),
                       "total=7.440000 sets=10 ratio=1.500000 pct=50.000000 maturity=baselineGrowing band=nil lower=false monotony=0.632456 strain=4.705469 wow=2.762431 measured=8/10 status=muchHigher guard=none day=2025-09-14")
        XCTAssertEqual(Self.describe(prepared.cardio),
                       "total=372.000000 sets=0 ratio=nil pct=nil maturity=baselineGrowing band=nil lower=true monotony=nil strain=nil wow=nil measured=3/4 status=nil guard=none day=2025-09-15")
        XCTAssertEqual(Self.describe(prepared.session),
                       "total=840.000000 sets=0 ratio=nil pct=nil maturity=earlyEstimate band=nil lower=true monotony=nil strain=nil wow=nil measured=2/7 status=nil guard=nil day=nil")
        XCTAssertEqual(Self.describe(prepared.ratios),
                       "count=56 2025-09-13:2.735802/muchHigher,nil/nil 2025-09-14:1.500000/muchHigher,nil/nil 2025-09-15:nil/nil,nil/nil")
        XCTAssertNil(prepared.provisionalStrengthRing)
        XCTAssertTrue(prepared.cardioMeasured)
    }

    func testAnUnknownDayOutsideTheWindowLeavesTheCardioComparisonIntact() {
        let prepared = Self.prepared(Self.fixture(unpricedDay: -40))
        XCTAssertEqual(Self.describe(prepared.cardio),
                       "total=508.000000 sets=0 ratio=1.668309 pct=66.830870 maturity=baselineGrowing band=nil lower=false monotony=1.122291 strain=570.123789 wow=94.636015 measured=4/4 status=muchHigher guard=none day=2025-09-15")
    }

    static func strengthLane(_ fixture: Fixture, through day: String) -> TrainingLoadModel.Lane {
        let workouts = fixture.strength.workouts
        return TrainingLoadLanes.strengthLane(workouts: workouts,
                                              byDay: TrainingLoadLanes.strengthByDay(workouts, tzOffsetSeconds: 0),
                                              through: day, tzOffsetSeconds: 0)
    }

    static func cardioLane(_ fixture: Fixture, through day: String) -> TrainingLoadModel.Lane {
        let series = TrainingLoadLanes.cardioSeries(sessions: fixture.sessions, resolution: fixture.cardio,
                                                    tzOffsetSeconds: 0)
        return TrainingLoadLanes.cardioLane(sessions: fixture.sessions, resolution: fixture.cardio, series: series,
                                            through: day, tzOffsetSeconds: 0)
    }

    /// Cardio and Strength read a longer window than Training Load. Anything older than the lookback must
    /// not move a reading, or the two screens would disagree with it.
    func testHistoryBeyondTheLookbackDoesNotMoveTheReading() {
        let shortest = Self.fixture(days: TrainingLoadLanes.lookbackDays + 1, unpricedDay: -40)
        let long = Self.fixture(days: 200, unpricedDay: -40)
        let prepared = Self.prepared(shortest)
        let strengthDay = prepared.strength.reading?.day ?? Self.today
        let cardioDay = prepared.cardio.reading?.day ?? Self.today
        XCTAssertEqual(Self.describe(Self.strengthLane(long, through: strengthDay)), Self.describe(prepared.strength))
        XCTAssertEqual(Self.describe(Self.cardioLane(long, through: cardioDay)), Self.describe(prepared.cardio))
    }

    /// A past week is read through its own Sunday: training after that day must not reach its reading.
    func testAPastWeekIgnoresEverythingAfterItsReadingDay() {
        let fixture = Self.fixture(days: 120, unpricedDay: -12)
        let day = WeeklyDigestEngine.addDays(Self.today, -9)
        let endOfDay = Self.ts(-8) - 12 * 3_600
        var truncatedLoads = TrainingCardioLoadResolution()
        let sessions = fixture.sessions.filter { $0.row.startTs < endOfDay }
        truncatedLoads.loads = fixture.cardio.loads.filter { id, _ in sessions.contains { $0.id == id } }
        truncatedLoads.duplicateSessionIds = fixture.cardio.duplicateSessionIds
        let truncated = Fixture(
            strength: ResolvedStrengthHistory(sessions: [], workouts: fixture.strength.workouts.filter { $0.startTs < endOfDay },
                                              templates: [:], historyAvailableFrom: nil),
            sessions: sessions, cardio: truncatedLoads, ratings: [])

        XCTAssertEqual(Self.describe(Self.strengthLane(fixture, through: day)),
                       Self.describe(Self.strengthLane(truncated, through: day)))
        let cardio = Self.cardioLane(fixture, through: day)
        XCTAssertEqual(Self.describe(cardio), Self.describe(Self.cardioLane(truncated, through: day)))
        XCTAssertTrue(cardio.isLowerBound, "the unpriced run on day -12 sits inside that week")
    }

    func testAWeekIsReadThroughItsSundayOrTodayWhileItRuns() {
        XCTAssertEqual(TrainingLoadLanes.readingDay(monday: "2025-09-01", today: "2025-09-15", hasActivityToday: false),
                       "2025-09-07")
        XCTAssertEqual(TrainingLoadLanes.readingDay(monday: "2025-09-15", today: "2025-09-17", hasActivityToday: true),
                       "2025-09-17")
        // A running week before today's first session is read through yesterday: the empty day has not
        // happened yet, and counting it as rest would lower the week every morning.
        XCTAssertEqual(TrainingLoadLanes.readingDay(monday: "2025-09-15", today: "2025-09-17", hasActivityToday: false),
                       "2025-09-16")
    }
}
