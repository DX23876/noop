import SwiftUI
import StrandDesign

// MARK: - Battery & Recording (#477, 2026-10 Settings reorganisation)
//
// Power saving was lifted out of Settings into its own screen (#477). The 2026-10 reorganisation made
// it the Settings page "Battery & Recording" and put Continuous HRV beside it: the two pull in opposite
// directions (Continuous HRV is the biggest steady drain on the strap, "Pause HRV capture" is the
// biggest saving), so they belong on one page. The controls, their prefs and their wiring are
// UNCHANGED — `AppModel.applyPowerSaving()` still reads every value from `PuffinExperiment`.
//
// The master gates the sub-options: the threshold slider, "Pause HRV capture" and "Low refresh" only
// appear (and only apply) while Power saving is on — `applyPowerSaving` ANDs each one with the master.
struct PowerSavingView: View {
    @EnvironmentObject var model: AppModel

    @AppStorage(PuffinExperiment.powerSavingKey) private var powerSavingEnabled = false
    @AppStorage(PuffinExperiment.powerSavingBatteryPctKey) private var powerSavingPct = 20
    /// Stored INVERTED so the default (absent = false) reads as "HRV pause on". The toggle shows `!this`.
    @AppStorage(PuffinExperiment.pauseHrvDisabledKey) private var pauseHrvDisabled = false
    @AppStorage(PuffinExperiment.lowRefreshKey) private var lowRefreshEnabled = false

    var body: some View {
        ScreenScaffold(title: "Battery & Recording",
                       subtitle: "Power saving and continuous HRV",
                       topBackground: liquidScaffoldSky()) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                ContinuousHrvSettingsCard()
                SettingsSection(
                    icon: "battery.25",
                    title: "Power saving",
                    blurb: "The strap keeps banking data on its own, so nothing is lost — NOOP just talks to it less often to help it last until you can charge it."
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle(isOn: $powerSavingEnabled) {
                            Text("Power saving mode")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                        }
                        .toggleStyle(.switch)
                        .tint(StrandPalette.accent)
                        .onChangeCompat(of: powerSavingEnabled) { _ in model.applyPowerSaving() }
                        Text("Slows background strap-sync (every 45 min instead of 15) while your strap's battery is low. No data loss — the strap banks everything, so sync just batches into larger, less frequent pulls.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)

                        if powerSavingEnabled {
                            rowDivider
                            HStack {
                                Text("Kick in at (strap battery)")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Spacer()
                                Text(verbatim: "\(powerSavingPct)%")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.accent)
                            }
                            // 10…35 in 5s. 35 buys one more step of strap life than the old 30 ceiling:
                            // the levers engage ~5% earlier in the discharge, at the cost of a slightly
                            // longer stretch of quieter syncing.
                            Slider(
                                value: Binding(get: { Double(powerSavingPct) }, set: { powerSavingPct = Int($0) }),
                                in: 10...35, step: 5,
                                onEditingChanged: { editing in if !editing { model.applyPowerSaving() } }
                            )
                            .tint(StrandPalette.accent)

                            rowDivider
                            // HRV pause: a sub-option, ON by default when the master is on (stored inverted).
                            Toggle(isOn: Binding(get: { !pauseHrvDisabled }, set: { pauseHrvDisabled = !$0 })) {
                                Text("Pause HRV capture")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                            }
                            .toggleStyle(.switch)
                            .tint(StrandPalette.accent)
                            .onChangeCompat(of: pauseHrvDisabled) { _ in model.applyPowerSaving() }
                            Text("While your strap's battery is low, stop the always-on background HRV stream — the biggest continuous drain on the strap. A Live screen still shows heart rate, and it re-arms automatically once the strap is charged.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            rowDivider
                            // Low refresh: a sub-option that applies at ANY charge, not just below the threshold.
                            Toggle(isOn: $lowRefreshEnabled) {
                                Text("Low refresh")
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                            }
                            .toggleStyle(.switch)
                            .tint(StrandPalette.accent)
                            .onChangeCompat(of: lowRefreshEnabled) { _ in model.applyPowerSaving() }
                            Text("Sync in the background every hour instead of every 15 minutes, whatever the strap's charge — fewer reconnections is the biggest saving on a WHOOP 4.0. Nothing is lost: the strap banks everything and hands it over in larger batches. Pull to sync still runs straight away, and live heart rate is untouched.")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .padding(.vertical, 4)
    }
}
