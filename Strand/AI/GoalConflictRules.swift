import Foundation

/// Shared conflict decisions for long-term goals; hosts format the remaining period comparisons.
enum GoalConflicts {
    struct Note: Equatable {
        /// The goal the note is shown on: the newer one of the pair.
        let goalId: UUID
        let text: String
    }

    static func longTermNotes(_ longTerm: [CoachGoal]) -> [Note] {
        var notes: [Note] = []
        let open = longTerm.filter { $0.status == .active || $0.status == .paused }
        for (index, a) in open.enumerated() {
            for b in open[(index + 1)...] {
                let newerId = newer(a.id, a.createdAt, b.id, b.createdAt)
                if a.kind == .weight, b.kind == .weight,
                   let da = direction(a), let db = direction(b), da * db < 0 {
                    notes.append(Note(goalId: newerId,
                                      text: String(localized: "Two weight goals pull in opposite directions")))
                } else if let template = a.templateId, template == b.templateId,
                          sports(a) == sports(b),
                          a.target != b.target {
                    notes.append(Note(goalId: newerId,
                                      text: String(localized: "Two goals of the same kind ask for different numbers")))
                }
            }
        }
        return notes
    }

    private static func sports(_ goal: CoachGoal) -> [String] {
        (goal.measure?.sportFilter ?? []).map { $0.lowercased() }.sorted()
    }

    private static func direction(_ goal: CoachGoal) -> Double? {
        guard let baseline = goal.baseline, let target = goal.target, baseline != target else { return nil }
        return target > baseline ? 1 : -1
    }

    static func newer(_ a: UUID, _ aDate: Date, _ b: UUID, _ bDate: Date) -> UUID {
        aDate >= bDate ? a : b
    }
}
