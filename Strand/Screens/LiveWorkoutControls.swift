import SwiftUI
import StrandDesign

/// Two large controls, Workout-app style: pause or resume, and end. Discard lives in the header menu so the
/// thumb zone holds only the two actions used in every session.
struct LiveWorkoutControls: View {
    let isPaused: Bool
    let onTogglePause: () -> Void
    let onEnd: () -> Void

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            LiveWorkoutControlButton(title: isPaused ? "Resume" : "Pause",
                                     symbol: isPaused ? "play.fill" : "pause.fill",
                                     tint: StrandPalette.effortColor,
                                     action: onTogglePause)
            LiveWorkoutControlButton(title: "End", symbol: "xmark",
                                     tint: StrandPalette.statusCritical,
                                     action: onEnd)
                .accessibilityHint(Text("Stops recording and saves what's captured so far"))
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.top, NoopMetrics.space3)
        .padding(.bottom, NoopMetrics.space2)
        .background(StrandPalette.surfaceBase.opacity(0.94).ignoresSafeArea(edges: .bottom))
    }
}
