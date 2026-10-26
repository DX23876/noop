import Foundation
import StrandAnalytics
import StrandCore
import WhoopProtocol
import WhoopStore

/// The daily analysis on the core's own store (Android plan D-5): what the Apple apps get from `Repository` and
/// `ProfileStore`, reduced to what the store alone can answer. Steps resolve from the store; Apple Health,
/// energy pricing, cardio load and workout fills are not part of it yet, so those parts of the pass stay empty
/// here rather than guessing. The profile comes from the Android app.
public enum CoreAnalysis {
    /// The wearer's profile as the Android app holds it.
    public struct Profile: Sendable, Equatable {
        public var age: Int, sex: String, weightKg: Double, heightCm: Double, hrMaxOverride: Int
        public init(age: Int, sex: String, weightKg: Double, heightCm: Double, hrMaxOverride: Int) {
            self.age = age; self.sex = sex; self.weightKg = weightKg; self.heightCm = heightCm
            self.hrMaxOverride = hrMaxOverride
        }
    }

    /// The wearer's analysis choices as the Android app holds them (the same keys the Apple `AppAnalysisHost` reads):
    /// the Effort model, the sleep stager, the wake check, the nightly HRV window and the day start. `standard` is
    /// what an install that never touched them gets on either platform.
    public struct Settings: Sendable, Equatable {
        public var effortBanister: Bool, sleepStagerV2: Bool, motionAwareWake: Bool, deepHrvWindow: Bool
        public var dayCycleMode: String?
        public init(effortBanister: Bool, sleepStagerV2: Bool, motionAwareWake: Bool, deepHrvWindow: Bool,
                    dayCycleMode: String?) {
            self.effortBanister = effortBanister; self.sleepStagerV2 = sleepStagerV2
            self.motionAwareWake = motionAwareWake; self.deepHrvWindow = deepHrvWindow; self.dayCycleMode = dayCycleMode
        }

        public static let standard = Settings(effortBanister: false, sleepStagerV2: true, motionAwareWake: false,
                                              deepHrvWindow: false, dayCycleMode: nil)

        /// What the pass reads, the experiments the Android app has no switch for left off.
        public var analysisSettings: AnalysisSettings {
            AnalysisSettings(effortMethod: effortBanister ? .banister : .edwards, spo2CandidateDisplay: false,
                             sleepStagerV2: sleepStagerV2, motionAwareWake: motionAwareWake,
                             deepHrvWindow: deepHrvWindow, dayCycleMode: .persisted(dayCycleMode),
                             rhythmAge: false, healthspan: false, hrvBaselineEpoch: 0, recoveryBaselineEpoch: 0,
                             traces: [])
        }
    }

    /// Today's scores the pass left in the store, as one log-friendly line; nil when today has no computed row.
    public struct Today: Sendable, Equatable {
        public var day: String, charge: Double?, effort: Double?, sleepMinutes: Double?, restingHr: Int?, hrv: Double?
        public var line: String {
            func n(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "-" }
            return "day=\(day) charge=\(n(charge)) effort=\(n(effort)) sleepMin=\(n(sleepMinutes)) " +
                "rhr=\(restingHr.map(String.init) ?? "-") hrv=\(n(hrv))"
        }
    }

    /// Runs the standard daily pass over the last `days` days on `store` and returns today's computed scores.
    @MainActor
    public static func run(store: WhoopStore, deviceId: String, profile: Profile, settings: Settings = .standard,
                           days: Int = 21) async -> Today? {
        let reader = StoreReader(store: store, activeDeviceId: deviceId, registeredWhoopIds: [])
        let engine = DailyAnalysis(services: StoreServices(reader: reader), profile: ProfileSource(profile),
                                   deviceId: deviceId, host: Host(settings), messages: { "\($0)" })
        await engine.analyzeRecent(maxDays: days, force: true, allowDayReuse: false)
        let today = StoreReader.localDayKey(Date())
        guard let row = try? await store.dailyMetrics(deviceId: deviceId + "-noop", from: today, to: today).first
        else { return nil }
        return Today(day: row.day, charge: row.recovery, effort: row.strain, sleepMinutes: row.totalSleepMin,
                     restingHr: row.restingHr, hrv: row.avgHrv)
    }

    @MainActor
    private final class StoreServices: AnalysisDataServices {
        let reader: StoreReader
        var days: [DailyMetric] = []
        init(reader: StoreReader) { self.reader = reader }

        func storeHandle() async -> WhoopStore? { reader.store }
        func refresh(days nDays: Int) async {
            let today = StoreReader.localDayKey(Date())
            let from = StoreReader.localDayKey(Date().addingTimeInterval(-Double(nDays) * 86_400))
            days = await reader.unionDailyMetrics(from: from, to: today)
        }
        func dailyMetrics(fromDay: String, toDay: String) async -> [DailyMetric] {
            await reader.unionDailyMetrics(from: fromDay, to: toDay)
        }
        func fillCardioLoadLedger() async {}
        func recomputeCardioLoadHistory() async {}
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

    @MainActor
    private final class ProfileSource: AnalysisProfileSource {
        let p: Profile
        init(_ p: Profile) { self.p = p }
        var age: Int { p.age }
        var sex: String { p.sex }
        var weightKg: Double { p.weightKg }
        var heightCm: Double { p.heightCm }
        var waistCm: Double { 0 }
        var hrMaxOverride: Int { p.hrMaxOverride }
        var hrMax: Int { p.hrMaxOverride > 0 ? p.hrMaxOverride : Int(StrainScorer.tanakaHRmax(age: Double(max(p.age, 1)))) }
        var stepTicksPerStep: Double { 1 }
        var stepsManualOverride: Double? { nil }
        var stepsCalibrationCoefficient = 0.0
        var stepsCalibrationSampleDays = 0
        var stepsCalibrationConfidence = 0.0
        var stepsCalibrationManual = false
        var stepsHasBankedMotion = false
        func analyticsProfile() -> UserProfile {
            UserProfile(weightKg: p.weightKg, heightCm: p.heightCm, age: Double(p.age), sex: p.sex)
        }
        func enteredVO2max() -> (day: String, value: Double)? { nil }
    }

    @MainActor
    private final class Host: AnalysisHost {
        let settings: Settings
        var bools: [String: Bool] = [:]
        var strings: [String: String] = [:]
        init(_ settings: Settings) { self.settings = settings }
        func analysisSettings() -> AnalysisSettings { settings.analysisSettings }
        func diagnostic(_ line: String, domain: TestDomain?) {}
        func storedBool(_ key: String) -> Bool { bools[key] ?? false }
        func storedString(_ key: String) -> String? { strings[key] }
        func store(_ value: Bool, forKey key: String) { bools[key] = value }
        func store(_ value: String?, forKey key: String) { strings[key] = value }
        func store(_ value: Double, forKey key: String) {}
        func passWillStart() -> AnalysisPassTicket {
            AnalysisPassTicket(owedToken: nil, cpuSecondsAtStart: nil, assertionExpiriesAtStart: 0)
        }
        func passDidFinish(_ ticket: AnalysisPassTicket, elapsedSeconds: Double) -> AnalysisPassReport {
            AnalysisPassReport(settled: true, costLine: "re-score: cost core")
        }
        nonisolated func paceIfBackgrounded(since mark: inout UInt64) async {}
        func costReading() -> (cpuSeconds: Double?, batteryPercent: Int?) { (nil, nil) }
    }
}
