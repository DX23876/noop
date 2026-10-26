import XCTest
@testable import NoopCore
import StrandAnalytics
import StrandCore
import WhoopStore

final class CoreTrainingReportsTests: XCTestCase {
    func testCardioKeepsMeasuredPaceSeparateFromUnmeasuredHeartRateLoad() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "strap-a", registeredWhoopIds: [])
        let now = Int(try XCTUnwrap(Calendar.current.date(from:
            DateComponents(year: 2026, month: 10, day: 26, hour: 12))).timeIntervalSince1970)
        let rows = [0, 7, 14, 21].map { back -> WorkoutRow in
            let start = now - back * 86_400 - 7_200
            return WorkoutRow(startTs: start, endTs: start + 1_800, sport: "Running", source: "manual",
                durationS: 1_800, energyKcal: 300, avgHr: 140, maxHr: 165, strain: nil,
                distanceM: 5_000, zonesJSON: nil, notes: nil, steps: 5_500)
        }
        _ = try await store.upsertWorkouts(rows, deviceId: "strap-a")
        let today = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now)))
        let daily = (0..<50).map { back in
            DailyMetric(day: WeeklyDigestEngine.addDays(today, -back), totalSleepMin: nil, efficiency: nil,
                deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                restingHr: 50, avgHrv: 70, recovery: 80, strain: 6, exerciseCount: 0, respRateBpm: 15)
        }
        _ = try await store.upsertDailyMetrics(daily, deviceId: "strap-a-noop")
        let report = await CoreTrainingReports.cardio(reader: reader, maxHR: 190, sex: "male",
            weekOffset: 5, sport: "missing", zoneSet: HRZones.zones(maxHR: 190), now: now)

        XCTAssertEqual(report.selection.weekOffset, 0)
        XCTAssertEqual(report.selection.minWeekOffset, -3)
        XCTAssertEqual(report.weekSessions, 1)
        XCTAssertEqual(report.minutes, 30)
        XCTAssertEqual(report.distanceM, 5_000)
        XCTAssertEqual(report.charge, 80, "locally computed days contribute just like imported days")
        XCTAssertEqual(report.progress.selectedSport, "Running")
        XCTAssertEqual(report.sessions.count, 4)
        XCTAssertEqual(report.sessions.first?.paceSecPerKm, 360)
        XCTAssertEqual(report.sessions.first?.beatsPerKm, 840)
        XCTAssertEqual(report.lane?.sevenDayTotal, 0, "an average-HR estimate must not become measured lane load")
        XCTAssertNil(report.zones, "zone time cannot be reconstructed from average heart rate")
        XCTAssertEqual(report.progress.paceBests.count, 1)
        XCTAssertNotEqual(CoreRead.json(report), "null")

        let older = await CoreTrainingReports.cardio(reader: reader, maxHR: 190, sex: "male",
            days: -1, weekOffset: -100, now: now)
        XCTAssertEqual(older.selection.days, 120, "unsupported windows use the Apple default")
        XCTAssertEqual(older.selection.weekOffset, -3)
        XCTAssertEqual(older.weekSessions, 1)

        let load = await CoreTrainingLoad.read(reader: reader, maxHR: 190, sex: "male",
                                               dismissedWorkoutSpans: [], now: now)
        XCTAssertEqual(load.recoveryState, "holding")
        XCTAssertGreaterThan(load.nightsRead, 0, "Training Load must read computed physiology, not only imports")
    }
    private func clock() throws -> Int {
        Int(try XCTUnwrap(Calendar.current.date(from:
            DateComponents(year: 2026, month: 10, day: 26, hour: 12))).timeIntervalSince1970)
    }

    func testSpeedTrendUsesTheSameUnitsAsTheCyclingChart() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "strap-a", registeredWhoopIds: [])
        let now = try clock()
        let rows = (0..<5).map { back in
            WorkoutRow(startTs: now - back * 7 * 86_400 - 7_200, endTs: now - back * 7 * 86_400 - 3_600,
                sport: "Cycling", source: "manual", durationS: 3_600, energyKcal: nil, avgHr: 130, maxHr: nil,
                strain: nil, distanceM: Double(30 - back * 2) * 1_000, zonesJSON: nil, notes: nil, steps: nil)
        }
        _ = try await store.upsertWorkouts(rows, deviceId: "strap-a")
        let report = await CoreTrainingReports.cardio(reader: reader, maxHR: 190, sex: "male", now: now)
        XCTAssertEqual(report.progress.modality, "cycling")
        XCTAssertEqual(report.progress.metric, "speed")
        XCTAssertEqual(report.progress.pace.compactMap(\.value), [22, 24, 26, 28, 30])
        XCTAssertEqual(try XCTUnwrap(report.progress.paceTrend).slopePerWeek, 2, accuracy: 0.001)
        XCTAssertNil(report.zones, "neither speed nor average HR supplies zone minutes")
        try contract(report, name: "cardio")
        var withZones = report
        withZones.zones = CoreTrainingReports.Zones(.init(minutes: [10, 15, 5, 0, 0],
            sessionsRead: 1, sessionsPossible: 2, usedMinuteBuckets: true))
        try contract(withZones, name: "cardio-zones")
    }

    func testManualDetailsReopenAndReplaceInsteadOfDuplicatingTheEnvelope() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "strap-a", registeredWhoopIds: [])
        let now = try clock()
        let row = WorkoutRow(startTs: now - 7_200, endTs: now - 3_600, sport: "Functional strength training",
            source: "apple-health", durationS: 1_800, energyKcal: 260, avgHr: 118, maxHr: 157,
            strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        _ = try await store.upsertWorkouts([row], deviceId: "strap-a")
        let first = await CoreTrainingReports.strength(reader: reader, now: now)
        let session = try XCTUnwrap(first.genericSessions.first)
        XCTAssertEqual(first.genericSessions.count, 1)
        XCTAssertTrue(session.drafts.isEmpty)
        var draft: [String: Any] = ["title": "Bench press", "workSets": 4, "muscle": "chest", "effort": "1,5", "usesRIR": true]
        let saved = await CoreTrainingReports.saveDetails(reader: reader, sessionId: session.id,
            drafts: [draft], dismissedWorkouts: [], now: now)
        XCTAssertEqual(saved, "saved")
        var reopened = await CoreTrainingReports.strength(reader: reader, now: now)
        XCTAssertEqual(reopened.genericSessions.count, 1)
        XCTAssertEqual(reopened.genericSessions.first?.drafts.first?.workSets, 4)
        XCTAssertFalse(try XCTUnwrap(reopened.genericSessions.first?.drafts.first?.usesRIR))
        XCTAssertEqual(reopened.recentSessions.first?.exercises.first?.sets.first?.rpe, 8.5)
        draft["workSets"] = 5
        let edited = await CoreTrainingReports.saveDetails(reader: reader, sessionId: reopened.genericSessions[0].id,
            drafts: [draft], dismissedWorkouts: [], now: now)
        XCTAssertEqual(edited, "saved")
        reopened = await CoreTrainingReports.strength(reader: reader, now: now)
        XCTAssertEqual(reopened.recentSessions.count, 1)
        XCTAssertEqual(reopened.workingSets, 5)
        XCTAssertEqual(reopened.recentSessions.first?.startTs, row.startTs)
        XCTAssertEqual(reopened.recentSessions.first?.durationS, row.durationS)
        try contract(reopened, name: "strength-details")
        let byId = await CoreTrainingReports.session(reader: reader, id: reopened.recentSessions[0].id, now: now)
        XCTAssertEqual(byId?.source, "manual")
        draft["effort"] = "12"
        let invalid = await CoreTrainingReports.saveDetails(reader: reader, sessionId: session.id,
            drafts: [draft], dismissedWorkouts: [], now: now)
        XCTAssertEqual(invalid, "invalidEffort")
        draft["effort"] = "1"; draft["workSets"] = -1
        let invalidSets = await CoreTrainingReports.saveDetails(reader: reader, sessionId: session.id,
            drafts: [draft], dismissedWorkouts: [], now: now)
        XCTAssertEqual(invalidSets, "invalidSets")
        let unchanged = await CoreTrainingReports.strength(reader: reader, now: now)
        XCTAssertEqual(unchanged.workingSets, 5, "invalid forms do not partially replace the workout")
        let missing = await CoreTrainingReports.saveDetails(reader: reader, sessionId: "not-a-session",
            drafts: [draft], dismissedWorkouts: [], now: now)
        XCTAssertEqual(missing, "sessionUnavailable")
    }

    func testAWithheldComparisonHasNeitherAPercentageNorACurve() {
        let day = "2026-10-26"
        let values = Dictionary(uniqueKeysWithValues: (0..<56).map {
            (WeeklyDigestEngine.addDays(day, -$0), 1.0)
        })
        let lane = TrainingLoadLanes.strengthLane(workouts: [], byDay: values, through: day, tzOffsetSeconds: 0)
        XCTAssertEqual(lane.reading?.guardState, .tooFewSessions)
        XCTAssertNotNil(lane.reading?.trend, "raw relative math alone does not establish enough comparable sessions")
        XCTAssertNil(lane.trend)
        XCTAssertNil(CoreTrainingLoad.Lane(lane).percent)
        let ratios = TrainingLoadLanes.ratios(strengthByDay: values, strengthActivity: LaneActivity.none, cardio: nil, through: day)
        XCTAssertTrue(ratios.allSatisfy { $0.strength == nil })
    }

    func testAllHistoryCanSelectAWeekMoreThanTenYearsAgo() throws {
        let selection = CoreTrainingReports.Selection(days: TrainingHistoryWindow.allDays, requestedOffset: -800,
            earliestDay: "2008-01-01", now: try clock())
        XCTAssertLessThan(selection.minWeekOffset, -800)
        XCTAssertEqual(selection.weekOffset, -800)
    }

    func testMappingAndFeedbackPersistThroughTheSharedStore() async throws {
        let store = try await WhoopStore.inMemory()
        let saved = await CoreTrainingReports.saveMapping(store: store, title: "Cable row", primary: "lats",
            secondary: ["biceps", "lats", "biceps"])
        XCTAssertTrue(saved)
        let mappings = try await store.strengthExerciseMappings()
        let row = try XCTUnwrap(mappings.values.first)
        XCTAssertEqual(row.primaryMuscleGroup, .lats)
        XCTAssertEqual(row.secondaryMuscleGroups, [.biceps])
        let aliases = try await store.trainingExerciseAnatomyAliases()
        XCTAssertEqual(aliases.count, 1, "the native anatomy catalog learns the same assignment")
        let invalid = await CoreTrainingReports.saveMapping(store: store, title: "Unknown", primary: "typo", secondary: [])
        XCTAssertFalse(invalid)
        let feedback = await CoreTrainingReports.recordFeedback(store: store, muscle: "lats", feeling: 2, now: 100)
        XCTAssertTrue(feedback)
        let invalidFeedback = await CoreTrainingReports.recordFeedback(store: store, muscle: "lats", feeling: 7, now: 101)
        XCTAssertFalse(invalidFeedback)
        let observations = try await store.muscleRecoveryFeedback()
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations.first?.feeling, 2)
        XCTAssertEqual(observations.first?.ts, 100)
    }

    func testStrengthContractIncludesSetPhasesAndRatedCoverage() async throws {
        let store = try await WhoopStore.inMemory()
        let reader = StoreReader(store: store, activeDeviceId: "strap-a", registeredWhoopIds: [])
        let now = try clock()
        let template = HevyExerciseTemplate(id: "bench", title: "Bench press", type: "weight_reps",
            primaryMuscleGroup: .chest, secondaryMuscleGroups: [.triceps], equipment: .barbell, isCustom: true)
        _ = try await store.upsertHevyExerciseTemplates([template])
        let workouts = (0..<5).map { back -> HevyWorkout in
            let start = now - back * 7 * 86_400 - 7_200
            return HevyWorkout(id: "bench-\(back)", title: "Push day", routineId: nil, notes: nil,
                startTs: start, endTs: start + 3_600, updatedAtTs: start, createdAtTs: start,
                exercises: [HevyExercise(index: 0, title: "Bench press", templateId: "bench", supersetId: nil, notes: nil,
                    sets: [HevySet(index: 0, type: .warmup, weightKg: 20, reps: 10, distanceM: nil, durationS: nil, rpe: nil, customMetric: nil),
                           HevySet(index: 1, type: .normal, weightKg: Double(80 - back * 2), reps: 8,
                                   distanceM: nil, durationS: nil, rpe: 8, customMetric: nil)])], source: .hevyCSV)
        }
        _ = try await store.upsertStrengthWorkouts(workouts)
        let report = await CoreTrainingReports.strength(reader: reader, now: now)
        XCTAssertEqual(report.workingSets, 1, "warmups are displayed but do not inflate the total")
        XCTAssertEqual(report.volumeSets, 1)
        XCTAssertEqual(report.overview.workingSets, 5)
        XCTAssertEqual(report.selection.minWeekOffset, -4, "imported set logs also bound the week picker")
        XCTAssertEqual(report.recentSessions.first?.source, "hevy_csv")
        XCTAssertEqual(report.recentSessions.first?.exercises.first?.sets.map(\.countsAsWork), [false, true])
        XCTAssertNotNil(report.exercise.trend)
        XCTAssertEqual(report.exercise.choices.first?.sessions, 5)
        try contract(report, name: "strength")
    }

    /// The actual encoded Swift documents are the Kotlin parser's fixtures. Values in the fixture are
    /// synthetic; the test pins their field/type contract while store tests above pin the calculations.
    private func contract<T: Encodable>(_ value: T, name: String) throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let dir = root.appendingPathComponent("android/app/src/test/resources/training")
        let path = dir.appendingPathComponent("\(name).json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value)
        if ProcessInfo.processInfo.environment["NOOP_UPDATE_TRAINING_FIXTURES"] == "1" {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: path)
        }
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: path))
        let actual = try JSONSerialization.jsonObject(with: data)
        func shape(_ object: Any) -> String {
            if let dict = object as? [String: Any] {
                return "{" + dict.keys.sorted().map { "\($0):\(shape(dict[$0]!))" }.joined(separator: ",") + "}"
            }
            if let array = object as? [Any] { return "[" + Set(array.map(shape)).sorted().joined(separator: ",") + "]" }
            if object is NSNumber { return "number" }
            if object is String { return "string" }
            return "null"
        }
        XCTAssertEqual(shape(actual), shape(expected), "Swift/Kotlin response contract drifted; regenerate and review both fixtures")
    }

}
