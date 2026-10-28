import Foundation
import StrandCore
import WhoopStore

/// The drafts the coach leaves for the wearer to decide (`CoachView.actionRow`'s review chips): a Hevy routine
/// (`HevyRoutineReviewView`) and a Hevy workout (`HevyWorkoutReviewView`). The coach only drafts; sending is the
/// wearer's tap, through the iOS writers and `HevyAPIClient` with the key Android hands in at `coach.configure`.
@MainActor
enum CoreCoachDrafts {
    struct Exercise: Encodable { var title: String, superset: String?, sets: [String], rest: String?, notes: String? }
    struct Routine: Encodable {
        var id: String, header: String, title: String, counts: String, rationale: String
        var warnings: [String]
        /// Set for a change to an existing routine: what goes and what comes (`replacementNotice`).
        var replaces: Bool, removed: [String], added: [String]
        var exercises: [Exercise]
        var error: String?
    }
    struct WorkoutCard: Encodable { var label: String, title: String, date: String, exercises: [Exercise], volume: String }
    struct Workout: Encodable {
        var id: String, header: String, cards: [WorkoutCard], createNote: String?, error: String?
    }
    struct Output: Encodable {
        var routine: Routine?
        var workout: Workout?
        /// The first goal and routine draft waiting, opened with `coach.drafts.goal.open`.
        var goalId: String?
        var sent: String?
        var error: String?
        var labels: [String: String]
    }

