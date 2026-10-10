import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore

// MARK: - WHOOP MG ECG reading screens (OpenStrap port)
//
// The capture sheet, the saved-readings list and a saved reading. Every result shown here is the strap's
// own; the category comes from OpenStrap's result-plus-heart-rate table. NOOP is not a medical device:
// a first-use notice states the limits and intended use, and every screen that names a category keeps
// that notice one tap away behind an info button rather than as text on the screen.

/// User-facing text and styling for the strap's category.
enum EcgCategoryText {
    static func title(_ raw: String) -> LocalizedStringKey {
        switch EcgCategory(rawValue: raw) {
        case .sinusRhythm: return "Sinus rhythm"
        case .lowHeartRate: return "Low heart rate"
        case .possibleAfib: return "Signs of atrial fibrillation"
        case .afibHighHeartRate: return "Signs of atrial fibrillation, high heart rate"
        case .highHeartRate: return "High heart rate"
        case .highHeartRateNoAfib: return "High heart rate, no signs of atrial fibrillation"
        case .inconclusive: return "Inconclusive"
        case .unreadable, .none: return "Unreadable"
        }
    }

    static func tint(_ raw: String) -> Color {
        switch EcgCategory(rawValue: raw) {
        case .sinusRhythm: return StrandPalette.statusPositive
        case .possibleAfib, .afibHighHeartRate: return StrandPalette.statusCritical
        case .lowHeartRate, .highHeartRate, .highHeartRateNoAfib: return StrandPalette.statusWarning
        default: return StrandPalette.textSecondary
        }
    }

    static func unreadableReasons(_ mask: UInt8) -> [LocalizedStringKey] {
        let m = EcgUnreadableMask(raw: mask)
        var out: [LocalizedStringKey] = []
        if m.lowAmplitude { out.append("The signal was too weak.") }
        if m.significantNoise { out.append("There was too much noise.") }
        if m.unstableSignal { out.append("The signal was unstable.") }
        if m.notEnoughData { out.append("There was not enough data.") }
        return out
    }

    /// Shown under Start while the strap cannot begin a reading; the same text as the `notReady` failure.
    static var notReady: LocalizedStringKey { failure("notReady") }

    static func failure(_ reason: String?) -> LocalizedStringKey {
        switch reason {
        case "notReady": return "Connect your WHOOP MG and switch on the ECG experiment first."
        case "prepare": return "The strap did not confirm the start commands."
        case "restart": return "The strap did not confirm the restart."
        case "disconnected": return "The strap disconnected during the reading."
        case "noData": return "The strap sent no ECG data."
        case "timeout": return "The strap did not finish within two minutes."
        case "interruptions": return "Contact with the clasp was lost three times."
        case "progress_255": return "The strap stopped the reading."
        case "save": return "The reading could not be saved."
        case "cancelled": return "Reading cancelled."
        default: return "The reading did not finish."
        }
    }
}

/// What a person confirms once before their first reading: what the feature is for, what it cannot do,
/// and that it is not for medical use. Bump `currentVersion` when the wording changes materially, so the
/// next reading asks again.
enum EcgReadingConsent {
    static let currentVersion = "2"
    static let acceptedVersionKey = "noopEcgReadingConsentVersion"

    static func isAccepted(_ stored: String) -> Bool { stored == currentVersion }

