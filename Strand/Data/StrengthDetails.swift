import Foundation
import StrandAnalytics
import StrandCore
import StrandTraining
import WhoopStore

/// The compact strength editor and its stored provenance, shared by Apple and Android.
/// Session envelopes keep owning time, duration and heart rate; this only adds exercise details.
enum StrengthDetails {
    struct Draft: Identifiable, Sendable {
        let id = UUID()
        var title = ""
        var workSets = 3
        var muscle: HevyMuscleGroup = .other
        var effort = ""
        var usesRIR = true
    }

    /// What the form can refuse to save, so the wearer is told which field to fix rather than having a
    /// value silently dropped.
    enum DraftError: Error, Equatable {
        case noExercise
        case setCountOutOfRange
        case effortOutOfRange(exercise: String)
    }

    static func rating(for draft: Draft) throws -> Double? {
        let text = draft.effort.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty else { return nil }
        guard let value = Double(text), value.isFinite else {
            throw DraftError.effortOutOfRange(exercise: draft.title)
        }
        let rpe = draft.usesRIR ? 10 - value : value
        guard (6...10).contains(rpe) else { throw DraftError.effortOutOfRange(exercise: draft.title) }
        return rpe
    }

    /// The catalogue entry and the workout one filled-in form describes.
    ///
    /// The workout id is the session's own window (or the entry being edited), so saving twice replaces
    /// the entry instead of adding a second copy of the same session.
    static func makeEntry(drafts: [Draft], session: UnifiedTrainingSession,
                          existingId: String?, now: Int)
        throws -> (templates: [HevyExerciseTemplate], workout: HevyWorkout) {
        let valid = drafts.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !valid.isEmpty else { throw DraftError.noExercise }
        var templates: [HevyExerciseTemplate] = []
        var exercises: [HevyExercise] = []
        for (index, draft) in valid.enumerated() {
            guard (1...20).contains(draft.workSets) else { throw DraftError.setCountOutOfRange }
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = title.lowercased().filter { $0.isLetter || $0.isNumber }
            let template = HevyExerciseTemplate(id: "manual.\(draft.muscle.rawValue).\(normalized)",
                                                title: title, type: "reps_only",
                                                primaryMuscleGroup: draft.muscle,
                                                secondaryMuscleGroups: [], equipment: .other,
                                                isCustom: true)
            let rpe = try rating(for: draft)
            let sets = (0..<draft.workSets).map {
                HevySet(index: $0, type: .normal, weightKg: nil, reps: nil,
                        distanceM: nil, durationS: nil, rpe: rpe, customMetric: nil)
            }
            templates.append(template)
            exercises.append(HevyExercise(index: index, title: title, templateId: template.id,
                                          supersetId: nil, notes: nil, sets: sets))
        }
        let workout = HevyWorkout(id: existingId ?? "manual-\(session.row.startTs)-\(session.row.endTs)",
                                  title: session.row.sport, routineId: nil, notes: nil,
                                  startTs: session.row.startTs, endTs: session.row.endTs,
                                  updatedAtTs: now, createdAtTs: now, exercises: exercises,
                                  source: .manual)
        return (templates, workout)
    }

    /// The form that re-opens onto an entry already saved. Work sets, muscle and rating come back from
    /// what was stored, so an edit changes one field instead of retyping the session.
    static func drafts(from workout: HevyWorkout?,
                       templates: [String: HevyExerciseTemplate]) -> [Draft] {
        guard let workout else { return [] }
        return workout.exercises.map { exercise in
            var draft = Draft()
            draft.title = exercise.title
            draft.workSets = max(1, exercise.workingSets.count)
            draft.muscle = exercise.templateId.flatMap { templates[$0]?.primaryMuscleGroup } ?? .other
            // Stored on the RPE scale; offered back on the same scale so the number does not change
            // meaning between saving and editing.
            if let rpe = exercise.workingSets.compactMap(\.rpe).first {
                draft.usesRIR = false
                draft.effort = rpe.formatted(.number.precision(.fractionLength(0...1)))
            }
            return draft
        }
    }


    struct GenericSession: Sendable {
        var session: UnifiedTrainingSession
        var manual: HevyWorkout?
    }

    static func genericSessions(_ fused: TrainingSessionFusionResult,
                                workouts: [HevyWorkout]) -> [GenericSession] {
        fused.sessions.compactMap { session in
            guard session.kind == .strength else { return nil }
            let overlapping = workouts.filter { detail in
                let overlap = max(0, min(detail.endTs, session.row.endTs) - max(detail.startTs, session.row.startTs))
                let shorter = max(1, min(detail.endTs - detail.startTs, session.row.endTs - session.row.startTs))
                return Double(overlap) / Double(shorter) > 0.8
            }
            guard overlapping.allSatisfy({ $0.source == .manual }) else { return nil }
            return GenericSession(session: session, manual: overlapping.first)
        }
    }

    static func saveMapping(store: WhoopStore, title: String, primary: HevyMuscleGroup,
                            secondary: [HevyMuscleGroup]) async throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, primary != .other else {
            throw DraftError.noExercise
        }
        let secondary = Array(Set(secondary)).filter { $0 != primary && $0 != .other }
            .sorted { $0.rawValue < $1.rawValue }
        try await store.upsertStrengthExerciseMapping(StrengthExerciseMapping(
            normalizedTitle: strengthNormalizedTitle(title), displayTitle: title,
            primaryMuscleGroup: primary, secondaryMuscleGroups: secondary))
        let normalized = ExerciseAnatomyCatalog.normalize(title)
        let primaryIds = primary.trainingMuscleIds
        let secondaryIds = secondary.flatMap(\.trainingMuscleIds).filter { !primaryIds.contains($0) }
        if !primaryIds.isEmpty {
            let anatomy = ExerciseAnatomy(id: "user:\(normalized)", title: title, mode: .weightReps,
                movementPattern: .other, primaryMuscleIds: primaryIds,
                secondaryMuscleIds: secondaryIds, confidence: .userConfirmed)
            try await store.upsertTrainingExerciseAnatomyAlias(.init(
                key: "user|\(normalized)", source: .imported,
                normalizedTitle: normalized, anatomy: anatomy, origin: "user"))
        }
    }
}
