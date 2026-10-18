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

/// Actions for the current strength set or rest. The activity carries exact identities so a stale
/// button cannot operate on a newer set or a replacement timer.
struct StrengthActivityControls: View {
    let workout: NOOPActivityAttributes.Workout

    var body: some View {
        if workout.pausedElapsedSeconds == nil, let session = workout.strengthSessionId {
            if let restEnd = workout.restEndsAt {
                HStack(spacing: NoopMetrics.space2) {
                    restButton("−15", session: session, end: restEnd, seconds: -15)
                    restButton("+15", session: session, end: restEnd, seconds: 15)
                    restButton("Skip", session: session, end: restEnd, seconds: 0)
                }
            } else if let next = workout.nextSet, next.canComplete {
                Button(intent: CompleteStrengthSetIntent(sessionId: session, setId: next.id)) {
                    Label("Set done", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: NoopMetrics.controlHeight)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .background(StrandPalette.chargeColor, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func restButton(_ title: LocalizedStringKey, session: String,
                            end: Date, seconds: Int) -> some View {
        Button(intent: AdjustStrengthRestIntent(sessionId: session,
                                                expectedEnd: Int(end.timeIntervalSince1970),
                                                seconds: seconds)) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: NoopMetrics.controlHeight)
                .foregroundStyle(StrandPalette.metricAmber)
                .background(StrandPalette.metricAmber.opacity(0.22), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
