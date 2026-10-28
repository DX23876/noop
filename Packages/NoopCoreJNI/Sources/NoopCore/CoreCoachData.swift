import Foundation
import StrandAnalytics
import StrandCore
import StrandTraining
import WhoopProtocol
import WhoopStore

/// The Android core's host of `CoachDataReading` (Android parity plan, Coach step 4): the reads the coach makes,
/// answered over the shared `StoreReader` the way `CoreGoals.Host` answers the goal loader, and through that host
/// wherever the two read the same lane, so the coach and the goals cannot disagree about a workout or a weigh-in.
/// A lane the core cannot read yet (energy summaries, the cardio room, mood, the Training Load reading) answers
/// nothing, so the coach says there is no data instead of quoting a number Apple would not. Writes are not wired
/// on Android yet and do nothing. Call `load()` before handing it to the coach: `days` and `sleeps` are read once.
@MainActor
final class CoreCoachData: CoachDataReading {
    private let goals: CoreGoals.Host
    private let settings: CoreGoals.Settings
    private let now: Date
    private var reader: StoreReader { goals.reader }

    private(set) var days: [DailyMetric] = []
    private(set) var sleeps: [CachedSleepSession] = []
    var deviceId: String { reader.activeDeviceId }
    let readinessLoadContext: ReadinessLoadContext? = nil

    init(reader: StoreReader, settings: CoreGoals.Settings, now: Date = Date()) {
        self.goals = CoreGoals.Host(reader: reader, settings: settings, motivationEnabled: false, now: now)
        self.settings = settings
        self.now = now
    }

    /// Reads the merged daily rows and the last fortnight's sleep, which the protocol exposes synchronously.
    func load() async {
        days = await goals.goalDays()
        let t = Int(now.timeIntervalSince1970)
        sleeps = await reader.unionSleepSessions(from: t - 14 * 86_400, to: t + 86_400, limit: 100)
    }

    var cardioLoadMaxHR: Double {
        settings.energyProfile?.maxHR ?? Double(StrainScorer.defaultMaxHR())
    }
    var strainProfileSex: String { settings.profileSex }

    func storeHandle() async -> WhoopStore? { reader.store }
    func refresh(days nDays: Int) async { await load() }

    func workoutRows(days: Int, reconcileHrCap: Int?) async -> [WorkoutRow] { await goals.goalWorkoutRows(days: days) }
    func workoutZoneMinutes(from: Int, to: Int, zoneSet: HRZoneSet, source: String) async -> [Double]? {
        await WorkoutPhysiology.zoneMinutes(reader: reader, from: from, to: to, zoneSet: zoneSet, source: source)
    }
    func strapSessionEnergy(for rows: [WorkoutRow], maxDays: Int) async -> [String: Double] { [:] }
    func resolvedStrengthHistory(days: Int) async -> ResolvedStrengthHistory { await goals.goalStrengthHistory(days: days) }
    func nativeTrainingExercises() async -> [TrainingExercise] {
        (try? await reader.store.trainingExercises()) ?? []
    }
    func cardioRoomToday() async -> LaneHeadroom? { nil }

    func series(key: String, source: String, days: Int, fullHistory: Bool) async -> [(day: String, value: Double)] {
        let r = range(days: days, fullHistory: fullHistory)
        return await reader.series(key: key, source: source, from: r.from, to: r.to, suppressedSleepWakeDays: [])
    }
    func exploreSeries(key: String, source: String, days: Int, fullHistory: Bool) async
        -> [(day: String, value: Double)] {
        let r = range(days: days, fullHistory: fullHistory)
        return await reader.exploreSeries(key: key, source: source, from: r.from, to: r.to, dailyRows: self.days,
                                          suppressedSleepWakeDays: [])
    }
    func resolvedSeries(key: String, source preferredSource: String, days: Int, fullHistory: Bool) async
        -> MetricSeriesResolution {
        let r = range(days: days, fullHistory: fullHistory)
        return await MetricResolver.resolve(store: reader.store, key: key, preferredSource: preferredSource,
                                            actualWhoopSource: reader.activeDeviceId, from: r.from, to: r.to,
                                            suppressedSleepWakeDays: [])
    }
    /// For the canonical WHOOP source, the keys under the active strap too, as `Repository.availableKeys` reads.
    func availableKeys(source: String) async -> [String] {
        let ids = source == MetricResolver.whoopSource
            ? StoreReader.importedReadIds(activeDeviceId: reader.activeDeviceId) : [source]
        var keys = Set<String>()
        for id in ids { keys.formUnion((try? await reader.store.metricKeys(deviceId: id)) ?? []) }
        return keys.sorted()
    }
    func metricSources(key: String) async -> [String] { (try? await reader.store.metricSources(key: key)) ?? [] }
    func metricCatalog() async -> [MetricCatalogEntry] { (try? await reader.store.metricCatalog()) ?? [] }

