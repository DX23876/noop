import SwiftUI
import AppIntents
import StrandDesign

/// Pause/resume and End for a running cardio workout on the Lock Screen and in the expanded Dynamic Island.
/// Pause runs in place through `ToggleWorkoutPauseIntent`; End opens NOOP with the confirmation up, so an
/// accidental tap can pause a run but never finish it.
struct WorkoutActivityControls: View {
    let workout: NOOPActivityAttributes.Workout

    private var isPaused: Bool { workout.pausedElapsedSeconds != nil }

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: ToggleWorkoutPauseIntent()) {
                Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(StrandPalette.effortColor)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(StrandPalette.effortColor.opacity(0.22), in: Capsule())
            }
            .buttonStyle(.plain)

            if let endURL = WorkoutActivityLink.endURL {
                Link(destination: endURL) {
                    Label("End", systemImage: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(StrandPalette.statusCritical)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(StrandPalette.statusCritical.opacity(0.22), in: Capsule())
                }
            }
        }
    }
}
