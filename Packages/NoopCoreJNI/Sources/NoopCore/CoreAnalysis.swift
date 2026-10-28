import Foundation
import StrandAnalytics
import StrandCore
import WhoopProtocol
import WhoopStore

/// The daily analysis on the core's own store (Android plan D-5, parity plan 1.1): what the Apple apps get from
/// `Repository` and `ProfileStore`, answered by the same shared code (`StrandCore`) over the core's store, with the
/// profile and the wearer's choices handed in by the Android app. Only the screen refreshes and the Apple-only
/// follow-ups (the HealthKit rewrite) have no counterpart.
public enum CoreAnalysis {
    /// The wearer's profile as the Android app holds it.
    public struct Profile: Sendable, Equatable {
        public var age: Int, sex: String, weightKg: Double, heightCm: Double, hrMaxOverride: Int
        /// The waist the Navy body-fat method reads (AgeLess lean mass), 0 when not entered.
        public var waistCm: Double
        /// The step estimate's calibration, as the Apple `ProfileStore` holds it (AgeLess steps).
        public var stepTicksPerStep: Double, stepsManualCoefficient: Double
        public var stepsCalibrationCoefficient: Double, stepsCalibrationSampleDays: Int
        public var stepsCalibrationConfidence: Double, stepsCalibrationManual: Bool, stepsHasBankedMotion: Bool
        public init(age: Int, sex: String, weightKg: Double, heightCm: Double, hrMaxOverride: Int, waistCm: Double = 0,
                    stepTicksPerStep: Double = 1, stepsManualCoefficient: Double = 0,
                    stepsCalibrationCoefficient: Double = 0, stepsCalibrationSampleDays: Int = 0,
                    stepsCalibrationConfidence: Double = 0, stepsCalibrationManual: Bool = false,
                    stepsHasBankedMotion: Bool = false) {
            self.age = age; self.sex = sex; self.weightKg = weightKg; self.heightCm = heightCm
            self.hrMaxOverride = hrMaxOverride; self.waistCm = waistCm
            self.stepTicksPerStep = stepTicksPerStep; self.stepsManualCoefficient = stepsManualCoefficient
            self.stepsCalibrationCoefficient = stepsCalibrationCoefficient
            self.stepsCalibrationSampleDays = stepsCalibrationSampleDays
            self.stepsCalibrationConfidence = stepsCalibrationConfidence
            self.stepsCalibrationManual = stepsCalibrationManual; self.stepsHasBankedMotion = stepsHasBankedMotion
        }
    }

    /// The wearer's analysis choices as the Android app holds them (the same keys the Apple `AppAnalysisHost` reads):
    /// the Effort model, the sleep stager, the wake check, the nightly HRV window, the day start and the two Lab
    /// passes, AgeLess and the daily rhythm. `standard` is what an install that never touched them gets on either
    /// platform.
    public struct Settings: Sendable, Equatable {
        public var effortBanister: Bool, sleepStagerV2: Bool, motionAwareWake: Bool, deepHrvWindow: Bool
        public var dayCycleMode: String?
        public var healthspan: Bool, rhythmAge: Bool
        /// The nights and detected workouts the wearer deleted, as "startTs:endTs" tokens (Apple: UserDefaults
        /// `sleep.dismissedSessions` and `workouts.dismissedDetected`; Android: the Room tombstones).
        public var dismissedSleepSpans: [String], dismissedWorkoutSpans: [String]
        /// The VO₂max the wearer entered, the day it was measured and the weight then; 0 when none.
        public var manualVO2max: Double, manualVO2maxDay: String, manualVO2maxWeightKg: Double
        /// The activity level the wearer chose for the fitness estimate (1 to 7), 0 for the automatic one.
        public var activityLevelOverride: Int
        /// Whether the energy model calibrates against a watch's active energy (Apple: Energy Plan setting).
        public var energyCalibration: Bool
        /// The Energy Plan's current formula, matching Apple's default before a plan is configured.
        public var basalFormula = BmrFormulaLog.decode("").current
        /// Manual baseline recalibration anchors, in Unix seconds; zero means no recalibration.
        public var hrvBaselineEpoch: Double = 0, recoveryBaselineEpoch: Double = 0
        /// Lab: the strap's SpO₂ estimate is kept for the Blood Oxygen tile (Apple `noopSpo2CandidateDisplay`).
        public var spo2CandidateDisplay = false
        public init(effortBanister: Bool, sleepStagerV2: Bool, motionAwareWake: Bool, deepHrvWindow: Bool,
                    dayCycleMode: String?, healthspan: Bool = false, rhythmAge: Bool = false,
                    dismissedSleepSpans: [String] = [], dismissedWorkoutSpans: [String] = [],
                    manualVO2max: Double = 0, manualVO2maxDay: String = "", manualVO2maxWeightKg: Double = 0,
                    activityLevelOverride: Int = 0, energyCalibration: Bool = false) {
            self.effortBanister = effortBanister; self.sleepStagerV2 = sleepStagerV2
            self.motionAwareWake = motionAwareWake; self.deepHrvWindow = deepHrvWindow; self.dayCycleMode = dayCycleMode
            self.healthspan = healthspan; self.rhythmAge = rhythmAge
            self.dismissedSleepSpans = dismissedSleepSpans; self.dismissedWorkoutSpans = dismissedWorkoutSpans
            self.manualVO2max = manualVO2max; self.manualVO2maxDay = manualVO2maxDay
            self.manualVO2maxWeightKg = manualVO2maxWeightKg
            self.activityLevelOverride = activityLevelOverride; self.energyCalibration = energyCalibration
        }

