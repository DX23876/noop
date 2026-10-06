import SwiftUI
import StrandDesign

/// "Recording" with a red dot while the workout runs, "Paused" in amber while it is paused.
struct LiveWorkoutStatusPill: View {
    let isPaused: Bool

    private var tint: Color { isPaused ? StrandPalette.statusWarningForeground : StrandPalette.metricRose }

    var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            Circle().fill(tint).frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(isPaused
                 ? String(localized: "Paused")
                 // Its own key: the bare Recording key is translated as a noun in several languages.
                 : String(localized: "workout.status.recording", defaultValue: "Recording"))
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .textCase(.uppercase)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, NoopMetrics.space3)
        .padding(.vertical, NoopMetrics.space2)
        .background(tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
