import XCTest
import StrandAnalytics
import StrandCore
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

        func storeHandle() async -> WhoopStore? { reader.store }
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
        func correctLegacyWorkoutEnergy(profile base: UserProfile) async throws -> Int? { nil }
        func bodyMetrics(days: Int) async -> BodyMetrics {
            await BodyMetricsReader.read(reader: reader, activeDeviceId: reader.activeDeviceId, days: days)
        }
        func weightSeries(days: Int) async -> [WeightPoint] {
            await WeightSeries.series(reader: reader, from: "0000-01-01", to: "9999-12-31")
        }
        func agelessLongSessions(days: Int) async -> [HealthspanVO2.LongSession] { [] }
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
        func analysisSettings() -> AnalysisSettings {
            AnalysisSettings(effortMethod: .banister, spo2CandidateDisplay: false, sleepStagerV2: false,
                             motionAwareWake: false, deepHrvWindow: false, dayCycleMode: .persisted(nil),
                             rhythmAge: false, healthspan: false, hrvBaselineEpoch: 0, recoveryBaselineEpoch: 0,
                             traces: [])
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
        let engine = DailyAnalysis(services: services, profile: Profile(), deviceId: "my-whoop", host: Host(),
                                   messages: { "\($0)" })

        let ok = await engine.prepareAnalysisRecipe()

        XCTAssertTrue(ok)
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
}
