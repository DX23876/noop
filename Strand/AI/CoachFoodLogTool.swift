import Foundation
import StrandCore
import StrandAnalytics
import WhoopStore

extension AICoachEngine {
    /// `get_food_log` (owner, 2026-11-21): the food log as the coach reads it, from `FoodCoachReport`. On the iPhone
    /// the goals, food facts and diet form come from the Food page's own model, loaded the same way, so the coach
    /// and the page name the same goal and the same note. Without that model (the Mac) the report leaves the goal out
    /// rather than guess one.
    func foodLogTool(from: String?, to: String?, entries: Bool) async -> String {
        let today = StoreReader.localDayKey(.now)
        let end = (to.flatMap { WeightSeries.date(forDay: $0) } != nil ? to! : today)
        let start = from.flatMap { WeightSeries.date(forDay: $0) != nil ? $0 : nil }
            ?? FoodQuality.shifted(end, by: -6, calendar: .current) ?? end
        guard start <= end else { return "Nothing read: `from` is after `to`." }
        let profile = repo.coachProfile()
        let male: Bool? = profile.sex.lowercased() == "male" ? true : profile.sex.lowercased() == "female" ? false : nil
        let plan = DietPlan.decode(UserDefaults.standard.string(forKey: DietPlan.storageKey))
        let dietLine = plan.map { "goal \($0.goal.rawValue) at \(String(format: "%.1f", $0.pacePercent)) % of body weight a week, way of eating \($0.form.rawValue)" }
        let references = FoodReference.values(profileSex: profile.sex, age: profile.age, weightKg: profile.weightKg,
                                              heightCm: profile.heightCm, energyKcal: nil)
        #if os(iOS)
        if let repository = repo as? Repository {
            let model = ForgeFoodModel()
            await model.load(repo: repository, profile: profile.analytics)
            let context = FoodCoachReport.Context(facts: model.factsById, male: model.male, options: model.scoreOptions,
                                                  goals: { model.goals(for: $0) }, references: references, dietLine: dietLine)
            return FoodCoachReport.text(all: model.allEntries, from: start, to: end, includeEntries: entries,
                                        today: today, context: context)
        }
        #endif
        guard let store = await repo.storeHandle() else { return "Couldn't open the local store." }
        let all = (try? await store.foodLogEntries(from: "2000-01-01", to: today)) ?? []
        var facts: [String: FoodScore.FoodFacts] = [:]
        for id in Set(all.compactMap(\.foodId)) where !id.hasPrefix("bls:") {
            if let item = await FoodLibrary.item(store: store, id: id) { facts[id] = item.scoreFacts }
        }
        let context = FoodCoachReport.Context(facts: facts, male: male, options: .forDiet(plan?.form),
                                              references: references, dietLine: dietLine)
        return FoodCoachReport.text(all: all, from: start, to: end, includeEntries: entries, today: today, context: context)
    }
}
