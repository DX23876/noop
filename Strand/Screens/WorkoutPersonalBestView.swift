import SwiftUI
import StrandAnalytics
import StrandDesign

struct WorkoutPersonalBestView: View {
    let result: WorkoutPersonalBest.Result

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Label("New best recorded split", systemImage: "medal")
                .font(StrandFont.headline).foregroundStyle(StrandPalette.statusPositive)
            Text(verbatim: "\(ActiveWorkoutClock.clock(Int(result.current.seconds.rounded()))) · \(result.current.meters == 1000 ? "1 km" : "1 mi")")
                .font(StrandFont.number(32)).monospacedDigit().foregroundStyle(StrandPalette.textPrimary)
            Text("Previous: \(ActiveWorkoutClock.clock(Int(result.previous.seconds.rounded())))")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            Text("Compared with your earlier NOOP recordings of this sport and split distance. Paused workouts and GPS gaps are excluded.")
                .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(NoopMetrics.space4)
        .background(StrandPalette.surfaceRaised, in: .rect(cornerRadius: NoopMetrics.cardRadius))
        .accessibilityElement(children: .combine)
    }
}
