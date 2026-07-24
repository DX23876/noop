import SwiftUI
import StrandDesign

// MARK: - Heute active-workout indicator
//
// Heute's own port of the shared `ActiveWorkoutIndicatorSection` (`Strand/Screens/TodayView.swift`) —
// classic Today and Liquid Today both render that SAME leaf so they never drift (see its own doc
// comment: "sharing one implementation keeps the two Today screens... from drifting"). Heute can't
// reuse it directly: that leaf is hardcoded to `StrandPalette`/`NoopCard`, and would look visually
// off-brand dropped into Heute's `HeuteRedesignPalette` skin — same reasoning as
// `HeuteHeartRateView`/`HeuteChargeBreakdownView`, which port the shared PURE logic but own their
// rendering. Heute had no active-workout indicator at all before this; the pure model
// (`ActiveWorkoutIndicatorModel.make(from:)` / `.elapsed(since:now:)`) is reused verbatim so the elapsed
// clock and workout detection can never disagree between the three Today screens.

struct HeuteActiveWorkoutIndicatorSection: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var router: NavRouter

    var body: some View {
        if let model = ActiveWorkoutIndicatorModel.make(from: app.activeWorkout) {
            HeuteActiveWorkoutIndicatorCard(model: model) {
                StrandHaptic.selection.play()
                router.openActiveWorkout()
            }
            .transition(.opacity)
        }
    }
}

private struct HeuteActiveWorkoutIndicatorCard: View {
    let model: ActiveWorkoutIndicatorModel
    let onReturn: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(HeuteRedesignPalette.heart)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text("WORKOUT IN PROGRESS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(HeuteRedesignPalette.heart)
                Spacer(minLength: 8)
                // Per-second live clock — only this Text re-evaluates on the tick, matching the shared
                // card's own leaf-isolation rationale.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(ActiveWorkoutIndicatorModel.elapsed(since: model.startedAt, now: context.date))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(HeuteRedesignPalette.ink)
                }
            }
            HStack(alignment: .center, spacing: 10) {
                Text(model.sport)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(HeuteRedesignPalette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                Button(action: onReturn) {
                    HStack(spacing: 6) {
                        Text("Return")
                        Image(systemName: "arrow.forward.circle.fill")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(HeuteRedesignPalette.heart, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Return to workout")
            }
        }
        .padding(16)
        .background(HeuteRedesignPalette.tile, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(HeuteRedesignPalette.line, lineWidth: 1))
        // One VoiceOver stop: dot + label + clock + sport + button read as a single actionable item.
        .accessibilityElement(children: .combine)
    }
}
