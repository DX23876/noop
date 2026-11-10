import Foundation
import StrandCore

extension AICoachEngine {
    /// Stores the coach's proposed diet plan change for the plan page (owner, 2026-11-10). The plan itself is never
    /// touched here: the wearer confirms the change on the plan page, which applies it through `DietPlanChange` and
    /// `DietTargets` with every safety line.
    func proposeDietChangeTool(input: [String: Any]) -> String {
        guard DietPlan.decode(UserDefaults.standard.string(forKey: DietPlan.storageKey)) != nil else {
            return "Nothing drafted: the user has no diet plan yet. Suggest they open Nutrition and tap the plan line "
                + "to plan their diet."
        }
        let change = DietPlanChange.parse(input, now: Int(Date().timeIntervalSince1970))
        guard !change.isEmpty, let raw = change.encoded() else {
            return "Nothing drafted: the change named nothing the planner allows (goal, pace, way of eating, breaks, "
                + "training-day share or a break week)."
        }
        UserDefaults.standard.set(raw, forKey: DietPlanChange.storageKey)
        return "Drafted (NOT active): a diet plan change is waiting on the plan page under Nutrition for the user "
            + "to review and confirm. Do not describe it as made."
    }
}
