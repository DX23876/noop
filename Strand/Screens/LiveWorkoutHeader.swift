import SwiftUI
import StrandDesign

/// Top bar of the live workout: minimize on the left, the recording state in the middle, and the menu that
/// holds the one rare action (discard) on the right, so the thumb zone keeps only pause and end.
struct LiveWorkoutHeader: View {
    let isPaused: Bool
    let onMinimize: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            Button("Back", systemImage: "chevron.down", action: onMinimize)
                .labelStyle(.iconOnly)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 40, height: 40)
                .background(StrandPalette.surfaceRaised, in: Circle())
                .buttonStyle(.plain)
                .accessibilityHint(Text("The workout keeps recording"))

            Spacer(minLength: 0)
            LiveWorkoutStatusPill(isPaused: isPaused)
            Spacer(minLength: 0)

            Menu("More", systemImage: "ellipsis") {
                Button("Discard workout", systemImage: "trash", role: .destructive, action: onDiscard)
            }
            .labelStyle(.iconOnly)
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.textPrimary)
            .frame(width: 40, height: 40)
            .background(StrandPalette.surfaceRaised, in: Circle())
        }
    }
}
