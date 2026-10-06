import SwiftUI
import StrandDesign

struct LiveWorkoutSectionsPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                if let workout = model.activeWorkout {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        WorkoutRecordingSectionsView(timeline: model.workoutRecording,
                            seconds: workout.elapsed(at: context.date), sport: workout.sport, isLive: true)
                    }
                    if model.workoutRecording.laps.isEmpty && model.workoutRecording.distanceM == 0 {
                        Text("Mark a lap to compare sections. GPS adds automatic distance splits.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Button("Mark lap", systemImage: "flag.fill", action: model.markWorkoutLapNow)
                        .font(StrandFont.headline).frame(maxWidth: .infinity, minHeight: 44)
                        .buttonStyle(.bordered).tint(StrandPalette.accent).disabled(workout.isPaused)
                }
            }
            .screenPadding().padding(.vertical, NoopMetrics.space4)
        }
    }
}
