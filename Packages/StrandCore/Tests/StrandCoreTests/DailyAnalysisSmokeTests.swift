import XCTest
import StrandAnalytics
@testable import StrandCore
import WhoopProtocol
import WhoopStore

/// The whole daily pass runs inside StrandCore against a real store, with platform services reduced to what a
/// store alone can answer. On Android this is the proof that the engine runs there, not only that it builds.
@MainActor
final class DailyAnalysisSmokeTests: XCTestCase {
    private final class StoreServices: AnalysisDataServices {
        let reader: StoreReader
        var days: [DailyMetric] = []
        private(set) var refreshes = 0
        private(set) var cardioRecomputes = 0
        private(set) var energyRefreshDays: [Int] = []

        init(reader: StoreReader) { self.reader = reader }

        /// Runs once, inside the next `storeHandle` call (the first read of a pass), then clears itself.
        var onStoreHandle: (@MainActor () -> Void)?
        private(set) var storeHandleCalls = 0
        func storeHandle() async -> WhoopStore? {
            storeHandleCalls += 1
            if let hook = onStoreHandle { onStoreHandle = nil; hook() }
            return reader.store
        }
        func refresh(days nDays: Int) async { refreshes += 1 }
        func dailyMetrics(fromDay: String, toDay: String) async -> [DailyMetric] {
            await reader.unionDailyMetrics(from: fromDay, to: toDay)
        }
        func fillCardioLoadLedger() async {}
        func recomputeCardioLoadHistory() async { cardioRecomputes += 1 }
        func energyPeakMETByDay(fromDay: String, toDay: String) async -> [String: Double] { [:] }
        func workoutRows(days: Int, reconcileHrCap: Int?) async -> [WorkoutRow] {
            let now = Int(Date().timeIntervalSince1970)
            return await reader.rawWorkoutRows(from: now - days * 86_400, to: now + 86_400, dismissedDetectedSpans: [])
        }
        func selfHealEditedStages(from windowStart: Int, to windowEnd: Int, unchangedDays: Set<String>,
                                  tzOffsetSeconds: Int) async -> [CachedSleepSession] { [] }
        func resolvedSteps(from: String, to: String) async -> MetricSeriesResolution {
            await MetricResolver.resolvedSteps(store: reader.store, actualWhoopSource: reader.activeDeviceId,
                                               from: from, to: to)
        }
        func refreshWhoopEnergyModel(days: Int, profile: UserProfile) async -> Bool {
            energyRefreshDays.append(days)
            return true
        }
        func noteEnergyInputsRederived(dayStartTs: Int) async {}
        func fillRecordedWorkoutHeartRate(from: Int, to: Int) async throws -> Int { 0 }
        func fillAppleWorkoutHeartRate(from: Int, to: Int) async throws -> Int { 0 }
        func ensureEnergyHistoryCurrent(profile: UserProfile, waitIfRunning: Bool) async {}
        func dismissedSleepWindows() -> [(start: Int, end: Int)] { [] }
        var dismissedWorkoutSpans: [String] = []
        func rawWorkoutRows(from lo: Int, to hi: Int) async -> [WorkoutRow] {
            await reader.rawWorkoutRows(from: lo, to: hi, dismissedDetectedSpans: dismissedWorkoutSpans)
        }
        func dismissedDetectedWorkoutWindows() -> [Range<Int>] { WorkoutSource.dismissedWindows(dismissedWorkoutSpans) }
        func correctLegacyWorkoutEnergy(profile base: UserProfile) async throws -> Int? { nil }
        func bodyMetrics(days: Int) async -> BodyMetrics {
            await BodyMetricsReader.read(reader: reader, activeDeviceId: reader.activeDeviceId, days: days)
        }
        func weightSeries(days: Int) async -> [WeightPoint] {
            await WeightSeries.series(reader: reader, from: "0000-01-01", to: "9999-12-31")
        }
        func agelessLongSessions(days: Int) async -> [HealthspanVO2.LongSession] { [] }
        func trainingSessions(from lo: Int, to hi: Int) async -> TrainingSessionFusionResult {
            TrainingSessionResolver.resolve(rows: [], metadata: [], links: [], preferences: [])
        }
    }

