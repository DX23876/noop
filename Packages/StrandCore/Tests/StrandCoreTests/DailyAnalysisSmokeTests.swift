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

        init(reader: StoreReader) { self.reader = reader }

        func storeHandle() async -> WhoopStore? { reader.store }
        func refresh(days nDays: Int) async { refreshes += 1 }
        func dailyMetrics(fromDay: String, toDay: String) async -> [DailyMetric] {
            await reader.unionDailyMetrics(from: fromDay, to: toDay)
        }
        func fillCardioLoadLedger() async {}
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
        func refreshWhoopEnergyModel(days: Int, profile: UserProfile) async -> Bool { true }
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
}
