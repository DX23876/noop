import SwiftUI
import StrandDesign

/// The sport above one large, centered elapsed clock. It is the only place elapsed time is shown, so it can
/// be the biggest thing on the screen; it dims while the workout is paused.
struct LiveWorkoutClock: View {
    let workout: AppModel.ActiveWorkout
    @ScaledMetric(relativeTo: .largeTitle) private var largeSize = 76.0
    @ScaledMetric(relativeTo: .largeTitle) private var mediumSize = 56.0
    @ScaledMetric(relativeTo: .largeTitle) private var compactSize = 42.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = Int(workout.elapsed(at: context.date))
                ViewThatFits(in: .horizontal) {
                    clock(elapsed, size: largeSize)
                    clock(elapsed, size: mediumSize)
                    clock(elapsed, size: compactSize)
                    Text(WorkoutAnnouncementText.duration(elapsed))
                        .font(StrandFont.headline).multilineTextAlignment(.center)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Elapsed time"))
                .accessibilityValue(Text(WorkoutAnnouncementText.duration(elapsed)))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func clock(_ seconds: Int, size: CGFloat) -> some View {
        Text(ActiveWorkoutClock.clock(seconds))
            .font(StrandFont.number(size)).monospacedDigit()
            .foregroundStyle(workout.isPaused ? StrandPalette.textTertiary : StrandPalette.effortColor)
            .fixedSize(horizontal: true, vertical: false)
            .contentTransition(reduceMotion ? .identity : .numericText())
    }
}
