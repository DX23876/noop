import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore

// MARK: - WHOOP MG ECG reading screens (OpenStrap port)
//
// The capture sheet, the saved-readings list and a saved reading. Every result shown here is the strap's
// own; the category comes from OpenStrap's result-plus-heart-rate table. NOOP is not a medical device,
// and each screen that names a category carries the disclaimer once, at the bottom.

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

    static let disclaimer: LocalizedStringKey = "The strap's built-in classifier reports the result; OpenStrap's table names it. NOOP is not a medical device and this is not a diagnosis. See a doctor if you have symptoms."

    static func unreadableReasons(_ mask: UInt8) -> [LocalizedStringKey] {
        let m = EcgUnreadableMask(raw: mask)
        var out: [LocalizedStringKey] = []
        if m.lowAmplitude { out.append("The signal was too weak.") }
        if m.significantNoise { out.append("There was too much noise.") }
        if m.unstableSignal { out.append("The signal was unstable.") }
        if m.notEnoughData { out.append("There was not enough data.") }
        return out
    }

    static func failure(_ reason: String?) -> LocalizedStringKey {
        switch reason {
        case "notReady": return "Connect your WHOOP MG and switch on the ECG experiment first."
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
            .navigationTitle("ECG")
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
            }
        }
        .frame(minWidth: NoopMetrics.detailSheetMinWidth, minHeight: NoopMetrics.detailSheetMinHeight)
    }

    @ViewBuilder private var content: some View {
        switch controller.phase {
        case .idle, .cancelled, .failed:
            setup
        case .waiting, .active, .contactLost, .restarting, .finishing:
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
                Text(EcgCategoryText.failure("notReady"))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.statusWarningForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        disclaimer
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
                Text("\(controller.elapsedSeconds) s")
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
        case .waiting: return "Touch the clasp"
        case .contactLost: return "Contact lost"
        case .restarting: return "Restarting"
        case .finishing: return "Result received"
        default: return "Recording"
        }
    }

    private var statusHint: LocalizedStringKey {
        switch controller.phase {
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

    private var disclaimer: some View {
        Text(EcgCategoryText.disclaimer)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
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
                EcgMeasurementsSection(samples: loaded.samples)
                Button(action: onNewReading) {
                    Text("New reading").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                Text(EcgCategoryText.disclaimer)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
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

struct EcgReadingListView: View {
    @ObservedObject var controller: EcgReadingController
    @EnvironmentObject var repo: Repository
    @State private var readings: [EcgReadingRow] = []
    @State private var loaded = false

    var body: some View {
        List {
            if loaded && readings.isEmpty {
                Text("No saved ECGs yet.")
                    .foregroundStyle(StrandPalette.textSecondary)
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
        .navigationTitle("Saved ECGs")
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
                    Text("25 mm/s, 10 mm/mV")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                EcgMeasurementsSection(samples: samples)
                facts
                Text(EcgCategoryText.disclaimer)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .background(StrandPalette.surfaceBase)
        .navigationTitle("ECG")
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
    let samples: [Int16?]
    @State private var analysis: EcgAnalysis.Result?
    @State private var done = false

    var body: some View {
        Group {
            if let analysis {
                measurements(analysis)
            } else if done {
                Text("Too few clear beats to measure this reading.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .task(id: samples.count) {
            guard !samples.isEmpty else { return }
            let input = samples
            analysis = await Task.detached(priority: .userInitiated) { EcgAnalysis.analyze(input) }.value
            done = true
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
            Text("Experimental. Measured on one lead at 100 Hz, so each interval is accurate to about 10 ms. A single wrist lead cannot show the heart's axis or the ST changes a 12-lead ECG looks for.")
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
                context.draw(Text(verbatim: label).font(StrandFont.diagramLabel).foregroundStyle(StrandPalette.accent),
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
