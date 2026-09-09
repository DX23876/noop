import Foundation
import WhoopStore

extension AICoachEngine {
    func proposeHevyWorkoutTool(input: [String: Any], proposals: HevyWorkoutProposalStore = .shared) async -> String {
        guard HevyCredentials.isConnected else { return "Nothing drafted: Hevy is not connected." }
        guard let store = await repo.storeHandle() else { return "Nothing drafted: local store unavailable." }
        let catalogue = (try? await store.hevyExerciseTemplates()) ?? [:]
        let operation = HevyWorkoutProposal.Operation(rawValue: input["operation"] as? String ?? "create") ?? .create
        let now = Int(Date().timeIntervalSince1970)
        guard let start = Self.workoutInt(input["start_ts"]), start <= now + 300,
              let end = Self.workoutInt(input["end_ts"]), end >= start else {
            return "Nothing drafted: start/end must describe a completed, non-future workout."
        }
        let title = (input["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "Nothing drafted: the workout needs a title." }

        var previous: HevyWorkout?
        var workoutId = "pending-\(UUID().uuidString)"
        if operation == .update {
            guard let id = input["workout_id"] as? String else {
                return "Nothing drafted: a correction needs the exact workout_id from get_strength_history."
            }
            previous = (try? await store.hevyWorkouts(from: 0, to: now + 86_400, limit: 4_000))?
                .first { $0.id == id }
            guard previous != nil else { return "Nothing drafted: that API workout was not found locally." }
            workoutId = id
        }

        guard let rawExercises = input["exercises"] as? [[String: Any]], !rawExercises.isEmpty else {
            return "Nothing drafted: at least one exercise is required."
        }
        var exercises: [HevyExercise] = []
        for (exerciseIndex, raw) in rawExercises.prefix(30).enumerated() {
            guard let templateId = raw["exercise_template_id"] as? String,
                  let template = catalogue[templateId] else {
                return "Nothing drafted: every exercise_template_id must come from find_hevy_exercises."
            }
            guard let rawSets = raw["sets"] as? [[String: Any]], !rawSets.isEmpty else {
                return "Nothing drafted: \(template.title) has no sets."
            }
            let sets = rawSets.prefix(50).enumerated().compactMap { index, raw -> HevySet? in
                let weight = Self.workoutDouble(raw["weight_kg"])
                let reps = Self.workoutInt(raw["reps"])
                let rpe = Self.workoutDouble(raw["rpe"])
                guard weight != nil || reps != nil else { return nil }
                guard weight.map({ $0 >= 0 && $0 <= 1_000 }) ?? true,
                      reps.map({ $0 >= 0 && $0 <= 1_000 }) ?? true,
                      rpe.map({ $0 >= 0 && $0 <= 10 }) ?? true else { return nil }
                return HevySet(index: index, type: HevySetType.parse(raw["type"] as? String),
                               weightKg: weight, reps: reps, distanceM: nil, durationS: nil,
                               rpe: rpe, customMetric: nil)
            }
            guard !sets.isEmpty else { return "Nothing drafted: \(template.title) has no valid sets." }
            exercises.append(HevyExercise(index: exerciseIndex, title: template.title,
                                           templateId: templateId, supersetId: nil,
                                           notes: nil, sets: sets))
        }
        let workout = HevyWorkout(id: workoutId, title: title, routineId: previous?.routineId,
                                  notes: input["notes"] as? String, startTs: start, endTs: end,
                                  updatedAtTs: now, createdAtTs: previous?.createdAtTs ?? start,
                                  exercises: exercises)
        let proposal = HevyWorkoutProposal(operation: operation, workout: workout,
                                           previousWorkout: previous,
                                           rationale: input["rationale"] as? String ?? "")
        guard proposals.propose(proposal) else { return "Nothing drafted: the proposal was empty." }
        return "Workout draft ready for review: \(title), \(exercises.count) exercises. Nothing has been sent to Hevy."
    }

    private static func workoutInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Double, value.isFinite { return Int(value) }
        return nil
    }

    private static func workoutDouble(_ value: Any?) -> Double? {
        if let value = value as? Double, value.isFinite { return value }
        if let value = value as? Int { return Double(value) }
        return nil
    }
}
