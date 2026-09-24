import XCTest
@testable import StrandAnalytics
import WhoopStore

/// P6: the room left today and the day a high week settles, read against the same functions as the band.
final class LaneOutlookTests: XCTestCase {

    private func day(_ offset: Int) -> String { WeeklyDigestEngine.addDays("2026-01-01", offset) }

    /// A lane trained every day for `days` days at `load`, with a session each day.
    private func steady(days: Int, load: Double) -> (byDay: [String: Double], activity: LaneActivity) {
        var byDay: [String: Double] = [:]
        var sessions: [String: Int] = [:]
        for index in 0..<days {
            byDay[day(index)] = load
            sessions[day(index)] = 1
        }
        return (byDay, LaneActivity(sessionsByDay: sessions, minutesByDay: sessions.mapValues { _ in 60 }))
    }

    private func ratio(_ byDay: [String: Double], today: String) -> (Double, LaneThresholds) {
        let relative = TrainingLoad.relativeLoad(dailyByDay: byDay, through: today, coverage: .lane)
        return (relative.trend!.ratio, LaneEngine.thresholds(for: relative)!)
    }

    /// Provisional edges (three weeks of history): 10 a day for six days plus today must stay at or under
    /// 1.15 × 10 × 7 = 80.5, so 20.5 fits before "above", and 1.44 × 70 − 60 = 40.8 before "well above".
    func testRoomOnProvisionalEdgesMatchesTheWorkedValue() throws {
        var history = steady(days: 21, load: 10)
        history.byDay[day(21)] = nil
        let room = try XCTUnwrap(LaneOutlook.headroom(dailyByDay: history.byDay, activity: history.activity,
                                                      lane: .strength, today: day(21)))
        XCTAssertEqual(room.loggedToday, 0)
        XCTAssertEqual(room.beforeAbove, 20.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(room.beforeWellAbove), 40.8, accuracy: 0.01)
    }

    /// On personal edges the room is exactly where the band changes: at it the week still reads within the
    /// edge, a little over it the week does not. Checked with the functions the screen uses.
    func testRoomSitsExactlyOnTheBandEdge() throws {
        var history = steady(days: 90, load: 10)
        for index in stride(from: 0, to: 90, by: 3) { history.byDay[day(index)] = 16 }
        let today = day(90)
        history.byDay[today] = 4
        let room = try XCTUnwrap(LaneOutlook.headroom(dailyByDay: history.byDay, activity: history.activity,
                                                      lane: .cardio, today: today))
        XCTAssertEqual(room.loggedToday, 4)
        for (extra, edge) in [(room.beforeAbove, \LaneThresholds.above),
                              (try XCTUnwrap(room.beforeWellAbove), \LaneThresholds.wellAbove)] {
            var at = history.byDay
            at[today] = 4 + extra
            let (inside, insideEdges) = ratio(at, today: today)
            XCTAssertLessThanOrEqual(inside, insideEdges[keyPath: edge] + 1e-9)
            at[today] = 4 + extra + 0.5
            let (outside, outsideEdges) = ratio(at, today: today)
            XCTAssertGreaterThan(outside, outsideEdges[keyPath: edge])
        }
    }

    /// Already past the edge: no room, never a negative one.
    func testNoRoomOncePastTheEdge() throws {
        var history = steady(days: 60, load: 10)
        for index in 53..<60 { history.byDay[day(index)] = 40 }
        let room = try XCTUnwrap(LaneOutlook.headroom(dailyByDay: history.byDay, activity: history.activity,
                                                      lane: .strength, today: day(59)))
        XCTAssertEqual(room.beforeAbove, 0)
        XCTAssertEqual(room.beforeWellAbove, 0)
    }

    /// No band, no room: too few sessions, or today could not be priced.
    func testNoRoomWithoutABand() {
        let sparse = [day(0): 10.0, day(10): 10]
        let activity = LaneActivity(sessionsByDay: [day(0): 1, day(10): 1])
        XCTAssertNil(LaneOutlook.headroom(dailyByDay: sparse, activity: activity, lane: .strength, today: day(20)))
        let history = steady(days: 40, load: 10)
        XCTAssertNil(LaneOutlook.headroom(dailyByDay: history.byDay, unknownDays: [day(40)],
                                          activity: history.activity, lane: .cardio, today: day(40)))
    }

    /// Below the WHO minimum the lane is capped at "above": there is no "well above" to have room before.
    func testLowVolumeCapHasNoWellAboveRoom() throws {
        var byDay: [String: Double] = [:]
        var sessions: [String: Int] = [:]
        var minutes: [String: Double] = [:]
        for index in stride(from: 0, to: 60, by: 7) {
            byDay[day(index)] = 30
            sessions[day(index)] = 1
            minutes[day(index)] = 30
        }
        let room = try XCTUnwrap(LaneOutlook.headroom(
            dailyByDay: byDay, activity: LaneActivity(sessionsByDay: sessions, minutesByDay: minutes),
            lane: .cardio, today: day(61)))
        XCTAssertNil(room.beforeWellAbove)
    }

