import Foundation
import StrandAnalytics
import WhoopStore

/// The data work the daily analysis asks its platform to do: reads that go through the platform's caches, the
/// passes it serializes (energy, cardio ledger), and the reload of its screens. The Apple apps implement it with
/// `Repository`; Android implements it over `StoreReader` and the core functions (Android plan B3 step 5).
@MainActor
public protocol AnalysisDataServices: AnyObject {
    func storeHandle() async -> WhoopStore?
    /// Reloads the screens' caches over the last `nDays` days.
    func refresh(days nDays: Int) async
    func dailyMetrics(fromDay: String, toDay: String) async -> [DailyMetric]
    func fillCardioLoadLedger() async
    /// Prices every stored cardio load again wherever its raw heart rate remains.
    func recomputeCardioLoadHistory() async
    func energyPeakMETByDay(fromDay: String, toDay: String) async -> [String: Double]
    /// The merged daily rows the screens show (imported over computed).
    var days: [DailyMetric] { get }
    func workoutRows(days: Int, reconcileHrCap: Int?) async -> [WorkoutRow]
    func selfHealEditedStages(from windowStart: Int, to windowEnd: Int, unchangedDays: Set<String>,
                              tzOffsetSeconds: Int) async -> [CachedSleepSession]
    func resolvedSteps(from: String, to: String) async -> MetricSeriesResolution
    func refreshWhoopEnergyModel(days: Int, profile: UserProfile) async -> Bool
    func noteEnergyInputsRederived(dayStartTs: Int) async
    @discardableResult
    func fillRecordedWorkoutHeartRate(from: Int, to: Int) async throws -> Int
    @discardableResult
    func fillAppleWorkoutHeartRate(from: Int, to: Int) async throws -> Int
    func ensureEnergyHistoryCurrent(profile: UserProfile, waitIfRunning: Bool) async
    func dismissedSleepWindows() -> [(start: Int, end: Int)]
    func correctLegacyWorkoutEnergy(profile base: UserProfile) async throws -> Int?
    func bodyMetrics(days: Int) async -> BodyMetrics
    func weightSeries(days: Int) async -> [WeightPoint]
    func agelessLongSessions(days: Int) async -> [HealthspanVO2.LongSession]
    /// The training sessions in `[lo, hi]`, one per physical session across its sources.
    func trainingSessions(from lo: Int, to hi: Int) async -> TrainingSessionFusionResult
}

/// The wearer's profile as the daily analysis reads it, and the step calibration it writes back. The Apple apps
/// implement it with `ProfileStore`.
@MainActor
public protocol AnalysisProfileSource: AnyObject {
    var age: Int { get }
    var sex: String { get }
    var weightKg: Double { get }
    var heightCm: Double { get }
    var waistCm: Double { get }
    var hrMaxOverride: Int { get }
    var hrMax: Int { get }
    var stepTicksPerStep: Double { get }
    var stepsManualOverride: Double? { get }
    var stepsCalibrationCoefficient: Double { get set }
    var stepsCalibrationSampleDays: Int { get set }
    var stepsCalibrationConfidence: Double { get set }
    var stepsCalibrationManual: Bool { get set }
    var stepsHasBankedMotion: Bool { get set }
    /// The profile the analytics price with, including the chosen basal formula.
    func analyticsProfile() -> UserProfile
    /// The VO₂max the wearer entered and the day it was measured, nil without one.
    func enteredVO2max() -> (day: String, value: Double)?
}

/// User-facing text the analysis needs and the platform translates.
public enum AnalysisMessage: Sendable {
    /// No on-device store is open yet.
    case noStore
    /// A manual current-day refresh found no activity data.
    case noCurrentDayActivity
    /// A requested reanalysis did not finish.
    case reanalysisUnfinished
}

/// Lets the platform observe the analysis's published state without the core depending on Combine: every change
/// to a published property calls `willChange()` first, and the platform's handler forwards it (SwiftUI's
/// `objectWillChange` on Apple).
public final class AnalysisObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var token: AnyObject?
    private var handler: (@Sendable () -> Void)?

    public init() {}

    /// The platform's observation object, created on first use; `onChange` is called before each change.
    public func token<T: AnyObject>(_ make: () -> T, onChange: @escaping @Sendable (T) -> Void) -> T {
        lock.lock()
        defer { lock.unlock() }
        if let existing = token as? T { return existing }
        let made = make()
        token = made
        handler = { [weak made] in if let made { onChange(made) } }
        return made
    }

    /// Called by the analysis before a published property changes.
    public func willChange() {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?()
    }
}
