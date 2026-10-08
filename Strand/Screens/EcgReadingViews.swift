import SwiftUI
import StrandDesign
import WhoopProtocol
import WhoopStore

// MARK: - WHOOP MG ECG reading screens (OpenStrap port)
//
// The capture sheet, the saved-readings list and a reading's trace. Every result shown here is the
// strap's own; the category comes from OpenStrap's result-plus-heart-rate table. NOOP is not a medical
// device, and the copy says so wherever a category appears.

/// User-facing text for the strap's category.
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

    static let disclaimer: LocalizedStringKey = "The result is reported by the strap's built-in classifier and named with OpenStrap's table. NOOP is not a medical device and this is not a diagnosis. See a doctor if you have symptoms."

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
        case "notReady": return "A reading needs a connected WHOOP MG with the full bond and the Experimental ECG opt-in switched on."
        case "disconnected": return "The strap disconnected during the reading."
        case "noData": return "The strap sent no ECG data. Check that the strap is an MG and try again."
        case "timeout": return "The strap did not finish the reading within two minutes."
        case "interruptions": return "Contact with the clasp was lost three times."
        case "progress_255": return "The strap aborted the reading."
        case "save": return "The reading could not be saved."
        case "cancelled": return "The reading was cancelled."
        default: return "The reading did not finish."
        }
    }
}

/// A strip of ECG samples (100 Hz) on a light grid: one major line per second, one minor per 0.2 s.
struct EcgTraceView: View {
    /// Samples in microvolts; nil entries are gaps (a lost packet).
    let samples: [Int16?]
    /// Points per second of trace.
    var pointsPerSecond: CGFloat = 120
    /// Fixed half-range in microvolts, or nil to scale to the data.
    var halfRangeMicrovolts: Double?

    var body: some View {
        Canvas { context, size in
            let perSample = pointsPerSecond / 100
            var grid = Path()
            var x: CGFloat = 0
            while x <= size.width {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
                x += pointsPerSecond / 5
            }
            context.stroke(grid, with: .color(StrandPalette.hairline), lineWidth: 0.5)
            var major = Path()
            x = 0
            while x <= size.width {
                major.move(to: CGPoint(x: x, y: 0))
                major.addLine(to: CGPoint(x: x, y: size.height))
                x += pointsPerSecond
            }
            major.move(to: CGPoint(x: 0, y: size.height / 2))
            major.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(major, with: .color(StrandPalette.hairlineStrong), lineWidth: 0.75)

            let peak = samples.compactMap { $0.map { abs(Double($0)) } }.max() ?? 0
            let half = halfRangeMicrovolts ?? max(400, peak * 1.15)
            let mid = size.height / 2
            var trace = Path()
            var penDown = false
            for (i, sample) in samples.enumerated() {
                guard let sample else { penDown = false; continue }
                let point = CGPoint(x: CGFloat(i) * perSample,
                                    y: mid - CGFloat(Double(sample) / half) * mid)
                if penDown { trace.addLine(to: point) } else { trace.move(to: point); penDown = true }
            }
            context.stroke(trace, with: .color(StrandPalette.metricRose), lineWidth: 1.4)
        }
    }
}

// MARK: - Capture

struct EcgReadingSheet: View {
    @ObservedObject var controller: EcgReadingController
    let onClose: () -> Void
    @AppStorage("noopEcgReadingWrist") private var wristRaw = Int(Whoop5Ecg.WristSelection.left.rawValue)
    @State private var showSaved = false