    // MARK: - Settling

    /// A tripled final week settles with rest: the forecast day reads about usual, the day before does
    /// not — the same readings, hysteresis included, the screen would show on those days.
    func testAHighWeekSettlesOnTheFirstUsualDay() throws {
        var history = steady(days: 70, load: 10)
        for index in 63..<70 { history.byDay[day(index)] = 30 }
        let from = day(69)
        XCTAssertEqual(LaneEngine.reading(dailyByDay: history.byDay, activity: history.activity, lane: .strength,
                                          through: from).band, .muchHigher)
        let settles = try XCTUnwrap(LaneOutlook.backToUsual(dailyByDay: history.byDay, activity: history.activity,
                                                            lane: .strength, from: from))
        XCTAssertGreaterThan(settles, from)
        let settled = LaneEngine.reading(dailyByDay: history.byDay, activity: history.activity, lane: .strength,
                                         through: settles).band
        XCTAssertTrue(settled == .usual || settled == .below)
        let dayBefore = WeeklyDigestEngine.addDays(settles, -1)
        if dayBefore > from {
            let before = LaneEngine.reading(dailyByDay: history.byDay, activity: history.activity, lane: .strength,
                                            through: dayBefore).band
            XCTAssertTrue(before == .higher || before == .muchHigher)
        }
    }

    /// A usual week has nothing to settle; a higher load settles later than a milder one.
    func testSettlingTracksHowHighTheWeekWas() throws {
        let usual = steady(days: 70, load: 10)
        XCTAssertNil(LaneOutlook.backToUsual(dailyByDay: usual.byDay, activity: usual.activity, lane: .strength,
                                             from: day(69)))
        func settling(_ load: Double) throws -> String {
            var history = steady(days: 70, load: 10)
            for index in 63..<70 { history.byDay[day(index)] = load }
            return try XCTUnwrap(LaneOutlook.backToUsual(dailyByDay: history.byDay, activity: history.activity,
                                                         lane: .strength, from: day(69)))
        }
        XCTAssertLessThanOrEqual(try settling(18), try settling(40))
    }

    // MARK: - Muscle groups

    private func workout(_ id: String, day index: Int, template: String, sets: Int) -> HevyWorkout {
        let ts = Int(ISO8601DateFormatter().date(from: day(index) + "T12:00:00Z")!.timeIntervalSince1970)
        let workingSets = (0..<sets).map {
            HevySet(index: $0, type: .normal, weightKg: 80, reps: 8, distanceM: nil, durationS: nil, rpe: 8,
                    customMetric: nil)
        }
        return HevyWorkout(id: id, title: "W", routineId: nil, notes: nil, startTs: ts, endTs: ts + 3_600,
                           updatedAtTs: ts, createdAtTs: ts,
                           exercises: [HevyExercise(index: 0, title: template, templateId: template, supersetId: nil,
                                                    notes: nil, sets: workingSets)])
    }

    /// Each group is read on its own series: a chest spike shows on chest alone, steady legs stay usual,
    /// and every band is exactly `LaneEngine`'s reading of that group's hard sets.
    func testEachMuscleGroupIsReadOnItsOwnSeries() {
        let templates = [
            "bench": HevyExerciseTemplate(id: "bench", title: "Bench", type: "weight_reps", primaryMuscleGroup: .chest,
                                          secondaryMuscleGroups: [.triceps], equipment: .barbell, isCustom: false),
            "squat": HevyExerciseTemplate(id: "squat", title: "Squat", type: "weight_reps",
                                          primaryMuscleGroup: .quadriceps, secondaryMuscleGroups: [.glutes],
                                          equipment: .barbell, isCustom: false)
        ]
        var workouts: [HevyWorkout] = []
        for index in stride(from: 0, to: 84, by: 2) {
            workouts.append(workout("b\(index)", day: index, template: "bench", sets: index >= 77 ? 12 : 4))
            workouts.append(workout("s\(index)", day: index, template: "squat", sets: 4))
        }
        let through = day(83)
        let bands = MuscleGroupLoad.bands(workouts, templates: templates, through: through)
        let series = MuscleGroupLoad.setsByGroupByDay(workouts, templates: templates)
        XCTAssertEqual(series[.chest]?[day(0)], 4)
        XCTAssertNil(series[.triceps], "secondary work is not counted, as on the Strength screen")
        for (group, byDay) in series {
            let expected = LaneEngine.reading(dailyByDay: byDay, activity: LaneActivity(sessionsByDay: byDay.mapValues { _ in 1 }),
                                              lane: .strength, through: through).band
            XCTAssertEqual(bands[group], expected, "\(group)")
        }
        XCTAssertEqual(bands[.chest], .muchHigher)
        XCTAssertEqual(bands[.quadriceps], .usual)
    }
}
