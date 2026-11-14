import SwiftUI
import StrandDesign

/// More than one WHOOP answered the scan and this install names none of them, so nothing has connected
/// yet (`StrapClaim`). The wearer picks; the strongest signal is first, which is almost always the strap
/// on this wrist, and the card claims nothing it cannot know. Putting it away leaves every strap alone
/// rather than falling back to the first one, which is the behaviour this card exists to end.
///
/// Observes the manager itself, as `WhoopPickList` does, so the Devices body is not re-evaluated by a
/// scan that concerns it in no other way.
struct StrapChoiceCard: View {
    @ObservedObject var ble: BLEManager
    let onPick: ((uuid: String, name: String, rssi: Int)) -> Void
    let onDismiss: () -> Void

    var body: some View {
        if !ble.strapChoice.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("More than one WHOOP nearby")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text("NOOP has not been told which strap is yours, and the first one it connects to keeps the entry. Pick yours — the strongest signal is listed first.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(ble.strapChoice, id: \.uuid) { strap in
                    Button(strap.name.isEmpty ? String(localized: "Unnamed strap") : strap.name) {
                        onPick(strap)
                    }
                    .buttonStyle(.bordered)
                }
                Button("Not now", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.accent)
            }
            .padding(NoopMetrics.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NoopPanelSurface(cornerRadius: 18))
        }
    }
}

