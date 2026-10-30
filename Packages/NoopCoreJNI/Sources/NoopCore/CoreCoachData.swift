import Foundation
import StrandAnalytics
import StrandCore
import StrandTraining
import WhoopProtocol
import WhoopStore

/// The Android core's host of `CoachDataReading` (Android parity plan, Coach step 4): the reads the coach makes,
/// answered over the shared `StoreReader` the way `CoreGoals.Host` answers the goal loader, and through that host
/// wherever the two read the same lane, so the coach and the goals cannot disagree about a workout or a weigh-in.
/// The energy summaries, the cardio room, mood, the Training Load reading and its readiness context come from the
/// same shared computations the Android screens use (`CoreEnergyPlan`, `CoreTrainingLoad`, `TrainingLoadLanes`), as
/// `Repository` answers them on Apple. A weigh-in the coach logs goes to the core's weight lane, as Body's does.
/// Call `load()` before handing it to the coach: `days`, `sleeps` and the readiness context are read once.
@MainActor
final class CoreCoachData: CoachDataReading {
    private let goals: CoreGoals.Host
    private let settings: CoreGoals.Settings
    private let now: Date
    private var reader: StoreReader { goals.reader }

    private(set) var days: [DailyMetric] = []
    private(set) var sleeps: [CachedSleepSession] = []
    var deviceId: String { reader.activeDeviceId }
    private(set) var readinessLoadContext: ReadinessLoadContext?
    /// The cardio lane's daily loads behind the readiness context, kept for `cardioRoomToday`.
    private var cardioLanes: (byDay: [String: Double], unknownDays: Set<String>, activity: LaneActivity)?

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
        await loadLanes()
    }

    /// `Repository.refreshReadinessLoadContext`: the strength and cardio lanes over exactly the history a reading
    /// depends on (`TrainingLoadLanes.lookbackDays`), priced with the wearer's maximum heart rate.
    private func loadLanes() async {
        let t = Int(now.timeIntervalSince1970)
        let days = TrainingLoadLanes.lookbackDays
        let fusion = await TrainingSessionResolver.read(reader: reader, from: t - days * 86_400, to: t + 86_400,
                                                        dismissedDetectedSpans: settings.dismissedWorkoutSpans)
        let strength = await StrengthHistoryReader.read(store: reader.store, days: days, now: t) { fusion }
        let resolution = await CardioLoadPricing.price(fusion.sessions, reader: reader, maxHR: cardioLoadMaxHR,
                                                       sex: strainProfileSex, dataRevision: 0, cache: CardioLoadCache(),
                                                       budget: CardioLoadPricing.cardioLoadSessionBudget,
                                                       recompute: false).resolution
        let offset = TimeZone.current.secondsFromGMT()
        let cardio = TrainingLoadLanes.cardioSeries(sessions: fusion.sessions, resolution: resolution, tzOffsetSeconds: offset)
        cardioLanes = (cardio.byDay, cardio.unknownDays, cardio.activity)
        readinessLoadContext = TrainingLoadLanes.readinessContext(strengthWorkouts: strength.workouts, cardio: cardio,
                                                                  today: StoreReader.localDayKey(now), tzOffsetSeconds: offset)
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
    /// `Repository.cardioRoomToday`: the cardio lane's room today (`LaneOutlook.headroom`).
    func cardioRoomToday() async -> LaneHeadroom? {
        if cardioLanes == nil { await loadLanes() }
        guard let lanes = cardioLanes else { return nil }
        return LaneOutlook.headroom(dailyByDay: lanes.byDay, unknownDays: lanes.unknownDays, activity: lanes.activity,
                                    lane: .cardio, today: StoreReader.localDayKey(now))
    }

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

    func todayEnergy(profile: UserProfile) async -> DailyEnergySummary? {
        let today = StoreReader.localDayKey(Date())
        return await energySummaries(days: 2, profile: profile).last { $0.day == today }
    }
    /// The summaries the Energy screens show (`CoreEnergyPlan.summaries`), with the adaptive prior as Apple's.
    func energySummaries(days: Int, profile: UserProfile) async -> [DailyEnergySummary] {
        let prior = await NutritionReads.adaptiveEstimate(reader: reader, asOf: Date())?.estimatedDailyKcal
        return await CoreEnergyPlan.summaries(reader: reader, settings: settings, profile: profile, days: days,
                                              adaptivePrior: prior)
    }
    func energyPeakMETByDay(fromDay: String, toDay: String) async -> [String: Double] {
        await EnergyCorrections.peakMETByDay(store: reader.store, deviceId: reader.activeDeviceId, fromDay: fromDay, toDay: toDay)
    }
    func activeEnergyByDay(days: Int) async -> [String: Double] { await goals.goalActiveEnergyByDay(days: days) }
    func adaptiveExpenditureEstimate(asOf: Date) async -> AdaptiveExpenditureEstimate? {
        await NutritionReads.adaptiveEstimate(reader: reader, asOf: asOf)
    }

    func weightSeries(days: Int) async -> [WeightPoint] {
        let r = range(days: days, fullHistory: false)
        return await WeightSeries.series(reader: reader, from: r.from, to: r.to)
    }
    func bodyMetrics(days: Int) async -> BodyMetrics { await goals.goalBodyMetrics(days: days) }
    /// `Repository.moodSeries`: the daily check-in faces, one per local day.
    func moodSeries(days: Int) async -> [(day: String, value: Double)] {
        await series(key: MoodStore.moodKey, source: MoodStore.moodDeviceId, days: days, fullHistory: false)
    }
    func hydrationHistory(days: Int, now: Date) async -> [(day: String, value: Double)] {
        await goals.goalHydrationHistory(days: days, now: now)
    }
    func hydrationGoalML(profileSex: String) -> Int {
        HydrationGoal.dailyGoalML(sex: profileSex, effort: days.first { $0.day == StoreReader.localDayKey(now) }?.strain)
    }
    func journalEntries(days: Int) async -> [JournalEntry] { await goals.goalJournalEntries(days: days) }
    /// A weigh-in the coach logs, into the core's weight lane as Body logs one (`CoreBody.logWeight`).
    func logWeight(kg: Double, at: Date, note: String?, source: WeightSource) async -> BodyWeightRow? {
        await CoreBody.weighIn(store: reader.store, kg: kg, at: at, note: note, source: source.storageToken)
    }

    /// From the energy profile Android supplies; without one, `UserProfile`'s defaults and the population
    /// maximum heart rate, so zone and energy answers stay explicit estimates rather than blanks.
    func coachProfile() -> CoachProfile {
        var p = settings.energyProfile ?? UserProfile(sex: settings.profileSex)
        if p.sex.isEmpty { p.sex = settings.profileSex }
        let hrMax = Int(cardioLoadMaxHR.rounded())
        return CoachProfile(sex: p.sex, age: Int(p.age), heightCm: p.heightCm, weightKg: p.weightKg, hrMax: hrMax,
                            hrZoneSet: HRZones.zones(age: p.age, maxHROverride: p.maxHR), analytics: p)
    }
    func refreshCoachCheckIn() async {}
    /// The Training Load screen's reading for the model (`CoachTrainingLoadBrief.text`), as Apple's host renders it.
    func trainingLoadBrief() async -> String {
        CoachTrainingLoadBrief.text(await CoreTrainingLoad.reading(reader: reader, maxHR: cardioLoadMaxHR, sex: strainProfileSex,
                                                                   dismissedWorkoutSpans: settings.dismissedWorkoutSpans).prepared)
    }

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
