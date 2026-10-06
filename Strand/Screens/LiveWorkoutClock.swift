import SwiftUI
import StrandDesign

/// The sport above one large, centered elapsed clock. It is the only place elapsed time is shown, so it can
/// be the biggest thing on the screen; it dims while the workout is paused.
struct LiveWorkoutClock: View {
    let workout: AppModel.ActiveWorkout

    var body: some View {
        VStack(spacing: NoopMetrics.space1) {
            HStack(spacing: NoopMetrics.space2) {
                WorkoutTypeIcon(workoutType: workout.sport, size: 17, weight: .semibold,
                                color: StrandPalette.effortColor)
                    .accessibilityHidden(true)
                Text(WorkoutSource.localizedDisplaySport(workout.sport))
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(ActiveWorkoutClock.clock(Int(workout.elapsed())))
                    .font(StrandFont.number(76)).monospacedDigit()
                    .foregroundStyle(workout.isPaused ? StrandPalette.textTertiary : StrandPalette.effortColor)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Elapsed time"))
            .accessibilityValue(Text(ActiveWorkoutClock.clock(Int(workout.elapsed()))))
        }
        .frame(maxWidth: .infinity)
    }
}
