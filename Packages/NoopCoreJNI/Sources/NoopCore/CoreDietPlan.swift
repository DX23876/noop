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

    /// `DietProgress.Progress` on the wire: `kind` is way, hold or recomp, with that case's fields beside it.
    struct ProgressWire: Encodable {
        var kind: String
        var goal: String?
        var startKg: Double
        var trendKg: Double
        var goalKg: Double?
        var fraction: Double?
        var stage: String?
        var doneKg: Double?
        var leftKg: Double?
        var inRange: Bool?
        var weeksInRange: Int?
        var weightSteady: Bool?
        var working: Bool?
        var bodyFatChange: Double?
        var waistChangeCm: Double?
        var strengthChangePercent: Double?

        init(_ p: DietProgress.Progress) {
            switch p {
            case .way(let w):
                kind = "way"; goal = w.goal.rawValue; startKg = w.startKg; trendKg = w.trendKg; goalKg = w.goalKg
                fraction = w.fraction; stage = w.stage.rawValue; doneKg = w.doneKg; leftKg = w.leftKg
            case .hold(let h):
                kind = "hold"; startKg = h.startKg; trendKg = h.trendKg; inRange = h.inRange; weeksInRange = h.weeksInRange
            case .recomp(let r):
                kind = "recomp"; startKg = r.startKg; trendKg = r.trendKg; weightSteady = r.weightSteady; working = r.working
                bodyFatChange = r.bodyFatChange; waistChangeCm = r.waistChangeCm; strengthChangePercent = r.strengthChangePercent
            }
        }
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
                                                dietBreakEveryWeeks: DietProgram.dietBreakEveryWeeks(plan))
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
        case "food.planProgress":
            // The way to the goal weight (`DietProgress`), as the plan page and Today's diet goal card show it: the
            // goal weight as planned, the smoothed weight trend, and for recomposition body fat and the waist.
            guard let plan = DietPlan.decode(args["plan"] as? String), !plan.hideNumbers else { return "null" }
            let from = Calendar.current.date(byAdding: .day, value: -120, to: Date()).map(StoreReader.localDayKey) ?? today
            let weights = await WeightSeries.series(reader: reader, from: from, to: today).map { (day: $0.day, kg: $0.value) }
            var bodyFat: [(day: String, value: Double)] = []
            var waist: [(day: String, value: Double)] = []
            if args["body"] as? Bool == true {
                let metrics = await BodyMetricsReader.read(reader: reader, activeDeviceId: reader.activeDeviceId, days: 365)
                bodyFat = metrics.series("body_fat").map { ($0.day, $0.value) }
                waist = metrics.series("waist").map { ($0.day, $0.value) }
            }
            guard let progress = DietProgress.resolve(plan: plan, goalWeightKg: DietTargets.plannedGoalWeight(plan, person: person),
                                                      weighIns: weights, bodyFat: bodyFat, waist: waist) else { return "null" }
            return CoreRead.json(ProgressWire(progress))
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