        /// The entered VO₂max as the energy model and AgeLess take it (Apple `FitnessPreferences.manualEntry`).
        var manualEntry: PeakMETResolver.ManualEntry? {
            guard manualVO2max > 0, manualVO2max.isFinite, manualVO2maxDay.count == 10 else { return nil }
            return .init(vo2max: manualVO2max, day: manualVO2maxDay,
                         weightKg: manualVO2maxWeightKg > 0 ? manualVO2maxWeightKg : nil)
        }

        public static let standard = Settings(effortBanister: false, sleepStagerV2: true, motionAwareWake: false,
                                              deepHrvWindow: false, dayCycleMode: nil)

        /// What the pass reads, the experiments the Android app has no switch for left off.
        public var analysisSettings: AnalysisSettings {
            AnalysisSettings(effortMethod: effortBanister ? .banister : .edwards, spo2CandidateDisplay: spo2CandidateDisplay,
                             sleepStagerV2: sleepStagerV2, motionAwareWake: motionAwareWake,
                             deepHrvWindow: deepHrvWindow, dayCycleMode: .persisted(dayCycleMode),
                             rhythmAge: rhythmAge, healthspan: healthspan,
                             hrvBaselineEpoch: hrvBaselineEpoch, recoveryBaselineEpoch: recoveryBaselineEpoch,
                             traces: [])
        }
    }

