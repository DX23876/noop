import Foundation
import StrandAnalytics

/// Presentation stays alive on save failure; only a successful database transaction marks it saved.
struct WorkoutCompletion: Identifiable, Equatable {
    enum Status: Equatable { case saving, saved, failed }
    let recording: CompletedWorkoutRecording
    var status: Status
    var personalBest: WorkoutPersonalBest.Result? = nil
    var id: UUID { recording.id }
}
