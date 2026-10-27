import XCTest
@testable import NoopCore
import StrandAnalytics
import StrandCore
import WhoopStore

final class CoreTrainingHistoryTests: XCTestCase {
    private let today = "2026-10-26"
    private var now: Int { 1793016000 } // Noon UTC on the synthetic history day.

    private func source() -> (TrainingHistoryPreparation.Source, [TrainingHistoryPreparation.LiftChoice]) {
        var resolution = TrainingCardioLoadResolution()
        var runs: [UnifiedTrainingSession] = []
        var workouts: [HevyWorkout] = []
        var ratings: [SessionRPEEntry] = []
        for back in stride(from: 58, through: 0, by: -2) {
            let start = now - back * 86_400
            let id = "run-\(back)"
            let row = WorkoutRow(startTs: start, endTs: start + 3_600, sport: "Running", source: "noop",
                durationS: 3_600, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                distanceM: 8_000, zonesJSON: nil, notes: nil, steps: nil)
            runs.append(.init(id: id, kind: .endurance, row: row,
                components: [.init(id: id, row: row, metadata: nil)], fusionOrigin: "automatic"))
            if back != 2 {
                resolution.record(.init(sessionId: id, trimp: 60, effort: 8,
                    source: back == 4 ? .averageHeartRate : .noopBand, coveredMinutes: 60, possibleMinutes: 60))
            }
            if back % 4 == 0 {
                ratings.append(.init(id: "r-\(back)", sessionId: id, startTs: start,
                    rpe: 6, sport: "Running", ratedAtTs: start + 4_000))
            }
            if back % 6 == 0 {
                let set = HevySet(index: 0, type: .normal, weightKg: 80, reps: 8,
                    distanceM: nil, durationS: nil, rpe: 8, customMetric: nil)
                workouts.append(.init(id: "lift-\(back)", title: "Push", routineId: nil, notes: nil,
                    startTs: start, endTs: start + 3_600, updatedAtTs: start, createdAtTs: start,
                    exercises: [.init(index: 0, title: "Bench press", templateId: "bench", supersetId: nil,
                        notes: nil, sets: [set])]))
            }
        }
        return TrainingHistoryPreparation.source(workouts: workouts, templates: [:], sessions: runs,
            resolution: resolution, ratings: ratings,
            vo2Estimates: [("2026-10-20", 42), ("2026-10-22", 43)], vo2Apple: [("2026-10-21", 44)],
            today: today, offset: 0)
    }

    func testThreeLanesKeepUnknownAndEstimatedDaysSeparate() throws {
        let (source, choices) = source()
        let result = CoreTrainingHistory.output(source: source, choices: choices,
            span: "threeMonths", jumpDay: nil, lifts: [])
        XCTAssertEqual(result.resolution, "day")
        XCTAssertEqual(result.cardio.count, 92)
        let missingDay = AnalyticsEngine.dayString(now - 2 * 86_400, offsetSec: 0)
        let estimateDay = AnalyticsEngine.dayString(now - 4 * 86_400, offsetSec: 0)
        let missing = try XCTUnwrap(result.cardio.first { $0.start == missingDay })
        XCTAssertNil(missing.total)
        XCTAssertEqual(missing.unknownDays, 1)
        XCTAssertNil(missing.estimatedTotal)
        let estimate = try XCTUnwrap(result.cardio.first { $0.start == estimateDay })
        XCTAssertNil(estimate.total)
        XCTAssertEqual(estimate.estimatedTotal, 60)
        XCTAssertEqual(estimate.estimatedDays, 1)
        XCTAssertGreaterThan(result.session.compactMap(\.possible).reduce(0, +),
                             result.session.compactMap(\.measured).reduce(0, +))
        XCTAssertEqual(result.lifts.map(\.id), ["bench"])
        XCTAssertTrue(result.lifts[0].values.contains { $0.value != nil })
        let lane = TrainingLoadLanes.strengthLane(workouts: source.workouts, byDay: source.strengthByDay,
                                                 through: source.strengthDay, tzOffsetSeconds: 0)
        let first = WeeklyDigestEngine.addDays(source.strengthDay, -6)
        XCTAssertEqual(result.strength.filter { $0.start >= first }.compactMap(\.total).reduce(0, +), lane.sevenDayTotal)
        XCTAssertEqual(result.strength.first { $0.start == source.strengthDay }?.band, lane.reading?.band?.rawValue)
        try contract(result)
    }

