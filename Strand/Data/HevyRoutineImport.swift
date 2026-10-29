import Foundation
import StrandCore
import StrandTraining
import WhoopStore

extension Repository {
    /// Hevy's saved routines as NOOP routines, for the wearer to pick from before anything is stored.
    /// Routines are pulled fresh when Hevy is connected, because the regular sync fetches them rarely;
    /// without a connection the routines an earlier sync stored are offered.
    func hevyRoutineImport(exercises: [TrainingExercise],
                           defaultRestSeconds: Int) async throws -> TrainingRoutineImport {
        guard let store = await storeHandle() else { throw RepositoryTrainingError.storeUnavailable }
        var current: Set<String>?
        if HevyCredentials.isConnected {
            current = try? await HevySyncCoordinator(fetcher: HevyAPIClient(), store: store).refreshRoutines()
        }
        return try await HevyRoutinePreparation.read(store: store, exercises: exercises,
            defaultRestSeconds: defaultRestSeconds, currentIds: current)
    }
}
