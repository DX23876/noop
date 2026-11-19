import Foundation
import StrandAnalytics
import StrandCore
import StrandTraining
import WhoopStore

/// Everything the diet plan needs to answer "what is today's calorie goal", gathered once.
///
/// Why it is here rather than in the Android core (moved 2026-11-19): the day's goal is the number the Food
/// page leads with, and the Today tile has to show the SAME one. Until now the gathering lived in a file
/// only Android compiles, so the iPhone's Food page gathered it again in its own model and a tile had
/// nowhere to ask. A second gathering for a tile is a second answer to the wearer's calorie goal, which is
/// the one number in this app where that is least acceptable.
///
/// The resolving itself was already shared (`DietDayResolver`); this is the reading around it.
///
/// Analysis migration required: no. Reads only.
enum DietDayContext {

    struct Context {
        var day: DietDayResolver.Day
        var person: DietPerson
        var complete: Set<String>
        var weights: [(day: String, kg: Double)]
        var history: ResolvedStrengthHistory
    }

    /// The strength work the plan reads: a year of resolved sessions, with the spans the wearer dismissed left out.
    static func strengthHistory(reader: StoreReader, dismissed: [String], now: Int) async -> ResolvedStrengthHistory {
        let fusion = await TrainingSessionResolver.read(reader: reader, from: now - 365 * 86_400, to: now + 86_400,
                                                        dismissedDetectedSpans: dismissed)
        return await StrengthHistoryReader.read(store: reader.store, days: 365, now: now) { fusion }
    }

    /// The strength days the plan counts as training: logged strength work and the planner's strength or hard sessions.
    static func trainingDays(reader: StoreReader, dismissed: [String], now: Int,
                             history known: ResolvedStrengthHistory? = nil) async -> DietTrainingDays {
        let history: ResolvedStrengthHistory
        if let known { history = known } else { history = await strengthHistory(reader: reader, dismissed: dismissed, now: now) }
        let offset = TimeZone.current.secondsFromGMT()
        let logged = Set(TrainingLoadLanes.strengthByDay(history.workouts, tzOffsetSeconds: offset).filter { $0.value > 0 }.keys)
        let planned = await MainActor.run { DietTrainingPlan.days(from: CoachPlanStore.shared.proposals) }
        return DietTrainingDays(planned: planned, logged: logged)
    }

    /// One day as the plan reads it: its phase, the training-day shift, the active-day extra and the burn the
    /// plan starts from.
    static func read(plan: DietPlan, person: DietPerson, burn: Double, kcalPerKg: Double?,
                     burnedByDay: [String: Double], dismissedWorkouts: [String],
                     store: WhoopStore, reader: StoreReader, day: String, now: Date = Date()) async -> Context {
        let today = StoreReader.localDayKey(now)
        let from = Calendar.current.date(byAdding: .day, value: -(DietExpenditure.windowDays - 1), to: now)
            .map(StoreReader.localDayKey) ?? today
        let complete = (try? await store.foodCompleteDays(from: from, to: today)) ?? []
        let intake = (await NutritionReads.nutritionByDay(store: store, from: from, to: today)).compactMapValues { $0.calories }
        let weighFrom = Calendar.current.date(byAdding: .day, value: -120, to: now).map(StoreReader.localDayKey) ?? today
        let weights = await WeightSeries.series(reader: reader, from: weighFrom, to: today).map { (day: $0.day, kg: $0.value) }
        var withFat = person
        let metrics = await BodyMetricsReader.read(reader: reader, activeDeviceId: reader.activeDeviceId, days: 365)
        withFat.bodyFatPercent = metrics.latest("body_fat")?.value
        let nowSec = Int(now.timeIntervalSince1970)
        let history = await strengthHistory(reader: reader, dismissed: dismissedWorkouts, now: nowSec)
        let training = await trainingDays(reader: reader, dismissed: dismissedWorkouts, now: nowSec, history: history)
        let inputs = DietDayResolver.Inputs(plan: plan, person: withFat, strapBurnKcal: burn, kcalPerKg: kcalPerKg,
                                            burnedByDay: burnedByDay, completeDays: complete, intakeByDay: intake,
                                            weighIns: weights, training: training, today: today)
        return Context(day: DietDayResolver.resolve(inputs, day: day, now: now), person: withFat,
                       complete: complete, weights: weights, history: history)
    }
}
