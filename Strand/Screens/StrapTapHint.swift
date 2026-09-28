import SwiftUI
import StrandDesign

/// Introduces the strap double-tap in a running strength session. A card with the whole explanation until
/// the lifter dismisses it or logs a set from the strap (`TrainingPreferences.strapTapTipDoneKey`), then a
/// single line whose info button brings the card back.
struct StrapTapHint: View {
    @AppStorage(TrainingPreferences.strapTapTipDoneKey) private var tipDone = false
    @State private var expanded = false

    var body: some View {
        if !tipDone || expanded { card } else { line }
    }

    private var card: some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 10) {
                Label("Log sets with the strap", systemImage: "hand.tap")
                    .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text("Double-tap the strap to complete the next set with the numbers in its row. Change a number first and the sets after it follow.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    cue("1", "Set logged")
                    cue("2", "Timed set over")
                    cue("3", "Rest ends in 5 seconds")
                    cue("0", "Not logged, the phone and Lock Screen say why")
                }
                Text("Turn it off in Settings › Training.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                HStack {
                    Spacer()
                    Button("Got it") {
                        tipDone = true
                        expanded = false
                    }
                    .buttonStyle(.bordered).tint(StrandPalette.accent)
                }
            }
        }
    }

    private func cue(_ count: String, _ meaning: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(count)×")
                .font(StrandFont.subhead.monospacedDigit()).foregroundStyle(StrandPalette.accent)
                .frame(minWidth: 24, alignment: .leading)
            Text(meaning).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var line: some View {
        HStack(spacing: 8) {
            Label("Double-tap the strap: next set", systemImage: "hand.tap")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Button { expanded = true } label: {
                Image(systemName: "info.circle").foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(Text("How strap logging works"))
        }
        .padding(.horizontal, 4)
    }
}

/// Why the last strap double-tap (or the Watch's "complete set") was not logged. The text arrives already
/// localized from `NativeWorkoutSessionModel.strapNotice`, the same words the Lock Screen shows.
struct StrapTapNotice: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        NoopCard(tint: StrandPalette.statusWarning) {
            HStack(alignment: .top, spacing: 8) {
                Label { Text(verbatim: text) } icon: { Image(systemName: "hand.tap") }
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(action: dismiss) {
                    Image(systemName: "xmark").foregroundStyle(StrandPalette.textSecondary)
                }
                .buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel(Text("Dismiss"))
            }
        }
    }
}
