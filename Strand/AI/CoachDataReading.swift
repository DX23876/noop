import Foundation
import StrandAnalytics
import StrandCore
import StrandTraining
import WhoopProtocol
import WhoopStore

/// The reads and writes the coach makes on the wearer's data (Android parity plan, Coach step 1). Apple's
/// `Repository` answers them (`CoachDataReading+Repository.swift`); the Android core is meant to answer them over its
/// `StoreReader`, the way `GoalInputReading` already does for the goals, so `AICoach` can move into a package that
/// does not see `Repository`. Requirements carry no default arguments; the defaults Repository's methods have live
/// in the extension below, so call sites read the same as before.
@MainActor
protocol CoachDataReading: AnyObject {
    var days: [DailyMetric] { get }
    var sleeps: [CachedSleepSession] { get }
    var deviceId: String { get }
    /// The maximum heart rate the cardio lane prices with, and the profile's sex for the TRIMP coefficient.
    var cardioLoadMaxHR: Double { get }
    var strainProfileSex: String { get }
    var readinessLoadContext: ReadinessLoadContext? { get }

    func storeHandle() async -> WhoopStore?
    func refresh(days nDays: Int) async

    func workoutRows(days: Int, reconcileHrCap: Int?) async -> [WorkoutRow]
    func workoutZoneMinutes(from: Int, to: Int, zoneSet: HRZoneSet, source: String) async -> [Double]?
    func strapSessionEnergy(for rows: [WorkoutRow], maxDays: Int) async -> [String: Double]
    func resolvedStrengthHistory(days: Int) async -> ResolvedStrengthHistory
    func nativeTrainingExercises() async -> [TrainingExercise]
    func cardioRoomToday() async -> LaneHeadroom?

    func series(key: String, source: String, days: Int, fullHistory: Bool) async -> [(day: String, value: Double)]
    func exploreSeries(key: String, source: String, days: Int, fullHistory: Bool) async
        -> [(day: String, value: Double)]
    func resolvedSeries(key: String, source preferredSource: String, days: Int, fullHistory: Bool) async
        -> MetricSeriesResolution
    func availableKeys(source: String) async -> [String]
    func metricSources(key: String) async -> [String]
    func metricCatalog() async -> [MetricCatalogEntry]

    func hrSamples(from: Int, to: Int, limit: Int) async -> [HRSample]
    func rrIntervals(from: Int, to: Int, limit: Int) async -> [RRInterval]
    func latestHRSampleTs() async -> Int?
    func restingHrByDay(fromDay: String, toDay: String) async -> [String: Double]
    func sleepSessions(from: Int, to: Int, limit: Int) async -> [CachedSleepSession]
    func habitualWakeSec(days: Int) async -> Int?
    func habitualMidsleepSec(days: Int) async -> Int?

    func todayEnergy(profile: UserProfile) async -> DailyEnergySummary?
    func energySummaries(days: Int, profile: UserProfile) async -> [DailyEnergySummary]
    func energyPeakMETByDay(fromDay: String, toDay: String) async -> [String: Double]
    func activeEnergyByDay(days: Int) async -> [String: Double]
    func adaptiveExpenditureEstimate(asOf: Date) async -> AdaptiveExpenditureEstimate?

    func weightSeries(days: Int) async -> [WeightPoint]
    func bodyMetrics(days: Int) async -> BodyMetrics
    func moodSeries(days: Int) async -> [(day: String, value: Double)]
    func hydrationHistory(days: Int, now: Date) async -> [(day: String, value: Double)]
    func hydrationGoalML(profileSex: String) -> Int
    func journalEntries(days: Int) async -> [JournalEntry]
    func logWeight(kg: Double, at: Date, note: String?, source: WeightSource) async -> BodyWeightRow?

    /// Host hooks: work the coach starts that the host still owns (the check-in notification schedule, and
    /// the Training Load screen's reading rendered through `CoachTrainingLoadBrief`).
    func refreshCoachCheckIn() async
    func trainingLoadBrief() async -> String

    func saveJournalAnswer(day: String, question: String, answeredYes: Bool, notes: String?) async
    func saveJournalNumeric(day: String, question: String, value: Double, notes: String?) async
}

/// Repository's default arguments, for callers holding the protocol.
extension CoachDataReading {
    func refresh() async { await refresh(days: 120) }
    func workoutRows(days: Int = 4000) async -> [WorkoutRow] { await workoutRows(days: days, reconcileHrCap: nil) }
    func workoutZoneMinutes(from: Int, to: Int, zoneSet: HRZoneSet) async -> [Double]? {
        await workoutZoneMinutes(from: from, to: to, zoneSet: zoneSet, source: "")
    }
    func strapSessionEnergy(for rows: [WorkoutRow]) async -> [String: Double] {
        await strapSessionEnergy(for: rows, maxDays: 120)
    }
    func resolvedStrengthHistory() async -> ResolvedStrengthHistory { await resolvedStrengthHistory(days: 4_000) }
    func series(key: String, source: String, days: Int = 4000) async -> [(day: String, value: Double)] {
        await series(key: key, source: source, days: days, fullHistory: false)
    }
    func exploreSeries(key: String, source: String, days: Int = 4000) async -> [(day: String, value: Double)] {
        await exploreSeries(key: key, source: source, days: days, fullHistory: false)
    }
    func resolvedSeries(key: String, source: String, days: Int = 4000) async -> MetricSeriesResolution {
        await resolvedSeries(key: key, source: source, days: days, fullHistory: false)
    }
    func hrSamples(from: Int, to: Int) async -> [HRSample] { await hrSamples(from: from, to: to, limit: 8000) }
    func rrIntervals(from: Int, to: Int) async -> [RRInterval] { await rrIntervals(from: from, to: to, limit: 8000) }
    func sleepSessions(from: Int, to: Int) async -> [CachedSleepSession] {
        await sleepSessions(from: from, to: to, limit: 100)
    }
    func habitualWakeSec() async -> Int? { await habitualWakeSec(days: 4000) }
    func habitualMidsleepSec() async -> Int? { await habitualMidsleepSec(days: 4000) }
    func energySummaries(profile: UserProfile) async -> [DailyEnergySummary] {
        await energySummaries(days: 30, profile: profile)
    }
    func adaptiveExpenditureEstimate() async -> AdaptiveExpenditureEstimate? {
        await adaptiveExpenditureEstimate(asOf: Date())
    }
    func weightSeries() async -> [WeightPoint] { await weightSeries(days: 4000) }
    func bodyMetrics() async -> BodyMetrics { await bodyMetrics(days: 4_000) }
    func moodSeries() async -> [(day: String, value: Double)] { await moodSeries(days: 4000) }
    func hydrationHistory(days: Int = 7) async -> [(day: String, value: Double)] {
        await hydrationHistory(days: days, now: Date())
    }
    func journalEntries() async -> [JournalEntry] { await journalEntries(days: 4000) }
    @discardableResult
    func logWeight(kg: Double, at: Date = Date()) async -> BodyWeightRow? {
        await logWeight(kg: kg, at: at, note: nil, source: .manual)
    }
    func saveJournalAnswer(day: String, question: String, answeredYes: Bool) async {
        await saveJournalAnswer(day: day, question: question, answeredYes: answeredYes, notes: nil)
    }
    func saveJournalNumeric(day: String, question: String, value: Double) async {
        await saveJournalNumeric(day: day, question: question, value: value, notes: nil)
    }
}
