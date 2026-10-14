import SwiftUI
import StrandDesign

/// Continuous HRV and its "Nights only" refinement, on the Battery & Recording page beside Power saving
/// (2026-10 Settings reorganisation; it lived in Settings' HRV card before). Same keys and the same BLE
/// wiring as before: `BLEManager.setKeepRealtimeForData(_:)` re-arms the stream on every change.
struct ContinuousHrvSettingsCard: View {
    @EnvironmentObject var model: AppModel

    @AppStorage(PuffinExperiment.keepRealtimeForDataKey) private var continuousHrvEnabled = false
    /// The default MUST match `PuffinExperiment.continuousHrvOvernightOnlyEnabled` (#1008): both read the
    /// same key by different routes, and a mismatch shows the switch off while capture is nights-only.
    @AppStorage(PuffinExperiment.continuousHrvOvernightOnlyKey) private var continuousHrvOvernightOnly = true

    var body: some View {
        SettingsSection(
            icon: "waveform.path.ecg",
            title: "Continuous HRV",
            blurb: "Keeps the beat-to-beat heart-rate stream running, not only while Live is open. More detail for night HRV, recovery and sleep. Uses more strap battery."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Toggle(isOn: $continuousHrvEnabled) {
                    Text("Continuous HRV")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .appleInspiredTint("settings.controls")
                .onChangeCompat(of: continuousHrvEnabled) { on in model.ble.setKeepRealtimeForData(on) }

                // #927: window-gate the continuous stream to the nightly quiet-hours window.
                if continuousHrvEnabled {
                    Toggle(isOn: $continuousHrvOvernightOnly) {
                        Text("Nights only")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .toggleStyle(.switch)
                    .appleInspiredTint("settings.controls")
                    .onChangeCompat(of: continuousHrvOvernightOnly) { _ in
                        model.ble.setKeepRealtimeForData(PuffinExperiment.keepRealtimeForDataEnabled)
                    }
                    Text("Records only in your quiet hours (22:00 to 07:00 by default), which roughly halves the battery cost. Daytime stress and naps get fewer readings. For a daytime reading, use \"Take an HRV reading\" on Live.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