    private var wrist: Whoop5Ecg.WristSelection {
        Whoop5Ecg.WristSelection(rawValue: UInt8(clamping: wristRaw)) ?? .left
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    content
                }
                .padding(NoopMetrics.screenPadding)
            }
            .background(StrandPalette.surfaceBase)
            .navigationTitle("ECG reading")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(controller.phase.isRunning ? "Cancel" : "Close") {
                        if controller.phase.isRunning { controller.cancel() } else {
                            controller.reset()
                            onClose()
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Saved") { showSaved = true }
                        .disabled(controller.phase.isRunning)
                }
            }
            .navigationDestination(isPresented: $showSaved) {
                EcgReadingListView(controller: controller)
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
            completed
        case .unreadable:
            ended(title: "Unreadable", lines: EcgCategoryText.unreadableReasons(controller.unreadableMask)
                  + ["Rest your arm, keep still and hold the clasp a little firmer."])
            startButton(title: "Try again")
        case .inconclusiveRetry:
            ended(title: "Inconclusive", lines: ["The strap could not decide. One more reading usually settles it."])
            Button { controller.retry() } label: {
                Text("Take one more reading").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder private var setup: some View {
        if controller.phase == .failed || controller.phase == .cancelled {
            Text(EcgCategoryText.failure(controller.failureReason))
                .font(StrandFont.subhead)
                .foregroundStyle(controller.phase == .failed ? StrandPalette.statusWarningForeground
                                 : StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text("Sit still and rest your arm. When the reading starts, hold the two indents on the clasp with the fingers of your other hand for about 40 seconds until the result appears.")
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
        Picker("Wrist", selection: $wristRaw) {
            Text("Left wrist").tag(Int(Whoop5Ecg.WristSelection.left.rawValue))
            Text("Right wrist").tag(Int(Whoop5Ecg.WristSelection.right.rawValue))
        }
        .pickerStyle(.segmented)
        Text("The wrist is written to the strap at the start of every reading.")
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
        startButton(title: "Start reading")
        if !controller.isReady {
            Text("Needs a connected WHOOP MG with the full bond and Settings → Experimental → ECG switched on.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusWarningForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(EcgCategoryText.disclaimer)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func startButton(title: LocalizedStringKey) -> some View {
        Button { controller.begin(wrist: wrist) } label: {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!controller.isReady)
    }

    @ViewBuilder private var running: some View {
        Text(statusLine)
            .font(StrandFont.headline)
            .foregroundStyle(controller.phase == .contactLost ? StrandPalette.statusWarningForeground
                             : StrandPalette.textPrimary)
        EcgTraceView(samples: paddedLive, pointsPerSecond: 60)
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius))
            .background(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius).fill(StrandPalette.surfaceRaised))
        ProgressView(value: Double(controller.progress), total: 100)
            .tint(StrandPalette.accent)
        HStack {
            Label(controller.liveHr.map { "\($0) bpm" } ?? "–", systemImage: "heart")
            Spacer()
            Text("Signal \(controller.quality)/3")
            Spacer()
            Text("\(controller.elapsedSeconds) s")
        }
        .font(StrandFont.captionNumber)
        .foregroundStyle(StrandPalette.textSecondary)
        if controller.interruptions > 0 {
            Text("Contact lost \(controller.interruptions)× (the reading ends at 3)")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusWarningForeground)
        }
    }

    private var statusLine: LocalizedStringKey {
        switch controller.phase {
        case .waiting: return "Hold the clasp with your other hand"
        case .contactLost: return "Contact lost. Hold the clasp again"
        case .restarting: return "Restarting the reading"
        case .finishing: return "Result received. Finishing"
        default: return "Recording. Keep still"
        }
    }

    /// The live ring, left-padded with gaps so the trace scrolls in from the right.
    private var paddedLive: [Int16?] {
        let live = controller.liveSamples
        let pad = max(0, EcgReadingController.liveCapacity - live.count)
        return Array(repeating: nil, count: pad) + live.map { Optional($0) }
    }

    @ViewBuilder private var completed: some View {
        EcgSavedSummary(controller: controller)
        startButton(title: "New reading")
    }

    @ViewBuilder private func ended(title: LocalizedStringKey, lines: [LocalizedStringKey]) -> some View {
        Text(title)
            .font(StrandFont.title2)
            .foregroundStyle(StrandPalette.textPrimary)
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(line)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The just-saved reading, loaded back from the store so what is shown is what was kept.
private struct EcgSavedSummary: View {
    @ObservedObject var controller: EcgReadingController
    @EnvironmentObject var repo: Repository
    @State private var row: EcgReadingRow?

    var body: some View {
        Group {
            if let row {
                NavigationLink {
                    EcgReadingDetailView(reading: row)
                } label: {
                    EcgReadingRowView(reading: row)
                }
                .buttonStyle(.plain)
                Text(EcgCategoryText.disclaimer)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView()
            }
        }
        .task(id: controller.savedRevision) {
            guard let id = controller.savedReadingId, let store = await repo.storeHandle() else { return }
            row = try? await store.ecgReadings().first { $0.id == id }
        }
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
                Text("No saved ECG readings yet.")
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
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(EcgCategoryText.title(reading.category))
                    .font(StrandFont.headline)
                    .foregroundStyle(EcgCategoryText.tint(reading.category))
                Text(Date(timeIntervalSince1970: TimeInterval(reading.startTs)),
                     format: .dateTime.day().month().year().hour().minute())
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            if let hr = reading.averageHr {
                Text("\(hr) bpm")
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
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
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                EcgReadingRowView(reading: reading)
                ScrollView(.horizontal, showsIndicators: true) {
                    EcgTraceView(samples: samples, pointsPerSecond: 120)
                        .frame(width: max(320, CGFloat(samples.count) / 100 * 120), height: 220)
                        .background(StrandPalette.surfaceRaised)
                }
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius))
                Text("One strong grid line per second. Scroll sideways for the whole reading.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                facts
                Text(EcgCategoryText.disclaimer)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(NoopMetrics.screenPadding)
        }
        .background(StrandPalette.surfaceBase)
        .navigationTitle("ECG")
        .task {
            guard let store = await repo.storeHandle(),
                  let packets = try? await store.ecgReadingPackets(id: reading.id) else { return }
            samples = packets.flatMap { packet -> [Int16?] in
                packet.isPlaceholder ? Array(repeating: nil, count: 100) : packet.samples.map { Optional($0) }
            }
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 6) {
            fact("Duration", "\(reading.endTs - reading.startTs) s")
            fact("Wrist", reading.wrist == "right" ? "Right" : "Left")
            fact("Strap result code", "\(reading.resultCode)")
            if let v = reading.variabilityRaw { fact("Strap variability (raw, likely RMSSD ms)", "\(v)") }
            if let q = reading.quality { fact("Signal quality", "\(q)/3") }
            fact("Samples", "\(reading.sampleCount) at 100 Hz")
            if reading.missingSegments > 0 { fact("Lost packets", "\(reading.missingSegments)") }
            if reading.interruptions > 0 { fact("Contact interruptions", "\(reading.interruptions)") }
            if reading.status == "inconclusive" { fact("Status", "Inconclusive after a retry") }
        }
        .font(StrandFont.subhead)
    }

    private func fact(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value).foregroundStyle(StrandPalette.textPrimary)
        }
    }
}