    /// Applies the Android app's further choices, sent as one JSON object so the JNI signature stays short: the
    /// deleted nights and workouts (`dismissedSleep`, `dismissedWorkouts`, "start:end" tokens), the waist and the
    /// step estimate's calibration (the `ProfileStore` names), and the fitness inputs the Apple Energy Plan holds
    /// (`manualVO2max`, `manualVO2maxDay`, `manualVO2maxWeightKg`, `activityLevelOverride`, `energyCalibration`, `formulaLog`)
    /// the Lab's `spo2CandidateDisplay` and the two manual baseline-recalibration anchors.
    /// Absent keys keep their defaults, the values an untouched Apple install has.
    public static func applyExtras(_ json: String, to settings: inout Settings, profile: inout Profile) {
        guard let data = json.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let raw = o["formulaLog"] as? String { settings.basalFormula = BmrFormulaLog.decode(raw).current }
        func double(_ k: String) -> Double? { (o[k] as? NSNumber)?.doubleValue }
        func int(_ k: String) -> Int? { (o[k] as? NSNumber)?.intValue }
        func bool(_ k: String) -> Bool? { (o[k] as? NSNumber)?.boolValue }
        if let v = o["dismissedSleep"] as? [String] { settings.dismissedSleepSpans = v }
        if let v = o["dismissedWorkouts"] as? [String] { settings.dismissedWorkoutSpans = v }
        if let v = double("manualVO2max") { settings.manualVO2max = v }
        if let v = o["manualVO2maxDay"] as? String { settings.manualVO2maxDay = v }
        if let v = double("manualVO2maxWeightKg") { settings.manualVO2maxWeightKg = v }
        if let v = int("activityLevelOverride") { settings.activityLevelOverride = v }
        if let v = bool("energyCalibration") { settings.energyCalibration = v }
        if let v = double("hrvBaselineEpoch") { settings.hrvBaselineEpoch = v }
        if let v = double("recoveryBaselineEpoch") { settings.recoveryBaselineEpoch = v }
        if let v = bool("spo2CandidateDisplay") { settings.spo2CandidateDisplay = v }
        if let v = double("waistCm") { profile.waistCm = v }
        if let v = double("stepTicksPerStep"), v > 0 { profile.stepTicksPerStep = v }
        if let v = double("stepsManualCoefficient") { profile.stepsManualCoefficient = v }
        if let v = double("stepsCalibrationCoefficient") { profile.stepsCalibrationCoefficient = v }
        if let v = int("stepsCalibrationSampleDays") { profile.stepsCalibrationSampleDays = v }
        if let v = double("stepsCalibrationConfidence") { profile.stepsCalibrationConfidence = v }
        if let v = bool("stepsCalibrationManual") { profile.stepsCalibrationManual = v }
        if let v = bool("stepsHasBankedMotion") { profile.stepsHasBankedMotion = v }
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
        let host = Host(settings)
        let source = ProfileSource(profile)
        source.basalFormula = settings.basalFormula
        source.manual = settings.manualEntry.map { ($0.day, $0.vo2max) }
        let services = StoreServices(reader: reader, settings: settings, host: host,
                                     profile: { [source] in source.analyticsProfile() })
        let engine = DailyAnalysis(services: services, profile: source, deviceId: deviceId, host: host,
                                   messages: { "\($0)" })
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
        let settings: Settings
        let profile: () -> UserProfile
        let host: Host
        var days: [DailyMetric] = []
        private var dataRevision = 0
        private let cardioCache = CardioLoadCache()
        private let stepCache = EnergyStepMovementCache()
        private var latestPeakMET: (day: String, peakMET: Double)?
        init(reader: StoreReader, settings: Settings, host: Host, profile: @escaping () -> UserProfile) {
            self.reader = reader; self.settings = settings; self.host = host; self.profile = profile
        }

        private var maxHR: Double { profile().maxHR ?? Double(StrainScorer.defaultMaxHR()) }
        private var sex: String { profile().sex }
        private var effortMethod: StrainScorer.Method { settings.analysisSettings.effortMethod }

        func storeHandle() async -> WhoopStore? { reader.store }
        func refresh(days nDays: Int) async {
            let today = StoreReader.localDayKey(Date())
            let from = StoreReader.localDayKey(Date().addingTimeInterval(-Double(nDays) * 86_400))
            days = await reader.unionDailyMetrics(from: from, to: today)
            dataRevision &+= 1
        }
        func dailyMetrics(fromDay: String, toDay: String) async -> [DailyMetric] {
            await reader.unionDailyMetrics(from: fromDay, to: toDay)
        }

        // MARK: Training sessions and cardio load (Apple: TrainingSessionFusion, TrainingCardioLoad)

        private func sessions(days: Int) async -> [UnifiedTrainingSession] {
            let now = Int(Date().timeIntervalSince1970)
            return await TrainingSessionResolver.read(reader: reader, from: now - days * 86_400, to: now + 86_400,
                                                      dismissedDetectedSpans: settings.dismissedWorkoutSpans).sessions
        }
        private func price(_ sessions: [UnifiedTrainingSession], budget: Int, recompute: Bool) async
            -> (resolution: TrainingCardioLoadResolution, computed: Int) {
            await CardioLoadPricing.price(sessions, reader: reader, maxHR: maxHR, sex: sex, dataRevision: dataRevision,
                                          cache: cardioCache, budget: budget, recompute: recompute)
        }
        func fillCardioLoadLedger() async {
            let all = await sessions(days: TrainingHistoryWindow.allDays)
            while !Task.isCancelled, await price(all, budget: 200, recompute: false).computed > 0 { await Task.yield() }
        }
        func recomputeCardioLoadHistory() async {
            _ = await price(await sessions(days: TrainingHistoryWindow.allDays), budget: Int.max, recompute: true)
            await cardioCache.removeAll()
        }
        func agelessLongSessions(days: Int) async -> [HealthspanVO2.LongSession] {
            let unified = await sessions(days: days)
            let resolution = await price(unified, budget: CardioLoadPricing.cardioLoadSessionBudget, recompute: false).resolution
            let nowTs = Int(Date().timeIntervalSince1970)
            let elevations = (try? await reader.store.workoutElevations(from: nowTs - (days + 1) * 86_400, to: nowTs)) ?? [:]
            return TrainingVO2max.longSessions(unified, resolution: resolution, elevations: elevations,
                                               offset: TimeZone.current.secondsFromGMT())
        }

        // MARK: Workouts (Apple: Repository.workoutRows, WorkoutHeartRateFillSeries)

        func workoutRows(days: Int, reconcileHrCap: Int?) async -> [WorkoutRow] {
            // The pass asks with `reconcileHrCap: 0`: the display-only heart-rate reconcile is not part of it.
            let now = Int(Date().timeIntervalSince1970)
            let raw = await reader.rawWorkoutRows(from: now - days * 86_400, to: now + 86_400,
                                                  dismissedDetectedSpans: settings.dismissedWorkoutSpans)
            let deduped = WorkoutSource.dedupCrossSource(raw)
            return await WorkoutHeartRateFills.overlay(deduped.sorted { $0.startTs > $1.startTs }, store: reader.store)
        }
        func fillRecordedWorkoutHeartRate(from: Int, to: Int) async throws -> Int {
            try await WorkoutHeartRateFills.fillRecorded(reader: reader, from: from, to: to, maxHR: maxHR, sex: sex,
                                                         method: effortMethod).filled
        }
        func fillAppleWorkoutHeartRate(from: Int, to: Int) async throws -> Int {
            try await WorkoutHeartRateFills.fillApple(reader: reader, from: from, to: to, maxHR: maxHR, sex: sex,
                                                      method: effortMethod).filled
        }

        // MARK: Sleep (Apple: Repository.selfHealEditedStages, dismissedSleepWindows)

        func selfHealEditedStages(from windowStart: Int, to windowEnd: Int, unchangedDays: Set<String>,
                                  tzOffsetSeconds: Int) async -> [CachedSleepSession] {
            await EditedSleepHeal.heal(
                store: reader.store, strapId: reader.activeDeviceId, computedId: reader.activeDeviceId + "-noop",
                from: windowStart, to: windowEnd, unchangedDays: unchangedDays, tzOffsetSeconds: tzOffsetSeconds,
                staging: .init(sleepV2: settings.sleepStagerV2, motionAwareWake: settings.motionAwareWake),
                lastSignature: host.storedString(Self.stagerSignatureKey),
                saveSignature: { [host] in host.store($0, forKey: Self.stagerSignatureKey) })
        }
        static let stagerSignatureKey = "analysis.selfHeal.stagerSignature"
        func dismissedSleepWindows() -> [(start: Int, end: Int)] {
            DismissedSleepSpans.windows(from: settings.dismissedSleepSpans)
        }

        // MARK: Steps, body, weight

        func resolvedSteps(from: String, to: String) async -> MetricSeriesResolution {
            await MetricResolver.resolvedSteps(store: reader.store, actualWhoopSource: reader.activeDeviceId,
                                               from: from, to: to)
        }
        func bodyMetrics(days: Int) async -> BodyMetrics {
            await BodyMetricsReader.read(reader: reader, activeDeviceId: reader.activeDeviceId, days: days)
        }
        func weightSeries(days: Int) async -> [WeightPoint] {
            let now = Date()
            return await WeightSeries.series(
                reader: reader,
                from: StoreReader.localDayKey(now.addingTimeInterval(-Double(days) * 86_400)),
                to: StoreReader.localDayKey(now.addingTimeInterval(86_400)))
        }

        // MARK: Energy (Apple: EnergySeries)

        func energyPeakMETByDay(fromDay: String, toDay: String) async -> [String: Double] {
            await EnergyCorrections.peakMETByDay(store: reader.store, deviceId: reader.activeDeviceId,
                                                 fromDay: fromDay, toDay: toDay)
        }
        func refreshWhoopEnergyModel(days: Int, profile: UserProfile) async -> Bool {
            let inputs = EnergyModelRefresh.Inputs(
                dailyRows: self.days, manualVO2: settings.manualEntry,
                activityLevelOverride: JurcaFitness.ActivityLevel(rawValue: settings.activityLevelOverride),
                calibrationEnabled: settings.energyCalibration, refreshMaxDays: Self.energyRefreshMaxDays,
                dismissedDetectedSpans: settings.dismissedWorkoutSpans, latestPeakMET: latestPeakMET)
            let outcome = await EnergyModelRefresh.perform(reader: reader, days: days, profile: profile, now: Date(),
                                                           inputs: inputs, stepCache: stepCache)
            latestPeakMET = outcome.latestPeakMET
            return outcome.ok
        }
        static let energyRefreshMaxDays = 120
        static let energyHistoryModelKey = "energy.historyModelVersion"
        func noteEnergyInputsRederived(dayStartTs: Int) async {
            await EnergyCorrections.noteInputsRederived(store: reader.store, dayStartTs: dayStartTs)
        }
        func ensureEnergyHistoryCurrent(profile: UserProfile, waitIfRunning: Bool) async {
            let current = WhoopDailyEnergyEstimate.modelVersion
            guard host.storedString(Self.energyHistoryModelKey) != current else { return }
            if await refreshWhoopEnergyModel(days: Self.energyRefreshMaxDays, profile: profile) {
                host.store(current, forKey: Self.energyHistoryModelKey)
            }
        }
        func correctLegacyWorkoutEnergy(profile base: UserProfile) async throws -> Int? {
            try await EnergyCorrections.correctLegacyWorkoutEnergy(reader: reader, profile: base)
        }
    }