    static let points: [(LocalizedStringKey, LocalizedStringKey)] = [
        ("An experimental test feature",
         "ECG readings in NOOP are an experimental feature for testing and personal interest. NOOP is not a medical device, and nothing here has been reviewed or approved for medical use."),
        ("No approval for NOOP",
         "WHOOP's ECG feature is cleared by the FDA only together with WHOOP's own app. That clearance does not extend to NOOP: reading the strap and analysing the trace here are not cleared or approved by the FDA or any other authority."),
        ("Not for medical use",
         "Do not use these readings to diagnose, rule out or monitor a heart condition, or to decide on medication or treatment. NOOP does not recommend any medical use."),
        ("Where the result comes from",
         "The rhythm result is calculated by the strap itself. NOOP shows it and cannot check whether it is correct. Heart rate, variability and intervals are NOOP's own estimates from the saved trace and are not validated."),
        ("Limits of a wrist ECG",
         "One lead at the wrist, 100 samples per second, an uncalibrated amplitude and a filter inside the strap. Movement, loose contact or a slow heart rate can give wrong results. A single lead cannot replace a 12-lead ECG."),
        ("Values can differ from a calibrated ECG",
         "Compared with a calibrated single-lead ECG device, amplitude, QRS width, the T wave and intervals can differ noticeably. Take the numbers as a rough indication, not as a measurement you can rely on."),
        ("If you feel unwell",
         "With symptoms such as chest pain, palpitations, dizziness or shortness of breath, contact a doctor. In an emergency, call your local emergency number (112 in Europe, 911 in the US) or alert your emergency contacts. Do not wait for or rely on a reading in NOOP."),
        ("Your readings stay with you",
         "NOOP stores readings on this device and sends them to no one. A backup you make yourself includes them."),
    ]
}

/// The intended-use notice: shown in place of the setup until it is confirmed, and on request afterwards.
private struct EcgReadingIntro: View {
    /// Nil once confirmed: the notice is then read-only and closes with Done.
    let onAccept: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Experimental", systemImage: "flask")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusWarningForeground)
            Text("Before you record an ECG")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        VStack(alignment: .leading, spacing: 16) {
            ForEach(EcgReadingConsent.points.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 4) {
                    Text(EcgReadingConsent.points[i].0)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(EcgReadingConsent.points[i].1)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .ecgCard()
        if let onAccept {
            VStack(spacing: 8) {
                Button(action: onAccept) {
                    Text("I understand, continue").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Button("Not now", action: onDismiss)
                    .buttonStyle(.borderless)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        } else {
            Button(action: onDismiss) {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}

/// The limits and intended-use notice behind an info button: result screens stay uncluttered while the
/// notice remains one tap away wherever a category is shown.
struct EcgInfoButton: View {
    @State private var presented = false

    var body: some View {
        Button { presented = true } label: {
            Label("Limits and intended use", systemImage: "info.circle")
        }
        .sheet(isPresented: $presented) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        EcgReadingIntro(onAccept: nil, onDismiss: { presented = false })
                    }
                    .padding(16)
                }
                .background(StrandPalette.surfaceBase)
            }
            #if os(macOS)
            .frame(minWidth: NoopMetrics.detailSheetMinWidth, minHeight: NoopMetrics.detailSheetMinHeight)
            #endif
        }
    }
}

/// One labelled number: an uppercase caption over a value and its unit.
private struct EcgStat: View {
    let label: LocalizedStringKey
    let value: String
    var unit: LocalizedStringKey? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .textCase(.uppercase)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(StrandFont.title2.monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The grouped surface every card on these screens sits on.
private extension View {
    func ecgCard() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StrandPalette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous))
    }
}

// MARK: - Capture

struct EcgReadingSheet: View {
    @ObservedObject var controller: EcgReadingController
    let onClose: () -> Void
    @AppStorage("noopEcgReadingWrist") private var wristRaw = Int(Whoop5Ecg.WristSelection.left.rawValue)
    @AppStorage(EcgReadingConsent.acceptedVersionKey) private var consentVersion = ""

