import SwiftUI
import StrandDesign

/// A one-time pointer to the Updates inbox on Liquid Today. Its only entry is the Forge "F" beside the
/// NOOP wordmark, which reads as a logo, so a new note there went unseen. The hint names the mark and
/// keeps coming back, once per launch, until the wearer ticks "Don't show again": closing it without the
/// tick means it was dismissed, not understood.
struct UpdatesMarkHint: View {
    static let dismissedKey = "updates.markHintDismissed"
    /// Shown once per launch at most, so it does not reappear on every visit to Today.
    @MainActor static var shownThisLaunch = false

    /// Close the hint. `dontShowAgain` is the tick's state at that moment.
    let onClose: (_ dontShowAgain: Bool) -> Void
    /// Close it and open the inbox right away.
    let onOpenInbox: (_ dontShowAgain: Bool) -> Void

    @State private var dontShowAgain = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space3) {
                    ForgeMark(size: 22)
                        .shadow(color: StrandPalette.forgeEmber.opacity(0.8), radius: 6)
                        .accessibilityHidden(true)
                    Text("Your updates live behind the F")
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Tap the glowing F next to NOOP at the top of Today to open your notifications: new features, strap notes and goal news.")
                    .font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: toggleDontShowAgain) {
                    Label("Don't show again", systemImage: dontShowAgain ? "checkmark.square.fill" : "square")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(dontShowAgain ? .isSelected : [])
                HStack(spacing: NoopMetrics.space3) {
                    Button("Close", action: close)
                        .buttonStyle(.bordered)
                    Button("Open updates", action: openInbox)
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            }
            .padding(NoopMetrics.cardPadding)
            // Opaque: a glass card let Today's cards show through and the text read poorly.
            .background(StrandPalette.surfaceBase,
                        in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius))
            .frame(maxWidth: 420)
            .padding(NoopMetrics.screenPadding)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }

    private func toggleDontShowAgain() {
        dontShowAgain.toggle()
    }

    private func close() {
        onClose(dontShowAgain)
    }

    private func openInbox() {
        onOpenInbox(dontShowAgain)
    }
}
