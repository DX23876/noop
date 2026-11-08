import Foundation
import StrandCore
import WhoopStore

/// The diet planner on Android (decision 2026-11-09): the plan's targets, forecast, suggestions and weekly look,
/// all from the shared `DietTargets`, `DietForecast`, `DietSuggest` and `DietAdjust`. Kotlin stores the plan as the
/// same JSON under the same key as iOS and passes it in; nothing here is stored.
enum CoreDietPlan {
    struct Resolved: Encodable {
        var result: DietTargets.Result
        var forecast: DietForecast.Forecast
        /// The goal for the asked day (a fasting day has its own) and its macros.
        var dayKcal: Double
        var dayMacros: FoodTargets.Macros
    }

    static func run(_ op: String, args: [String: Any], store: WhoopStore, reader: StoreReader) async -> String {
        func double(_ k: String) -> Double? { (args[k] as? NSNumber)?.doubleValue }
        let sex = (args["sex"] as? String ?? "").lowercased()
        let person = DietPerson(weightKg: double("weightKg") ?? 80, heightCm: double("heightCm").flatMap { $0 > 0 ? $0 : nil },
                                age: (args["age"] as? Int).flatMap { $0 > 0 ? $0 : nil },
                                male: sex == "male" ? true : sex == "female" ? false : nil)
        let burn = double("burnKcal") ?? person.weightKg * 30
        let kcalPerKg = double("kcalPerKg")
        let today = StoreReader.localDayKey(Date())

        switch op {
        case "food.planResolve":
            guard let plan = DietPlan.decode(args["plan"] as? String) else { return "null" }
            let result = DietTargets.resolve(plan, person: person, burnKcal: burn, kcalPerKg: kcalPerKg)
            let day = args["day"] as? String ?? today
            let forecast = DietForecast.project(startKg: person.weightKg, goalKg: result.goalWeightKg, intakeKcal: result.averageKcal,
                                                burnKcal: result.burnKcal, kcalPerKg: kcalPerKg ?? DietTargets.defaultKcalPerKg,
                                                dietBreakEveryWeeks: plan.dietBreakEveryWeeks)
            return CoreRead.json(Resolved(result: result, forecast: forecast,
                                          dayKcal: DietTargets.kcal(on: day, plan: plan, result: result),
                                          dayMacros: FoodTargets.macros(plan: plan, result: result, day: day)))
        case "food.planSuggest":
            let from = Calendar.current.date(byAdding: .day, value: -14, to: Date()).map(StoreReader.localDayKey) ?? today
            let entries = ((try? await store.foodLogEntries(from: from, to: today)) ?? []).map(FoodLogEntryLite.init)
            let keep = (args["keep"] as? [String] ?? []).compactMap(DietPlan.Keep.init(rawValue:))
            let mode = DietPlan.Mode(rawValue: args["mode"] as? String ?? "") ?? .simple
            let s = DietSuggest.top(entries: entries, keep: keep, likesRules: args["likesRules"] as? Bool ?? false,
                                    strength: args["strength"] as? Bool ?? false, mode: mode)
            return CoreRead.json(["suggestions": s])
        case "food.planWeekly":
            guard let plan = DietPlan.decode(args["plan"] as? String) else { return "null" }
            let result = DietTargets.resolve(plan, person: person, burnKcal: burn, kcalPerKg: kcalPerKg)
            let from = Calendar.current.date(byAdding: .day, value: -21, to: Date()).map(StoreReader.localDayKey) ?? today
            let weights = await WeightSeries.series(reader: reader, from: from, to: today).map { (day: $0.day, kg: $0.value) }
            let weekStart = Calendar.current.date(byAdding: .day, value: -6, to: Date()).map(StoreReader.localDayKey) ?? today
            let logged = Set(((try? await store.foodLogEntries(from: weekStart, to: today)) ?? []).map(\.day)).count
            let outcome = DietAdjust.weekly(plan: plan, result: result, weighIns: weights, loggedDays: logged, today: today,
                                            kcalPerKg: kcalPerKg ?? DietTargets.defaultKcalPerKg)
            return CoreRead.json(outcome)
        case "food.planFit":
            // Whether a food (by id or stored group) suits the plan: 1 suits, -1 kept rare, 0 neutral.
            guard let plan = DietPlan.decode(args["plan"] as? String),
                  let motif = FoodGroupMotif.forFoodId(args["foodId"] as? String) ?? FoodGroupMotif.forGroup(args["group"] as? String)
            else { return #"{"fit":0}"# }
            return #"{"fit":\#(plan.form.fit(motif, addon: plan.addon))}"#
        default:
            return #"{"error":"unknownOp"}"#
        }
    }
}
