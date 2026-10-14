import SwiftUI
import StrandDesign

// MARK: - Heart rate sharing
//
// Both ways of sharing live heart rate with other devices, side by side (2026-10 Settings
// reorganisation). They used to live apart: the phone broadcaster on Data Sources, the strap's own
// broadcast on Data Sources AND in the 5/MG experiments card, whose title promised "Garmin/ANT" although
// both paths are Bluetooth only.
//
// The phone broadcaster is owned by THIS screen and stops when it closes, exactly as it did on Data
// Sources — a foreground convenience, not a background service. The strap broadcast is a stored
// device-config flag and keeps running without the app.

struct HeartRateSharingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState

    @AppStorage(HrBroadcaster.defaultsKey) private var phoneBroadcastEnabled = false
    @AppStorage(PuffinExperiment.broadcastHrKey) private var strapBroadcastEnabled = false
    /// Same gate the rest of Settings uses for 5/MG-only controls (see `SettingsView.showFiveMGControls`).
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop4.rawValue

    // The broadcaster's diagnostic sink forwards to this box, which `onAppear` points at `live`, so the
    // broadcast-out lifecycle lines land in the same exported strap log the WHOOP path writes (#421).
    private final class LogSink { weak var live: LiveState? }
    private let broadcastLogSink: LogSink
    @StateObject private var hrBroadcaster: HrBroadcaster

    init() {
        let sink = LogSink()
        self.broadcastLogSink = sink
        _hrBroadcaster = StateObject(wrappedValue: HrBroadcaster(log: { [weak sink] line in
            // HrBroadcaster is @MainActor, so it only ever calls this closure from the main actor.
            MainActor.assumeIsolated { sink?.live?.append(log: line) }
        }))
    }

    #if os(macOS)
    private static let phoneTitle: LocalizedStringKey = "Via this Mac"
    #else
    private static let phoneTitle: LocalizedStringKey = "Via iPhone"
    #endif

    private var strapCanBroadcast: Bool { selectedWhoopModelRaw == WhoopModel.whoop5mg.rawValue }

    var body: some View {
        ScreenScaffold(title: "Heart rate sharing",
                       subtitle: "Let a treadmill, bike computer, Zwift or a sports watch read your heart rate.",
                       topBackground: liquidScaffoldSky()) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                phoneCard
                if strapCanBroadcast { strapCard }
            }
        }
        .onAppear {
            broadcastLogSink.live = live
            hrBroadcaster.bind(to: live)
            if phoneBroadcastEnabled { hrBroadcaster.start() }
        }
        .onDisappear {
            // A foreground convenience tied to this screen's owned object: release the radio when the
            // screen goes away; revisiting with the switch on starts it again.
            hrBroadcaster.stop()
        }
    }

    private var phoneCard: some View {
        SettingsSection(
            icon: "iphone.radiowaves.left.and.right",
            title: Self.phoneTitle,
            blurb: "Acts as a standard Bluetooth heart-rate sensor. Works with every strap. Shares only while this screen is open."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Toggle(isOn: $phoneBroadcastEnabled) {
                    Text(Self.phoneTitle)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .appleInspiredTint("settings.controls")
                .accessibilityLabel(Self.phoneTitle)
                .onChangeCompat(of: phoneBroadcastEnabled) { on in
                    if on { hrBroadcaster.start() } else { hrBroadcaster.stop() }
                }
                if phoneBroadcastEnabled { phoneStatus }
            }
        }
    }

    /// Honest live status only while it is on: a warning when the radio cannot run, else who is reading
    /// it or that it is waiting (never a fabricated "connected").
    @ViewBuilder private var phoneStatus: some View {
        if let note = hrBroadcaster.statusNote {
            Text(note)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusWarningForeground)
                .fixedSize(horizontal: false, vertical: true)
        } else if hrBroadcaster.subscriberCount > 0 {
            let n = hrBroadcaster.subscriberCount
            // Whole-phrase variants per count so translators never see a stitched plural.
            Text(n == 1 ? "1 device reading your heart rate"
                        : "\(n) devices reading your heart rate")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
        } else if let hr = live.heartRate {
            Text("Sharing \(hr) bpm. Waiting for a device to pair.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        } else {
            Text("No live heart rate yet. Open Live to pair your strap.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var strapCard: some View {
        SettingsSection(
            icon: "antenna.radiowaves.left.and.right",
            title: "Via strap",
            blurb: "WHOOP 5.0 and MG only. The strap sends its heart rate itself over Bluetooth, even without your iPhone nearby. Uses more strap battery."
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.rowSpacing) {
                Toggle(isOn: $strapBroadcastEnabled) {
                    Text("Via strap")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .appleInspiredTint("settings.controls")
                .accessibilityLabel("Share heart rate via the strap")
                .onChangeCompat(of: strapBroadcastEnabled) { on in model.ble.setBroadcastHr(on) }
                Text("Applies on the next connection, or right away when connected. Writes a setting on the strap that turning this off reverses. Needs an iPhone: a Mac can't write to a 5/MG.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                // #573: leaving it on keeps the strap radio advertising continuously.
                if strapBroadcastEnabled {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "battery.25")
                            .foregroundStyle(StrandPalette.statusWarningForeground)
                            .accessibilityHidden(true)
                        Text("Your strap is sending its heart rate right now and drains its battery faster. Turn this off when no other device needs it.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.statusWarningForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}
