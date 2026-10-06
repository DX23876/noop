import SwiftUI
import StrandDesign
import StrandAnalytics

struct LiveWorkoutGuidanceView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(UnitPrefs.systemKey) private var units = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceUnits = ""
    private var system: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: units) ?? .metric, override: distanceUnits)
    }

    var body: some View {
        if let guidance = model.workoutRecording.guidance, let workout = model.activeWorkout {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    if let phase = guidance.current {
                        HStack {
                            Text(WorkoutGuidanceText.title(phase.kind)).font(StrandFont.headline)
                            Spacer(minLength: NoopMetrics.space2)
                            Text("\(guidance.index + 1) / \(guidance.phases.count)").font(StrandFont.captionNumber)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        if let remaining = guidance.remaining(seconds: workout.elapsed(at: context.date), meters: model.workoutRecording.distanceM) {
                            Text(phase.meters == nil ? ActiveWorkoutClock.clock(Int(remaining.rounded(.up)))
                                 : UnitFormatter.distanceFromMeters(remaining, system: system))
                                .font(StrandFont.number(32)).monospacedDigit()
                                .accessibilityLabel(Text("Remaining"))
                                .accessibilityValue(Text(phase.meters == nil ? WorkoutAnnouncementText.duration(Int(remaining.rounded(.up)))
                                     : UnitFormatter.distanceFromMeters(remaining, system: system)))
                        }
                        if phase.meters != nil, !model.workoutGPSIsFresh(at: context.date), !workout.isPaused {
                            Text("Distance phase waiting for GPS.").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                        }
                        Button("Next phase", systemImage: "forward.end.fill", action: model.skipWorkoutPhase)
                            .font(StrandFont.subhead).frame(minHeight: 44).disabled(workout.isPaused)
                    } else {
                        Label("Plan complete. End the workout when ready.", systemImage: "checkmark.circle")
                            .font(StrandFont.subhead)
                    }
                }
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(NoopMetrics.space4)
                .background(StrandPalette.surfaceRaised, in: .rect(cornerRadius: NoopMetrics.cardRadius))
            }
        }
    }
}