    private var wrist: Whoop5Ecg.WristSelection {
        Whoop5Ecg.WristSelection(rawValue: UInt8(clamping: wristRaw)) ?? .left
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    content
                }
                .padding(16)
                .animation(.default, value: controller.phase)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("ECG reading")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if controller.phase.isRunning {
                        Button("Stop") { controller.cancel() }
                    } else {
                        Button("Close") {
                            controller.reset()
                            onClose()
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        EcgReadingListView(controller: controller)
                    } label: {
                        Label("Saved ECGs", systemImage: "list.bullet")
                    }
                    .disabled(controller.phase.isRunning)
                }
                ToolbarItem(placement: .primaryAction) {
                    EcgInfoButton()
                }
            }
        }
        // Swiping the sheet away mid-reading would leave the strap recording out of sight; Stop is the way out.
        .interactiveDismissDisabled(controller.phase.isRunning)
        #if os(macOS)
        // A sheet on macOS needs a size; on iPhone the same minimum would push the content past the screen.
        .frame(minWidth: NoopMetrics.detailSheetMinWidth, minHeight: NoopMetrics.detailSheetMinHeight)
        #endif
    }

    @ViewBuilder private var content: some View {
        if controller.cleanupIncomplete && !controller.phase.isRunning {
            Label("The strap did not confirm that ECG recording stopped. Starting a new reading stops it first.",
                  systemImage: "exclamationmark.triangle")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.statusWarningForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        switch controller.phase {
        case .idle, .cancelled, .failed:
            if !EcgReadingConsent.isAccepted(consentVersion) {
                EcgReadingIntro(onAccept: { consentVersion = EcgReadingConsent.currentVersion },
                                onDismiss: {
                                    controller.reset()
                                    onClose()
                                })
            } else {
                setup
            }
        case .preparing, .waiting, .active, .contactLost, .restarting, .finishing, .stopping:
            running
        case .completed:
            EcgSavedResult(controller: controller) { controller.begin(wrist: wrist) }
        case .unreadable:
            outcome(icon: "waveform.slash", title: "Unreadable",
                    lines: EcgCategoryText.unreadableReasons(controller.unreadableMask)
                        + ["Rest your arm on a table, keep still and hold the clasp a little firmer."])
            primaryButton("Try again") { controller.begin(wrist: wrist) }
        case .inconclusiveRetry:
            outcome(icon: "questionmark.circle", title: "Inconclusive",
                    lines: ["The strap could not decide. One more reading usually settles it."])
            primaryButton("Take one more reading") { controller.retry() }
        }
    }

    // MARK: Setup

    @ViewBuilder private var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Record an ECG")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Sit still and rest your arm. Hold the two indents on the clasp with the fingers of your other hand for about 40 seconds.")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if controller.phase == .failed || controller.phase == .cancelled {
            Label(EcgCategoryText.failure(controller.failureReason),
                  systemImage: controller.phase == .failed ? "exclamationmark.triangle" : "xmark.circle")
                .font(StrandFont.subhead)
                .foregroundStyle(controller.phase == .failed ? StrandPalette.statusWarningForeground
                                 : StrandPalette.textSecondary)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("Wrist")
                .textCase(.uppercase)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            Picker("Wrist", selection: $wristRaw) {
                Text("Left").tag(Int(Whoop5Ecg.WristSelection.left.rawValue))
                Text("Right").tag(Int(Whoop5Ecg.WristSelection.right.rawValue))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        VStack(alignment: .leading, spacing: 8) {
            primaryButton("Start") { controller.begin(wrist: wrist) }
                .disabled(!controller.isReady)
            if !controller.isReady {
                Text(EcgCategoryText.notReady)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.statusWarningForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Running

    @ViewBuilder private var running: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusTitle)
                .font(StrandFont.headline)
                .foregroundStyle(controller.phase == .contactLost ? StrandPalette.statusWarningForeground
                                 : StrandPalette.textPrimary)
            Text(statusHint)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        EcgLiveStrip(samples: controller.liveSamples)
        VStack(spacing: 8) {
            ProgressView(value: Double(controller.progress), total: 100)
                .tint(StrandPalette.accent)
            HStack {
                Text("\(controller.progress) %")
                Spacer()
                // Once the strap reports progress it is counting down its 30 s recording; before that
                // (contact settling) only the elapsed time is honest.
                if let left = EcgHeartKeyProgress(raw: UInt8(clamping: controller.progress)).remainingSeconds {
                    Text("\(left) s left")
                } else {
                    Text("\(controller.elapsedSeconds) s")
                }
            }
            .font(StrandFont.captionNumber)
            .foregroundStyle(StrandPalette.textSecondary)
        }
        HStack(spacing: 16) {
            EcgStat(label: "Heart rate", value: controller.liveHr.map(String.init) ?? "–", unit: "bpm")
            EcgStat(label: "Signal", value: "\(controller.quality)/3")
            EcgStat(label: "Interruptions", value: "\(controller.interruptions)/3")
        }
        .ecgCard()
    }

    private var statusTitle: LocalizedStringKey {
        switch controller.phase {
        case .preparing: return "Preparing the strap"
        case .stopping: return "Stopping"
        case .waiting: return "Touch the clasp"
        case .contactLost: return "Contact lost"
        case .restarting: return "Restarting"
        case .finishing: return "Result received"
        default: return "Recording"
        }
    }

    private var statusHint: LocalizedStringKey {
        switch controller.phase {
        case .preparing: return "Waiting for the strap to confirm each command."
        case .stopping: return "Switching the strap's ECG off."
        case .waiting: return "Hold both indents with the fingers of your other hand."
        case .contactLost: return "Hold the clasp again; the reading continues."
        case .restarting: return "Keep holding the clasp."
        case .finishing: return "Saving the reading."
        default: return "Keep still and keep holding the clasp."
        }
    }

    // MARK: Shared pieces

    private func primaryButton(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func outcome(icon: String, title: LocalizedStringKey, lines: [LocalizedStringKey]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .ecgCard()
    }
}

/// The just-saved reading, loaded back from the store so what is shown is what was kept.
private struct EcgSavedResult: View {
    @ObservedObject var controller: EcgReadingController
    let onNewReading: () -> Void
    @EnvironmentObject var repo: Repository
    @State private var loaded: (row: EcgReadingRow, samples: [Int16?])?

    var body: some View {
        Group {
            if let loaded {
                EcgResultHeader(reading: loaded.row)
                EcgPrintout(samples: loaded.samples)
                EcgMeasurementsSection(readingId: loaded.row.id, samples: loaded.samples)
                Button(action: onNewReading) {
                    Text("New reading").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: controller.savedRevision) {
            guard let id = controller.savedReadingId, let store = await repo.storeHandle(),
                  let row = try? await store.ecgReadings().first(where: { $0.id == id }) else { return }
            let packets = (try? await store.ecgReadingPackets(id: id)) ?? []
            loaded = (row, EcgSamples.flatten(packets))
        }
    }
}

enum EcgSamples {
    /// One reading's window as a sample stream; a lost packet becomes one second of gap.
    static func flatten(_ packets: [EcgReadingPacketRow]) -> [Int16?] {
        packets.flatMap { packet -> [Int16?] in
            packet.isPlaceholder ? Array(repeating: nil, count: EcgPaper.sampleRate)
                : packet.samples.map { Optional($0) }
        }
    }
}

/// Category, the three numbers and the time of a reading.
struct EcgResultHeader: View {
    let reading: EcgReadingRow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(EcgCategoryText.title(reading.category), systemImage: "waveform.path.ecg")
                    .font(StrandFont.headline)
                    .foregroundStyle(EcgCategoryText.tint(reading.category))
                Text(Date(timeIntervalSince1970: TimeInterval(reading.startTs)),
                     format: .dateTime.weekday(.wide).day().month(.wide).hour().minute())
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            HStack(spacing: 16) {
                EcgStat(label: "Heart rate", value: reading.averageHr.map(String.init) ?? "–", unit: "bpm")
                EcgStat(label: "HRV", value: reading.variabilityRaw.map(String.init) ?? "–", unit: "ms")
                EcgStat(label: "Length", value: "\(reading.sampleCount / EcgPaper.sampleRate)", unit: "s")
            }
        }
        .ecgCard()
    }
}

// MARK: - Saved readings

/// Saved readings as a destination of their own, so they stay reachable without the strap's device card:
/// another strap active, the MG out of range, or the opt-in switched off after recording. A new reading
/// is offered only with the opt-in on; the capture sheet itself says when the strap cannot start one.
struct EcgReadingsScreen: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(PuffinExperiment.ecgKey) private var ecgEnabled = false
    @State private var readingPresented = false

    var body: some View {
        EcgReadingListView(controller: model.ecgReading)
            .toolbar {
                if ecgEnabled {
                    ToolbarItem(placement: .primaryAction) {
                        Button { readingPresented = true } label: {
                            Label("New reading", systemImage: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $readingPresented) {
                EcgReadingSheet(controller: model.ecgReading, onClose: { readingPresented = false })
            }
    }
}

struct EcgReadingListView: View {
    @ObservedObject var controller: EcgReadingController
    @EnvironmentObject var repo: Repository
    @State private var readings: [EcgReadingRow] = []
    @State private var loaded = false
    @State private var refreshToken = 0

    var body: some View {
        List {
            Section("WHOOP MG") {
                if loaded && readings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No saved ECGs yet.")
                            .foregroundStyle(StrandPalette.textSecondary)
                        Text("A reading needs a WHOOP MG and the ECG switch under Settings → Experimental · WHOOP 5 / MG.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(readings) { reading in
                    NavigationLink {
                        EcgReadingDetailView(reading: reading)
                    } label: {
                        EcgReadingRowView(reading: reading)
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.map { readings[$0].id }
                    readings.remove(atOffsets: offsets)
                    Task {
                        guard let store = await repo.storeHandle() else { return }
                        for id in ids { try? await store.deleteEcgReading(id: id) }
                    }
                }
            }
            #if os(iOS)
            AppleWatchEcgSection(noopReadings: readings, refreshToken: refreshToken)
            #endif
        }
        .refreshable {
            if let store = await repo.storeHandle() { readings = (try? await store.ecgReadings()) ?? [] }
            refreshToken &+= 1
        }
        .navigationTitle("Saved ECGs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EcgInfoButton()
            }
        }
        .task(id: controller.savedRevision) {
            guard let store = await repo.storeHandle() else { return }
            readings = (try? await store.ecgReadings()) ?? []
            loaded = true
        }
    }
}

struct EcgReadingRowView: View {
    let reading: EcgReadingRow

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .foregroundStyle(EcgCategoryText.tint(reading.category))
            VStack(alignment: .leading, spacing: 4) {
                Text(EcgCategoryText.title(reading.category))
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(Date(timeIntervalSince1970: TimeInterval(reading.startTs)),
                     format: .dateTime.day().month().year().hour().minute())
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            if let hr = reading.averageHr {
                Text("\(hr) bpm")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct EcgReadingDetailView: View {
    let reading: EcgReadingRow
    @EnvironmentObject var repo: Repository
    @State private var samples: [Int16?] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                EcgResultHeader(reading: reading)
                VStack(alignment: .leading, spacing: 8) {
                    EcgPrintout(samples: samples)
                    Text("25 mm/s, 10 mm/mV nominal: the strap's amplitude scale is not calibrated.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                EcgMeasurementsSection(readingId: reading.id, samples: samples)
                facts
            }
            .padding(16)
        }
        .background(StrandPalette.surfaceBase)
        .navigationTitle("ECG reading")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EcgInfoButton()
            }
        }
        .task {
            guard let store = await repo.storeHandle(),
                  let packets = try? await store.ecgReadingPackets(id: reading.id) else { return }
            samples = EcgSamples.flatten(packets)
        }
    }

    private var facts: some View {
        VStack(spacing: 0) {
            fact("Wrist", reading.wrist == "right" ? "Right" : "Left")
            Divider()
            fact("Strap result code", verbatim: "\(reading.resultCode)")
            if let quality = reading.quality {
                Divider()
                fact("Signal quality", verbatim: "\(quality)/3")
            }
            if reading.missingSegments > 0 {
                Divider()
                fact("Lost packets", verbatim: "\(reading.missingSegments)")
            }
            if reading.interruptions > 0 {
                Divider()
                fact("Contact interruptions", verbatim: "\(reading.interruptions)")
            }
            if reading.status == "inconclusive" {
                Divider()
                fact("Status", "Inconclusive after a retry")
            }
        }
        .padding(.horizontal, 16)
        .background(StrandPalette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous))
    }

    private func fact(_ label: LocalizedStringKey, _ value: LocalizedStringKey) -> some View {
        HStack {
            Text(label).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value).foregroundStyle(StrandPalette.textPrimary)
        }
        .font(StrandFont.body)
        .padding(.vertical, 12)
    }

    private func fact(_ label: LocalizedStringKey, verbatim value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(verbatim: value).foregroundStyle(StrandPalette.textPrimary).monospacedDigit()
        }
        .font(StrandFont.body)
        .padding(.vertical, 12)
    }
}

// MARK: - Measurements

/// Rhythm, HRV and the intervals of the average beat, computed from a reading's samples on display.
/// Nothing here is stored; a better method later re-measures every saved reading.
struct EcgMeasurementsSection: View {
    /// Which reading `samples` belong to. The measurements are recomputed when it or the sample count
    /// changes: the count alone misses a different reading of the same length, the id alone misses
    /// samples that arrive after the view appears.
    let readingId: String
    let samples: [Int16?]
    /// The strip comes from the WHOOP MG: its high-pass is undone before anything is measured.
    var fromStrap = true
    /// The last result and the reading it belongs to; nil analysis = too few clear beats.
    @State private var result: (key: String, analysis: EcgAnalysis.Result?)?

    private var key: String { "\(readingId)#\(samples.count)" }

    var body: some View {
        // The sections stay direct children of the caller's stack, as before, so its spacing applies
        // between them. The analysis runs from a zero-height loader that exists only while this reading
        // has no result: a `.task` on the whole Group never ran, because before the first result the
        // Group had no child to carry it, so the measurements never appeared.
        Group {
            if let result, result.key == key {
                if let analysis = result.analysis {
                    measurements(analysis)
                } else {
                    Text("Too few clear beats to measure this reading.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            } else if !samples.isEmpty {
                Color.clear
                    .frame(height: 0)
                    .task(id: key) {
                        let key = key
                        let input = samples
                        let cutoff = fromStrap ? EcgAnalysis.strapHighPassHz : nil
                        let analysis = await Task.detached(priority: .userInitiated) {
                            EcgAnalysis.analyze(input, compensatingHighPassHz: cutoff)
                        }.value
                        guard !Task.isCancelled else { return }
                        result = (key, analysis)
                    }
            }
        }
    }

    @ViewBuilder private func measurements(_ a: EcgAnalysis.Result) -> some View {
        section("Rhythm") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    EcgStat(label: "Average", value: "\(Int(a.meanHeartRate.rounded()))", unit: "bpm")
                    EcgStat(label: "Lowest", value: "\(Int(a.minHeartRate.rounded()))", unit: "bpm")
                    EcgStat(label: "Highest", value: "\(Int(a.maxHeartRate.rounded()))", unit: "bpm")
                }
                Divider()
                Group {
                    if a.irregularBeats == 0 {
                        Text("No irregular beats in this reading.")
                    } else {
                        Text("Irregular beats: \(a.irregularBeats)")
                    }
                }
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            }
            .ecgCard()
        }
        section("Heart rate variability") {
            HStack(spacing: 16) {
                EcgStat(label: "RMSSD", value: a.rmssdMs.map { "\(Int($0.rounded()))" } ?? "–", unit: "ms")
                EcgStat(label: "SDNN", value: a.sdnnMs.map { "\(Int($0.rounded()))" } ?? "–", unit: "ms")
                EcgStat(label: "pNN50", value: a.pnn50.map { "\(Int($0.rounded()))" } ?? "–", unit: "%")
            }
            .ecgCard()
        }
        if !a.template.isEmpty {
            section("Average beat") {
                VStack(alignment: .leading, spacing: 8) {
                    EcgAverageBeatView(template: a.template, rIndex: a.templateRIndex, fiducials: a.fiducials)
                    Text("From \(a.beatsAveraged) of \(a.beatsDetected) beats. P, Q, J and T mark where the intervals are measured.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            section("Intervals") {
                VStack(spacing: 0) {
                    interval("PR interval", a.prMs, typical: "Typical: 120 to 200 ms")
                    Divider()
                    interval("QRS duration", a.qrsMs, typical: "Typical: under 120 ms")
                    Divider()
                    interval("QT interval", a.qtMs, typical: nil)
                    Divider()
                    interval("QTc (Fridericia)", a.qtcFridericiaMs, typical: "Typical: under 450 ms")
                }
                .padding(.horizontal, 16)
                .background(StrandPalette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous))
            }
            Text("Experimental. Checked against cardiologist annotations (PhysioNet QT Database) and, for the strap, against an Apple Watch, but not clinically validated. One sample every 10 ms limits every interval. A single wrist lead cannot show the heart's axis or the ST changes a 12-lead ECG looks for.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(_ title: LocalizedStringKey,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .textCase(.uppercase)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            content()
        }
    }

    private func interval(_ label: LocalizedStringKey, _ value: Double?, typical: LocalizedStringKey?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let typical {
                    Text(typical)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer()
            if let value {
                Text("\(Int(value.rounded())) ms")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
            } else {
                Text("not measurable")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.vertical, 12)
    }
}

/// The median beat on enlarged ECG paper (the same 25 mm/s to 10 mm/mV proportion, zoomed to the width),
/// with the measuring points marked.
struct EcgAverageBeatView: View {
    let template: [Double]
    let rIndex: Int
    let fiducials: EcgAnalysis.Fiducials?
    @State private var width: CGFloat = 0

    private var spanMillimeters: CGFloat {
        CGFloat(template.count) / CGFloat(EcgPaper.sampleRate) * EcgPaper.millimetersPerSecond
    }

    /// Millivolts above and below the baseline, rounded out to half millivolts.
    private var range: (top: Double, bottom: Double) {
        let hi = (template.max() ?? 0) / 1000, lo = (template.min() ?? 0) / 1000
        return ((max(0.5, hi * 1.15) * 2).rounded(.up) / 2, (max(0.5, -lo * 1.15) * 2).rounded(.up) / 2)
    }

    var body: some View {
        let ppm = width > 0 ? width / spanMillimeters : 1
        let paper = EcgPaper(pointsPerMillimeter: ppm)
        let height = CGFloat(range.top + range.bottom) * EcgPaper.millimetersPerMillivolt * ppm
        Canvas { context, size in
            paper.drawGrid(in: &context, size: size)
            let baseline = CGFloat(range.top) * EcgPaper.millimetersPerMillivolt * ppm
            paper.drawTrace(template.map { Optional($0) }[...], in: &context, originX: 0, baselineY: baseline)
            guard let f = fiducials else { return }
            let marks: [(String, Double?)] = [("P", f.pOnsetMs), ("Q", f.qrsOnsetMs), ("J", f.jPointMs), ("T", f.tEndMs)]
            for (label, ms) in marks {
                guard let ms else { continue }
                let x = (CGFloat(rIndex) + CGFloat(ms) / 1000 * CGFloat(EcgPaper.sampleRate)) * paper.pointsPerSample
                var line = Path()
                line.move(to: CGPoint(x: x, y: 16))
                line.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(line, with: .color(StrandPalette.accent),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                context.draw(Text(verbatim: label).font(StrandFont.diagramLabel).foregroundColor(StrandPalette.accent),
                             at: CGPoint(x: x, y: 4), anchor: .top)
            }
        }
        .frame(height: width > 0 ? height : 160)
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChangeCompat(of: proxy.size.width) { width = $0 }
            }
        )
        .background(StrandPalette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous))
        .accessibilityLabel(Text("Average beat"))
    }
}
