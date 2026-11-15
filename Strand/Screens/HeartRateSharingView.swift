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
                       subtitle: classicOnlySubtitle("Let a treadmill, bike computer, Zwift or a sports watch read your heart rate."),
                       topBackground: liquidScaffoldSky()) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                phoneCard
                if strapCanBroadcast { strapCard }
            }
        }
        .pagePicture("heart.fill", accent: "antenna.radiowaves.left.and.right", tint: StrandPalette.metricRose)
        .onAppear {
            broadcastLogSink.live = live
            hrBroadcaster.bind(to: live)
            if phoneBroadcastEnabled { hrBroadcaster.start() }
            // Ask the strap what it is actually doing, here and when the link comes up. Deliberately not on
            // every connect: the decision was that NOOP sends an unasked strap nothing, and this is the
            // moment somebody wants the answer. A read changes no setting.
            readSharingWhenPossible()
        }
        .onChangeCompat(of: live.bonded) { _ in readSharingWhenPossible() }
        .onDisappear {
            // A foreground convenience tied to this screen's owned object: release the radio when the
            // screen goes away; revisiting with the switch on starts it again.
            hrBroadcaster.stop()
        }
    }

    /// Ask the strap, when there is a strap to ask.
    ///
    /// Called on appear AND when the bond lands, because the usual way into this page is to open it while
    /// the app is still reconnecting: the first attempt then finds nothing, and keyed on appear alone the
    /// card would keep saying "unknown" and telling the wearer to connect a strap that connected two
    /// seconds ago — on the one page whose job is to answer that question.
    private func readSharingWhenPossible() {
        guard strapCanBroadcast, live.connected, live.bonded else { return }
        model.ble.readStrapSharingState()
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
                strapStatus
                strapStopButton
            }
        }
    }

    /// What the STRAP says, never what the switch above says.
    ///
    /// The two are different facts and this is the one that matters: the flag lives on the strap and
    /// survives a reinstall, a new phone, or an off that never reached it, so a switch reading off is no
    /// evidence at all. A wearer whose strap drains in three days instead of ten needs to be able to see
    /// which of the two they are in, and until 2026-11-15 the warning below was keyed on the switch — so
    /// it appeared only when the app already knew, and stayed hidden in exactly the case it exists for.
    @ViewBuilder private var strapStatus: some View {
        switch live.strapSharingOn {
        case true?:
            // #573: leaving it on keeps the strap radio advertising continuously.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "battery.25")
                    .foregroundStyle(StrandPalette.statusWarningForeground)
                    .accessibilityHidden(true)
                Text("Your strap is sending its heart rate right now, to anything in range, even when nothing is connected to it. That drains it much faster. Turn it off when no other device needs it.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.statusWarningForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        case false?:
            Text("Your strap says it is not sharing.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        case nil:
            Text("Connect your strap to see whether it is sharing. This is a setting on the strap itself, so it can be on even when this switch is off.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The way back for a strap that is sharing although nothing in the app asked it to.
    ///
    /// Hidden only when the strap itself has said it is not sharing. While that is unknown the button
    /// stays, because "we have not asked" is the state a stranded strap sits in and the one where a wearer
    /// most needs something to press.
    @ViewBuilder private var strapStopButton: some View {
        if live.strapSharingOn != false {
            VStack(alignment: .leading, spacing: 6) {
                // Deliberately NOT followed by a read: the write runs its own 121 read-back and
                // `finishBroadcastHrWrite` records the state from it. A second read here would put two
                // requests for the same key on the wire at once, and each handler would take the first
                // reply as the answer to its own.
                NoopButton("Stop sharing on the strap", systemImage: "antenna.radiowaves.left.and.right.slash",
                           kind: .secondary) {
                    model.ble.stopStrapSharingOnStrap()
                }
                Text("Sends the off command again, even if the switch above already looks off. Your live heart rate in NOOP is not affected.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