    func testSpansJumpsAndLiftChoicesHaveTheAppleBounds() {
        let (source, choices) = source()
        let future = CoreTrainingHistory.output(source: source, choices: choices,
            span: "fiveYears", jumpDay: "2030-01-01", lifts: ["bench", "bench"])
        XCTAssertEqual(future.jumpDay, today)
        XCTAssertEqual(future.last, today)
        XCTAssertEqual(future.resolution, "month")
        XCTAssertEqual(future.lifts.map(\.id), ["bench"])
        let invalid = CoreTrainingHistory.output(source: source, choices: choices,
            span: "invalid", jumpDay: "2026-02-30", lifts: ["removed"])
        XCTAssertEqual(invalid.span, "oneYear")
        XCTAssertNil(invalid.jumpDay)
        XCTAssertEqual(invalid.lifts.map(\.id), ["bench"])
        let past = CoreTrainingHistory.output(source: source, choices: choices,
            span: "all", jumpDay: "2000-01-01", lifts: [])
        XCTAssertEqual(past.jumpDay, source.earliest)
        XCTAssertEqual(past.last, today, "whole history still ends today when selecting an older period")
    }

    func testEmptyStoreDoesNotInventMeasuredRestDays() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "strap", registeredWhoopIds: [])
        let result = await CoreTrainingHistory.read(reader: reader, span: "all", jumpDay: nil, lifts: [],
            maxHR: 190, sex: "male", dismissedWorkouts: [], now: now)
        XCTAssertNil(result.earliest)
        XCTAssertEqual(result.first, result.today)
        XCTAssertEqual(result.strength.count, 1)
        for lane in [result.strength, result.cardio, result.session] {
            XCTAssertNil(lane[0].total)
            XCTAssertEqual(lane[0].knownDays, 0)
            XCTAssertEqual(lane[0].unrecordedDays, 1)
        }
    }

    func testStoreReadKeepsLongRangeAdaptationsAndDoesNotPromoteAverageHeartRate() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "strap", registeredWhoopIds: [])
        let start = now - 200 * 86_400
        let day = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(start)))
        _ = try await store.upsertWorkouts([WorkoutRow(startTs: start, endTs: start + 3_600,
            sport: "Running", source: "manual", durationS: 3_600, energyKcal: nil, avgHr: 140,
            maxHr: nil, strain: nil, distanceM: 8_000, zonesJSON: nil, notes: nil, steps: nil)], deviceId: "strap")
        _ = try await store.upsertMetricSeries([MetricPoint(day: day, key: "vo2max", value: 44)],
                                               deviceId: MetricResolver.appleHealthSource)
        _ = try await store.upsertMetricSeries([MetricPoint(day: day, key: "vo2max_est", value: 42)],
                                               deviceId: "strap-noop")
        let result = await CoreTrainingHistory.read(reader: reader, span: "oneYear", jumpDay: day,
            lifts: [], maxHR: 190, sex: "male", dismissedWorkouts: [], now: now)
        XCTAssertEqual(result.earliest, day)
        XCTAssertEqual(result.jumpDay, day)
        XCTAssertEqual(result.vo2.compactMap(\.value), [42])
        XCTAssertEqual(result.vo2Apple.compactMap(\.value), [44], "history must not inherit the 90-day hero limit")
        XCTAssertEqual(result.cardio.compactMap(\.estimatedTotal).count, 1)
        XCTAssertGreaterThan(result.cardio.compactMap(\.estimatedTotal).reduce(0, +), 0)
        XCTAssertEqual(result.cardio.compactMap(\.total).reduce(0, +), 0,
                       "a session without raw HR remains separate from measured load")
        XCTAssertEqual(result.session.compactMap(\.measured).reduce(0, +), 0)
        XCTAssertEqual(result.session.compactMap(\.possible).reduce(0, +), 1)
    }

    private func contract(_ value: CoreTrainingHistory.Output) throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let file = root.appendingPathComponent("android/app/src/test/resources/training/history.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value)
        if ProcessInfo.processInfo.environment["NOOP_UPDATE_TRAINING_FIXTURES"] == "1" { try data.write(to: file) }
        XCTAssertEqual(try JSONSerialization.jsonObject(with: data) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? NSDictionary,
                       "Kotlin tests consume the exact shared-core output, including nulls, units and bands")
    }
}
