#if os(iOS)
import Foundation

/// The training planner's days as the diet plan reads them (owner, 2026-11-10): a session counts when it is still
/// on (not declined, skipped or paused) and is strength work or a hard session, the days that use the most
/// carbohydrate. A rescheduled session counts on the day it moved to. Read here, passed to the core as
/// `DietTrainingDays.planned`, so the core reads no store.
enum DietTrainingPlan {
    /// Words in the planner's free-text sport that mean strength work, in the languages the coach writes in.
    static let strengthWords = ["strength", "weight", "lift", "gym", "squat", "deadlift", "bench", "hypertrophy",
                                "push", "pull", "legs", "upper", "lower", "full body", "kraft", "hantel", "muskel",
                                "fuerza", "musculation", "forza", "siłow", "força", "силов", "力量", "重量"]

    static func days(from proposals: [PlanProposal]) -> Set<String> {
        Set(proposals.filter(counts).map(\.day))
    }

    static func counts(_ p: PlanProposal) -> Bool {
        switch p.status {
        case .declined, .skipped, .paused: return false
        default: break
        }
        if p.intent == .hard { return true }
        guard p.intent != .rest, p.intent != .mobility else { return false }
        let sport = p.sport.lowercased()
        return strengthWords.contains { sport.contains($0) }
    }
}
#endif