    @MainActor
    private final class ProfileSource: AnalysisProfileSource {
        let p: Profile
        var basalFormula = BmrFormulaLog.decode("").current
        init(_ p: Profile) {
            self.p = p
            stepsCalibrationCoefficient = p.stepsCalibrationCoefficient
            stepsCalibrationSampleDays = p.stepsCalibrationSampleDays
            stepsCalibrationConfidence = p.stepsCalibrationConfidence
            stepsCalibrationManual = p.stepsCalibrationManual
            stepsHasBankedMotion = p.stepsHasBankedMotion
        }
        var age: Int { p.age }
        var sex: String { p.sex }
        var weightKg: Double { p.weightKg }
        var heightCm: Double { p.heightCm }
        var waistCm: Double { p.waistCm }
        var hrMaxOverride: Int { p.hrMaxOverride }
        var hrMax: Int { p.hrMaxOverride > 0 ? p.hrMaxOverride : Int(StrainScorer.tanakaHRmax(age: Double(max(p.age, 1)))) }
        var stepTicksPerStep: Double { p.stepTicksPerStep }
        var stepsManualOverride: Double? { p.stepsManualCoefficient > 0 ? p.stepsManualCoefficient : nil }
        var stepsCalibrationCoefficient: Double
        var stepsCalibrationSampleDays: Int
        var stepsCalibrationConfidence: Double
        var stepsCalibrationManual: Bool
        var stepsHasBankedMotion: Bool
        func analyticsProfile() -> UserProfile {
            // Same formula selection as Repository.analyticsProfile; the generic UserProfile default
            // is retained for other callers and must not substitute for the Energy Plan's selection.
            UserProfile(weightKg: p.weightKg, heightCm: p.heightCm, age: Double(p.age), sex: p.sex,
                        maxHR: Double(hrMax), basalFormula: basalFormula)
        }
        func enteredVO2max() -> (day: String, value: Double)? { manual }
        var manual: (day: String, value: Double)?
    }

    @MainActor
    private final class Host: AnalysisHost {
        let settings: Settings
        /// The pass's own bookkeeping (watermarks, heal flags, the stager signature), kept for the process so a
        /// later pass reuses it as the Apple app does through UserDefaults.
        static var bools: [String: Bool] = [:]
        static var strings: [String: String] = [:]
        var bools: [String: Bool] { get { Self.bools } set { Self.bools = newValue } }
        var strings: [String: String] { get { Self.strings } set { Self.strings = newValue } }
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