    private final class Profile: AnalysisProfileSource {
        var age = 35
        var sex = "male"
        var weightKg = 80.0
        var heightCm = 180.0
        var waistCm = 0.0
        var hrMaxOverride = 0
        var hrMax: Int { 190 }
        var stepTicksPerStep = 1.0
        var stepsManualOverride: Double? { nil }
        var stepsCalibrationCoefficient = 0.0
        var stepsCalibrationSampleDays = 0
        var stepsCalibrationConfidence = 0.0
        var stepsCalibrationManual = false
        var stepsHasBankedMotion = false
        func analyticsProfile() -> UserProfile {
            UserProfile(weightKg: weightKg, heightCm: heightCm, age: Double(age), sex: sex)
        }
        func enteredVO2max() -> (day: String, value: Double)? { nil }
    }

    @MainActor
    private final class Host: AnalysisHost {
        var lines: [String] = []
        var bools: [String: Bool] = [:]
        var strings: [String: String] = [:]
        var sleepStagerMethod: SleepStager.Method = .v1
        var dayCycleMode: DayCycleMode = .persisted(nil)
        var traces: Set<TestDomain> = []
        func analysisSettings() -> AnalysisSettings {
            AnalysisSettings(spo2CandidateDisplay: false, sleepStagerV2: false,
                             motionAwareWake: false, deepHrvWindow: false, dayCycleMode: dayCycleMode,
                             rhythmAge: false, healthspan: false, hrvBaselineEpoch: 0, recoveryBaselineEpoch: 0,
                             traces: traces, sleepStagerMethod: sleepStagerMethod)
        }
        func diagnostic(_ line: String, domain: TestDomain?) { lines.append(line) }
        func storedBool(_ key: String) -> Bool { bools[key] ?? false }
        func storedString(_ key: String) -> String? { strings[key] }
        func store(_ value: Bool, forKey key: String) { bools[key] = value }
        func store(_ value: String?, forKey key: String) { strings[key] = value }
        func store(_ value: Double, forKey key: String) {}
        func passWillStart() -> AnalysisPassTicket {
            AnalysisPassTicket(owedToken: nil, cpuSecondsAtStart: nil, assertionExpiriesAtStart: 0)
        }
        func passDidFinish(_ ticket: AnalysisPassTicket, elapsedSeconds: Double) -> AnalysisPassReport {
            AnalysisPassReport(settled: true, costLine: "re-score: cost test")
        }
        nonisolated func paceIfBackgrounded(since mark: inout UInt64) async {}
        func costReading() -> (cpuSeconds: Double?, batteryPercent: Int?) { (nil, nil) }
    }

    func testAPassOverAStoreWithNoHeartRateFinishesWithNothingScored() async throws {
        let store = try await WhoopStore.inMemory()
        let services = StoreServices(reader: StoreReader(store: store, activeDeviceId: "my-whoop",
                                                         registeredWhoopIds: []))
        let host = Host()
        let engine = DailyAnalysis(services: services, profile: Profile(), deviceId: "my-whoop", host: host,
                                   messages: { "\($0)" })

        await engine.analyzeRecent(maxDays: 3, force: true, allowDayReuse: false)

        XCTAssertTrue(engine.results.isEmpty)
        XCTAssertFalse(engine.computing)
        XCTAssertNil(engine.analysisProgress, "progress is cleared on every exit")
        XCTAssertNotNil(engine.note, "a pass with nothing to score says so")
    }

    private func dayKey(_ daysAgo: Int) -> String {
        StoreReader.localDayKey(Date().addingTimeInterval(-Double(daysAgo) * 86_400))
    }