    static func run(_ op: String, _ args: [String: Any], store: WhoopStore?) async -> Output {
        let unit = TrainingWeightUnit(rawValue: args["weightUnit"] as? String ?? "") ?? .kilograms
        let id = (args["id"] as? String).flatMap(UUID.init(uuidString:))
        var sent: String?, error: String?
        switch (op, id) {
        case ("coach.drafts.routine.decline", let id?): HevyRoutineProposalStore.shared.decide(id, as: .declined)
        case ("coach.drafts.workout.decline", let id?): HevyWorkoutProposalStore.shared.decide(id, as: .declined)
        case ("coach.drafts.routine.send", let id?):
            guard let proposal = HevyRoutineProposalStore.shared.proposal(id: id) else { break }
            do {
                _ = try await HevyRoutineWriter.send(proposal, using: HevyAPIClient())
                HevyRoutineProposalStore.shared.decide(id, as: .sent)
                sent = String(format: "Sent “%@” to Hevy.".localizedCatalogValue, proposal.title)
            } catch let failure {
                // Kept as `.failed`, so the wearer is offered a retry rather than the draft quietly reappearing.
                let text = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
                HevyRoutineProposalStore.shared.decide(id, as: .failed, error: text)
                error = text
            }
        case ("coach.drafts.workout.send", let id?):
            guard let proposal = HevyWorkoutProposalStore.shared.proposal(id: id) else { break }
            do {
                let saved = try await HevyWorkoutWriter.send(proposal, using: HevyAPIClient())
                _ = try? await store?.upsertHevyWorkouts([saved])
                HevyWorkoutProposalStore.shared.decide(id, as: .sent)
                sent = "Send to Hevy".localizedCatalogValue
            } catch let failure {
                let text = (failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription
                HevyWorkoutProposalStore.shared.decide(id, as: .failed, error: text)
                error = text
            }
        default: break
        }
        return Output(routine: HevyRoutineProposalStore.shared.pending.first.map(routine),
                      workout: HevyWorkoutProposalStore.shared.pending.first.map { workout($0, unit: unit) },
                      goalId: CoachGoalSetupProposalStore.shared.pending.first?.id.uuidString,
                      sent: sent, error: error, labels: labels)
    }

    static func routine(_ p: HevyRoutineProposal) -> Routine {
        var removed: [String] = [], added: [String] = []
        let replaces = p.operation == .update && p.previousExercises != nil
        if replaces, let previous = p.previousExercises {
            let kept = Set(p.exercises.map(\.templateId))
            removed = previous.filter { !kept.contains($0.templateId) }.map(\.title)
            let before = Set(previous.map(\.templateId))
            added = p.exercises.filter { !before.contains($0.templateId) }.map(\.title)
        }
        return Routine(
            id: p.id.uuidString,
            header: (p.operation == .update ? "Change to a routine" : "New routine").localizedCatalogValue,
            title: p.title,
            counts: String(format: "%lld exercises · %lld working sets".localizedCatalogValue, p.exercises.count, p.totalWorkingSets),
            rationale: p.rationale, warnings: p.warnings, replaces: replaces, removed: removed, added: added,
            exercises: p.exercises.map { e in
                Exercise(title: e.title,
                         superset: e.supersetId.map { String(format: "Superset %lld".localizedCatalogValue, $0 + 1) },
                         sets: e.sets.map(\.summary),
                         rest: e.restSeconds.flatMap { $0 > 0 ? String(format: "Rest %llds".localizedCatalogValue, $0) : nil },
                         notes: e.notes?.isEmpty == false ? e.notes : nil)
            },
            error: p.lastError)
    }

    static func workout(_ p: HevyWorkoutProposal, unit: TrainingWeightUnit) -> Workout {
        func card(_ w: HevyWorkout, _ label: String) -> WorkoutCard {
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            let volume = w.exercises.flatMap(\.workingSets).compactMap(\.volumeLoadKg).reduce(0, +)
            return WorkoutCard(
                label: label.localizedCatalogValue, title: w.title,
                date: f.string(from: Date(timeIntervalSince1970: TimeInterval(w.startTs))),
                exercises: w.exercises.map { e in
                    Exercise(title: e.title, superset: nil, sets: [e.sets.map { setText($0, unit) }.joined(separator: " · ")],
                             rest: nil, notes: nil)
                },
                volume: "Volume".localizedCatalogValue + ": " + TrainingPreferences.formattedWeight(volume, unit: unit))
        }
        var cards: [WorkoutCard] = []
        if let previous = p.previousWorkout { cards.append(card(previous, "Before")) }
        cards.append(card(p.workout, p.operation == .update ? "After" : "Workout"))
        return Workout(
            id: p.id.uuidString,
            header: (p.operation == .update ? "Workout correction" : "Completed workout").localizedCatalogValue,
            cards: cards,
            createNote: p.operation == .create
                ? "The documented Hevy API does not provide workout deletion. Check this new workout carefully before sending.".localizedCatalogValue
                : nil,
            error: p.lastError)
    }

    /// One logged set as `HevyWorkoutReviewView.setText` writes it.
    static func setText(_ set: HevySet, _ unit: TrainingWeightUnit) -> String {
        var text = "\(set.weightKg.map { TrainingPreferences.formattedWeight($0, unit: unit) } ?? "bodyweight") × \(set.reps.map(String.init) ?? "—")"
        if let rpe = set.rpe { text += " @ RPE \(String(format: "%.1f", rpe))" }
        return text
    }

    static var labels: [String: String] {
        [
            "routineTitle": "Routine draft", "workoutTitle": "Hevy workout", "later": "Later", "close": "Close",
            "hevy": "Hevy", "review": "Review before sending",
            "nothingSent": "Nothing has been sent to Hevy. Your account is unchanged until you send this.",
            "worth": "Worth a look", "check": "Check",
            "checkNote": "These come from NOOP's own check against your recent training, not from the coach. You can send it anyway.",
            "changes": "What changes", "beforeAfter": "Before and after",
            "replaces": "Sending this replaces the whole routine in Hevy — the exercises below are the routine afterwards.",
            "removed": "Removed", "added": "Added", "same": "Same exercises — only the sets change.",
            "routine": "The routine", "sets": "Sets",
            "send": "Send to Hevy", "sending": "Sending…", "discard": "Discard", "decline": "Decline",
            "onlyButton": "The coach can't send this by itself — only this button does.",
            "decided": "This draft has already been decided.", "askAgain": "Ask the coach for a new one if you still want it.",
            "reviewRoutine": "Review routine", "reviewWorkout": "Review workout",
        ].mapValues(\.localizedCatalogValue)
    }
}