    func hrSamples(from: Int, to: Int, limit: Int) async -> [HRSample] {
        await reader.hrSamples(from: from, to: to, limit: limit)
    }
    func rrIntervals(from: Int, to: Int, limit: Int) async -> [RRInterval] {
        await reader.rrIntervals(from: from, to: to, limit: limit)
    }
    func latestHRSampleTs() async -> Int? { await reader.unionLatestHRSampleTs() }
    func restingHrByDay(fromDay: String, toDay: String) async -> [String: Double] {
        await reader.restingHrByDay(fromDay: fromDay, toDay: toDay)
    }
    func sleepSessions(from: Int, to: Int, limit: Int) async -> [CachedSleepSession] {
        await reader.unionSleepSessions(from: from, to: to, limit: limit)
    }
    func habitualWakeSec(days: Int) async -> Int? {
        let offset = TimeZone.current.secondsFromGMT()
        return SleepStageTotals.habitualWakeSec(await historyBlocks(days: days, offsetSec: offset), offsetSec: offset)
    }
    func habitualMidsleepSec(days: Int) async -> Int? {
        let offset = TimeZone.current.secondsFromGMT()
        return SleepStageTotals.habitualMidsleepSec(await historyBlocks(days: days, offsetSec: offset),
                                                    offsetSec: offset)
    }

    func todayEnergy(profile: UserProfile) async -> DailyEnergySummary? { nil }
    func energySummaries(days: Int, profile: UserProfile) async -> [DailyEnergySummary] { [] }
    func energyPeakMETByDay(fromDay: String, toDay: String) async -> [String: Double] { [:] }
    func activeEnergyByDay(days: Int) async -> [String: Double] { await goals.goalActiveEnergyByDay(days: days) }
    func adaptiveExpenditureEstimate(asOf: Date) async -> AdaptiveExpenditureEstimate? { nil }

    func weightSeries(days: Int) async -> [WeightPoint] {
        let r = range(days: days, fullHistory: false)
        return await WeightSeries.series(reader: reader, from: r.from, to: r.to)
    }
    func bodyMetrics(days: Int) async -> BodyMetrics { await goals.goalBodyMetrics(days: days) }
    func moodSeries(days: Int) async -> [(day: String, value: Double)] { [] }
    func hydrationHistory(days: Int, now: Date) async -> [(day: String, value: Double)] {
        await goals.goalHydrationHistory(days: days, now: now)
    }
    func hydrationGoalML(profileSex: String) -> Int {
        HydrationGoal.dailyGoalML(sex: profileSex, effort: days.first { $0.day == StoreReader.localDayKey(now) }?.strain)
    }
    func journalEntries(days: Int) async -> [JournalEntry] { await goals.goalJournalEntries(days: days) }
    func logWeight(kg: Double, at: Date, note: String?, source: WeightSource) async -> BodyWeightRow? { nil }

    func refreshCoachCheckIn() async {}
    func trainingLoadBrief() async -> String { "" }

    func saveJournalAnswer(day: String, question: String, answeredYes: Bool, notes: String?) async {}
    func saveJournalNumeric(day: String, question: String, value: Double, notes: String?) async {}

    private func range(days: Int, fullHistory: Bool) -> (from: String, to: String) {
        if fullHistory { return ("0000-01-01", "9999-12-31") }
        return (StoreReader.localDayKey(now.addingTimeInterval(-Double(days) * 86_400)),
                StoreReader.localDayKey(now.addingTimeInterval(86_400)))
    }

    private func historyBlocks(days: Int, offsetSec: Int) async -> [SleepStageTotals.HistoryBlock] {
        let t = Int(now.timeIntervalSince1970)
        return await reader.sleepHistoryBlocks(from: t - days * 86_400, to: t + 86_400, offsetSec: offsetSec)
    }
}
