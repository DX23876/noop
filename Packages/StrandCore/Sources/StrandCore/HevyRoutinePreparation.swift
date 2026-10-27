import Foundation
import StrandTraining
import WhoopStore

/// The same reviewed exercise matching and routine parser on both platforms, before any plan write.
public enum HevyRoutinePreparation {
    public static func read(store: WhoopStore, exercises: [TrainingExercise], defaultRestSeconds: Int = 120,
                            currentIds: Set<String>? = nil) async throws -> TrainingRoutineImport {
        let stored = try await store.hevyRoutines()
        let routines = currentIds.map { ids in stored.filter { ids.contains($0.id) } } ?? stored
        let matcher = HevyRoutineExerciseMatcher(exercises: exercises,
            templates: try await store.strengthExerciseTemplates(), aliases: try await store.trainingExerciseAnatomyAliases())
        return HevyRoutineImporter.parse(routines.map { Data($0.rawJSON.utf8) },
            defaultRestSeconds: defaultRestSeconds, match: { matcher.match(title: $0, templateId: $1) })
    }
}