    func testSwitchingSleepMethodInvalidatesPersistedDayReuseInBothDirections() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "my-whoop"
        let yesterday = Calendar.current.date(byAdding: .day, value: -1,
                                              to: Calendar.current.startOfDay(for: Date()))!
        let start = Int(yesterday.timeIntervalSince1970)
        let day = StoreReader.localDayKey(yesterday)
        let end = start + 8 * 3_600
        let hr = stride(from: start - 24 * 3_600, to: end, by: 60).map {
            HRSample(ts: $0, bpm: $0 < start ? 70 : 50)
        }
        let gravity = stride(from: start, to: end, by: 60).map {
            GravitySample(ts: $0, x: 0, y: 0, z: 1)
        }
        try await store.insert(Streams(hr: hr, gravity: gravity), deviceId: deviceId)
        let services = StoreServices(reader: StoreReader(store: store, activeDeviceId: deviceId,
                                                         registeredWhoopIds: []))
        let host = Host()
        host.sleepStagerMethod = .v2
        let engine = DailyAnalysis(services: services, profile: Profile(), deviceId: deviceId,
                                   host: host, messages: { "\($0)" })

        await engine.analyzeRecent(maxDays: 2, force: true, allowDayReuse: true)
        let originalRows = try await store.dayScanFingerprints(deviceId: deviceId + "-noop",
                                                              from: day, to: day)
        let original = try XCTUnwrap(originalRows[day], "The real pass must persist a reusable day")
        let originalSignature = try XCTUnwrap(original.semanticSignature)

        // No raw, profile, recipe or calendar input changes between these passes. The persisted
        // semantic fingerprint must prevent the previous method's result from being reused.
        for method in [SleepStager.Method.v3, .v2] {
            host.sleepStagerMethod = method
            host.lines.removeAll()
            await engine.analyzeRecent(maxDays: 2, force: true, allowDayReuse: true)
            let rows = try await store.dayScanFingerprints(deviceId: deviceId + "-noop", from: day, to: day)
            let updated = try XCTUnwrap(rows[day])
            XCTAssertEqual(updated.inputRevision, original.inputRevision)
            XCTAssertEqual(updated.deviceRevision, original.deviceRevision)
            let signature = try XCTUnwrap(updated.semanticSignature)
            if method == .v3 {
                XCTAssertNotEqual(signature, originalSignature)
            } else {
                XCTAssertEqual(signature, originalSignature)
            }
            XCTAssertTrue(host.lines.contains {
                $0.hasPrefix("reuse day=\(day) reuse=false miss=") && $0.contains("semanticSignature")
            }, "A method switch must recompute the stored day even when reuse is allowed: \(host.lines)")
            XCTAssertTrue(host.lines.contains {
                $0.hasPrefix("reuse semantic diff") && $0.contains("sleepMethod:")
            }, "The cache miss must be attributed to the pipeline method")
        }
    }

    /// A store one recipe behind runs the whole rebuild: every step once, the weekly scores for every week
    /// the raw history covers, the stress proxy over the history, and only then both cursors.
    func testAMigrationRunsTheRebuildAndMovesTheRecipeLast() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.setCursor(AnalysisRecipe.cursor, AnalysisRecipe.currentVersion - 1)
        // A few raw samples 20 days back mark where the raw history begins (too few to score a day).
        let rawStart = Int(Date().timeIntervalSince1970) - 20 * 86_400
        try await store.insert(Streams(hr: (0..<10).map { HRSample(ts: rawStart + $0 * 60, bpm: 60) }),
                               deviceId: "my-whoop")
        // Three weeks of computed days with a slowly moving resting rate and HRV.
        let rows = (0...21).map { ago in
            DailyMetric(day: dayKey(ago), totalSleepMin: 420 + Double(ago % 3) * 10, efficiency: nil,
                        deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                        restingHr: 52 + ago % 4, avgHrv: 60 + Double(ago % 5), recovery: nil, strain: nil,
                        exerciseCount: nil)
        }
        _ = try await store.upsertDailyMetrics(rows, deviceId: "my-whoop-noop")
        let services = StoreServices(reader: StoreReader(store: store, activeDeviceId: "my-whoop",
                                                         registeredWhoopIds: []))
        let host = Host()
        let engine = DailyAnalysis(services: services, profile: Profile(), deviceId: "my-whoop", host: host,
                                   messages: { "\($0)" })

        let ok = await engine.prepareAnalysisRecipe()

        XCTAssertTrue(ok)
        // The cost of a rebuild is logged: where it started, every step, the whole run.
        let label = AnalysisRecipe.label(AnalysisRecipe.currentVersion)
        let rebuildLines = host.lines.filter { $0.hasPrefix("rebuild \(label): ") }
        XCTAssertTrue(rebuildLines.first?.contains("start from") ?? false, rebuildLines.first ?? "no lines")
        XCTAssertEqual(rebuildLines.filter { $0.contains(" done, ") }.count,
                       AnalysisRecipe.RebuildStep.allCases.count)
        XCTAssertTrue(rebuildLines.last?.contains("finished, ") ?? false)
        let recipe = try await store.cursor(AnalysisRecipe.cursor)
        let position = try await store.cursor(AnalysisRecipe.rebuildCursor)
        XCTAssertEqual(recipe, AnalysisRecipe.currentVersion)
        XCTAssertEqual(position, AnalysisRecipe.rebuildPosition(target: AnalysisRecipe.currentVersion,
                                                                after: .publish))
        XCTAssertEqual(services.cardioRecomputes, 1)
        XCTAssertEqual(services.energyRefreshDays, [21], "21 days of raw history price the standard window")
        let vitality = try await store.metricSeries(deviceId: "my-whoop-noop", key: "vitality",
                                                    from: "0000-01-01", to: "9999-12-31")
        var expected: [String] = []
        var saturday = DailyAnalysis.saturdayKey(onOrBefore: dayKey(20))
        while saturday <= dayKey(0) {
            expected.append(saturday)
            saturday = WeeklyDigestEngine.addDays(saturday, 7)
        }
        XCTAssertEqual(vitality.map(\.day), expected, "one weekly row per week the raw history covers")
        let stress = try await store.metricSeries(deviceId: MetricResolver.whoopSource, key: "stress",
                                                  from: "0000-01-01", to: "9999-12-31")
        XCTAssertEqual(stress.count, rows.count - 1, "every day after the first has a stress reading")
    }

    /// A rebuild interrupted after its energy step resumes with the one step still owed.
    func testAnInterruptedRebuildRunsOnlyTheStepsStillOwed() async throws {
        let store = try await WhoopStore.inMemory()
        let target = AnalysisRecipe.currentVersion
        try await store.setCursor(AnalysisRecipe.cursor, target - 1)
        try await store.setCursor(AnalysisRecipe.rebuildCursor,
                                  AnalysisRecipe.rebuildPosition(target: target, after: .energyHistory))
        let services = StoreServices(reader: StoreReader(store: store, activeDeviceId: "my-whoop",
                                                         registeredWhoopIds: []))
        let engine = DailyAnalysis(services: services, profile: Profile(), deviceId: "my-whoop", host: Host(),
                                   messages: { "\($0)" })

        let ok = await engine.prepareAnalysisRecipe()

        XCTAssertTrue(ok)
        XCTAssertEqual(services.cardioRecomputes, 0)
        XCTAssertTrue(services.energyRefreshDays.isEmpty)
        XCTAssertEqual(services.refreshes, 1, "only the publish step ran")
        let recipe = try await store.cursor(AnalysisRecipe.cursor)
        XCTAssertEqual(recipe, target)
    }

    // MARK: - Effort's workout time (#2438)

    /// Yesterday as the smoke tests above build it (a night at 50 bpm after a day at 70), then a still day at
    /// 70 once a minute. `walk` adds a detected bout at 15:00: a 15-minute warm-up at 100 bpm (below 50 % HRR)
    /// and 20 minutes at 155, both moving, once a second. `lowHour` adds an hour at 100 bpm sitting still from
    /// 18:00, once a second, which no detector takes for a workout.
    private func seedYesterday(_ store: WhoopStore, walk: Bool, lowHour: Bool) async throws -> (start: Int, day: String) {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
        let start = Int(yesterday.timeIntervalSince1970)
        let walkStart = start + 15 * 3_600, walkEnd = walkStart + 35 * 60
        let lowStart = start + 18 * 3_600, lowEnd = lowStart + 3_600
        var hr = stride(from: start - 24 * 3_600, to: start + 22 * 3_600, by: 60).filter {
            !(walk && $0 >= walkStart && $0 < walkEnd) && !(lowHour && $0 >= lowStart && $0 < lowEnd)
        }.map { HRSample(ts: $0, bpm: $0 < start || $0 >= start + 8 * 3_600 ? 70 : 50) }
        var gravity = hr.filter { $0.ts >= start }.map { GravitySample(ts: $0.ts, x: 0, y: 0, z: 1) }
        if walk {
            for t in walkStart ..< walkEnd {
                hr.append(HRSample(ts: t, bpm: t < walkStart + 15 * 60 ? 100 : 155))
                gravity.append(GravitySample(ts: t, x: Double(t % 2) * 0.5, y: 0, z: 1))
            }
        }
        if lowHour {
            for t in lowStart ..< lowEnd {
                hr.append(HRSample(ts: t, bpm: 100))
                gravity.append(GravitySample(ts: t, x: 0, y: 0, z: 1))
            }
        }
        try await store.insert(Streams(hr: hr.sorted { $0.ts < $1.ts }, gravity: gravity.sorted { $0.ts < $1.ts }),
                               deviceId: "my-whoop")
        return (start, StoreReader.localDayKey(yesterday))
    }

    private func storedEffort(_ store: WhoopStore, _ day: String) async throws -> Double {
        let row = try await store.dailyMetrics(deviceId: "my-whoop-noop", from: day, to: day).first
        return try XCTUnwrap(row?.strain)
    }

    private func workout(_ start: Int, _ end: Int, sport: String, source: String) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: source, durationS: Double(end - start),
                   energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil,
                   notes: nil, steps: nil)
    }

    /// The stored day and `LiveEffort` read one resolver, the union the Workouts list shows: an activity file,
    /// a lifting session and a retained strap's recording count, a dismissed detected row does not.
    func testEffortWorkoutTimeIsTheUnionTheWorkoutsListShows() async throws {
        let store = try await WhoopStore.inMemory()
        let services = StoreServices(reader: StoreReader(store: store, activeDeviceId: "new-mg",
                                                         registeredWhoopIds: ["new-mg", "old-five"]))
        let t = Int(Date().timeIntervalSince1970) - 10 * 3_600
        _ = try await store.upsertWorkouts([workout(t, t + 600, sport: "Walking", source: "activity-file")],
                                           deviceId: "activity-file")
        _ = try await store.upsertWorkouts([workout(t + 1_000, t + 1_600, sport: "Squat", source: "lifting")],
                                           deviceId: "lifting")
        _ = try await store.upsertWorkouts([workout(t + 2_000, t + 2_600, sport: "Running", source: "manual")],
                                           deviceId: "old-five")
        _ = try await store.upsertWorkouts([workout(t + 3_000, t + 3_600, sport: "detected", source: "my-whoop-noop")],
                                           deviceId: "my-whoop-noop")
        services.dismissedWorkoutSpans = ["\(t + 3_000):\(t + 3_600)"]

        let spans = await DailyAnalysis.effortWorkoutSpans(services: services, from: t - 60, to: t + 4_000)

        XCTAssertEqual(Set(spans.map(\.lowerBound)), [t, t + 1_000, t + 2_000])
    }

    /// A workout imported after its day was scored reaches that day's stored Effort: the pass reads it
    /// (the activity-file namespace was never read for the stored day) and the day's signature sees it, so a
    /// pass allowed to reuse days re-derives this one instead of keeping the old Effort.
    func testAWorkoutImportedLaterReachesTheStoredDay() async throws {
        let store = try await WhoopStore.inMemory()
        let (start, day) = try await seedYesterday(store, walk: false, lowHour: true)
        let services = StoreServices(reader: StoreReader(store: store, activeDeviceId: "my-whoop",
                                                         registeredWhoopIds: []))
        let host = Host()
        host.dayCycleMode = .midnight
        let engine = DailyAnalysis(services: services, profile: Profile(), deviceId: "my-whoop", host: host,
                                   messages: { "\($0)" })
        await engine.analyzeRecent(maxDays: 2, force: true, allowDayReuse: true)
        let before = try await storedEffort(store, day)

        let lowStart = start + 18 * 3_600
        _ = try await store.upsertWorkouts([workout(lowStart, lowStart + 3_600, sport: "Walking",
                                                    source: "activity-file")], deviceId: "activity-file")
        host.lines.removeAll()
        await engine.analyzeRecent(maxDays: 2, force: true, allowDayReuse: true)

        let after = try await storedEffort(store, day)
        XCTAssertGreaterThan(after, before,
                             "the hour below 50 % HRR counts once it is workout time")
        XCTAssertTrue(host.lines.contains {
            $0.hasPrefix("reuse day=\(day) reuse=false miss=") && $0.contains("semanticSignature")
        }, "the import must re-derive the day, not reuse it: \(host.lines)")
    }

    /// The Workouts test mode writes one shadow line per bout of the day, scored against the wearer's own
    /// entries; a confirmed suggestion is not ground truth, a hand-logged session is. Off, nothing is written.
    func testShadowLinesScoreEachBoutAgainstTheWearersOwnEntries() async throws {
        let store = try await WhoopStore.inMemory()
        let (start, day) = try await seedYesterday(store, walk: true, lowHour: false)
        let services = StoreServices(reader: StoreReader(store: store, activeDeviceId: "my-whoop",
                                                         registeredWhoopIds: []))
        let host = Host()
        host.dayCycleMode = .midnight
        let engine = DailyAnalysis(services: services, profile: Profile(), deviceId: "my-whoop", host: host,
                                   messages: { "\($0)" })
        let walkStart = start + 15 * 3_600
        let shadow = { host.lines.filter { $0.hasPrefix("activityShadow day=\(day) track=dayBout rule=v0") } }

        await engine.analyzeRecent(maxDays: 2, force: true, allowDayReuse: false)
        XCTAssertTrue(shadow().isEmpty, "the test mode is off")

        host.traces = [.workouts]
        _ = try await store.upsertWorkouts([workout(walkStart, walkStart + 35 * 60, sport: "Walking",
                                                    source: WorkoutSource.confirmedSuggestionSource)],
                                           deviceId: "my-whoop")
        host.lines.removeAll()
        await engine.analyzeRecent(maxDays: 2, force: true, allowDayReuse: false)
        XCTAssertFalse(shadow().isEmpty, "got \(host.lines.filter { $0.hasPrefix("activityShadow") })")
        XCTAssertTrue(shadow().allSatisfy { $0.hasSuffix("result=unlabelled") },
                      "a confirmed suggestion is not an entry: \(shadow())")

        _ = try await store.upsertWorkouts([workout(walkStart, walkStart + 35 * 60, sport: "Walking",
                                                    source: "manual")], deviceId: "my-whoop")
        host.lines.removeAll()
        await engine.analyzeRecent(maxDays: 2, force: true, allowDayReuse: false)
        XCTAssertTrue(shadow().contains { $0.hasSuffix("result=matched kind=walk") }, "got \(shadow())")
    }

    /// The activity refresh stores what the full pass stores from the same streams, detected bout included,
    /// and a dismissed bout leaves both. It never lowers the value already stored for the day.
    func testTheActivityRefreshScoresTheDayAsTheFullPassDoes() async throws {
        let store = try await WhoopStore.inMemory()
        let (start, day) = try await seedYesterday(store, walk: true, lowHour: false)
        let services = StoreServices(reader: StoreReader(store: store, activeDeviceId: "my-whoop",
                                                         registeredWhoopIds: []))
        let host = Host()
        host.dayCycleMode = .midnight
        let engine = DailyAnalysis(services: services, profile: Profile(), deviceId: "my-whoop", host: host,
                                   messages: { "\($0)" })
        let lateThatDay = Date(timeIntervalSince1970: TimeInterval(start + 23 * 3_600))

        await engine.analyzeRecent(maxDays: 2, force: true, allowDayReuse: false)
        let passed = try await storedEffort(store, day)
        // Clear the stored value so the refresh's own score is what lands.
        _ = try await store.updateDailyStrains([(day: day, strain: 0)], deviceId: "my-whoop-noop")
        _ = await engine.refreshCurrentDayActivity(now: lateThatDay)
        let refreshed = try await storedEffort(store, day)
        XCTAssertEqual(refreshed, passed, accuracy: 1e-9,
                       "the refresh counts the warm-up inside the detected bout, as the pass does")

        services.dismissedWorkoutSpans = ["\(start + 15 * 3_600):\(start + 15 * 3_600 + 60)"]
        await engine.analyzeRecent(maxDays: 2, force: true, allowDayReuse: false)
        let dismissed = try await storedEffort(store, day)
        XCTAssertLessThan(dismissed, passed, "a dismissed bout's warm-up is not workout time")
        _ = try await store.updateDailyStrains([(day: day, strain: 0)], deviceId: "my-whoop-noop")
        _ = await engine.refreshCurrentDayActivity(now: lateThatDay)
        let refreshedDismissed = try await storedEffort(store, day)
        XCTAssertEqual(refreshedDismissed, dismissed, accuracy: 1e-9)

        _ = try await store.updateDailyStrains([(day: day, strain: dismissed + 5)], deviceId: "my-whoop-noop")
        _ = await engine.refreshCurrentDayActivity(now: lateThatDay)
        let floored = try await storedEffort(store, day)
        XCTAssertEqual(floored, dismissed + 5, accuracy: 1e-9,
                       "the refresh never lowers the stored value; the next full pass decides")
    }

    // MARK: - Rebuild

    /// The daily step returns only once the heal re-pass a pass queued for itself has finished. The queue
    /// resumes a pass's waiters and starts the queued re-pass in one synchronous stretch, so a check for a
    /// queued request after `analyzeRecent` returned found none and the later steps ran beside the re-pass.
    func testTheDailyHistoryStepWaitsForTheHealRepass() async throws {
        let store = try await WhoopStore.inMemory()
        let services = StoreServices(reader: StoreReader(store: store, activeDeviceId: "my-whoop",
                                                         registeredWhoopIds: []))
        let engine = DailyAnalysis(services: services, profile: Profile(), deviceId: "my-whoop", host: Host(),
                                   messages: { "\($0)" })
        // The first pass queues a follow-up while it runs, as the #899 heal does.
        services.onStoreHandle = { [weak engine] in engine?.enqueueFollowup(maxDays: 3, reason: .semanticChange) }

        try await engine.runDailyHistoryPass(days: 3)

        XCTAssertGreaterThanOrEqual(services.storeHandleCalls, 2, "the step's pass and the queued re-pass both ran")
        XCTAssertFalse(engine.computing, "no pass is still running when the step returns")
    }
}
