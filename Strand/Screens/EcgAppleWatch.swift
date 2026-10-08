#if os(iOS)
import HealthKit
import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Apple Watch ECGs as a reference for the strap's
//
// An Apple Watch records a single lead similar to lead I at about 512 Hz in calibrated microvolts. Read
// from Apple Health and brought onto the strap's 100 Hz grid, it is measured by the same `EcgAnalysis`,
// so the two devices can be compared reading by reading. Nothing here is stored; the Apple ECG stays in
// Apple Health. Read-only: NOOP never writes an ECG to Health.

/// One Apple Watch ECG from Apple Health, with its voltages already on the 100 Hz grid.
struct AppleWatchEcg: Identifiable {
    let id: UUID
    let start: Date
    let classification: HKElectrocardiogram.Classification
    let averageHeartRate: Double?
    let samplingHz: Double
    let samples: [Int16?]
}

enum AppleWatchEcgSource {
    private static let store = HKHealthStore()

    /// Asks once for read access to ECGs. iOS never says whether read access was granted, so an empty
    /// list afterwards means either "no ECGs" or "not allowed".
    static func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        try await store.requestAuthorization(toShare: [], read: [HKObjectType.electrocardiogramType()])
    }

    /// The most recent Apple Watch ECGs, newest first, each with its voltages loaded.
    static func recent(limit: Int = 10) async throws -> [AppleWatchEcg] {
        let ecgs: [HKElectrocardiogram] = try await withCheckedThrowingContinuation { continuation in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let query = HKSampleQuery(sampleType: HKObjectType.electrocardiogramType(), predicate: nil,
                                      limit: limit, sortDescriptors: [sort]) { _, samples, error in
                if let error { continuation.resume(throwing: error); return }
                continuation.resume(returning: (samples as? [HKElectrocardiogram]) ?? [])
            }
            store.execute(query)
        }
        var out: [AppleWatchEcg] = []
        for ecg in ecgs {
            let rate = ecg.samplingFrequency?.doubleValue(for: .hertz()) ?? 512
            let microvolts = try await voltages(of: ecg)
            out.append(AppleWatchEcg(
                id: ecg.uuid, start: ecg.startDate, classification: ecg.classification,
                averageHeartRate: ecg.averageHeartRate?.doubleValue(for: .count().unitDivided(by: .minute())),
                samplingHz: rate, samples: EcgResample.toHundredHertz(microvolts, rate: rate)))
        }
        return out
    }

    /// The lead-I-like voltages in microvolts, in order.
    private static func voltages(of ecg: HKElectrocardiogram) async throws -> [Double] {
        try await withCheckedThrowingContinuation { continuation in
            var values: [Double] = []
            values.reserveCapacity(ecg.numberOfVoltageMeasurements)
            let unit = HKUnit.voltUnit(with: .micro)
            let query = HKElectrocardiogramQuery(ecg) { _, result in
                switch result {
                case .measurement(let measurement):
                    if let quantity = measurement.quantity(for: .appleWatchSimilarToLeadI) {
                        values.append(quantity.doubleValue(for: unit))
                    }
                case .done:
                    continuation.resume(returning: values)
                case .error(let error):
                    continuation.resume(throwing: error)
                @unknown default:
                    continuation.resume(returning: values)
                }
            }
            store.execute(query)
        }
    }

    static func title(_ classification: HKElectrocardiogram.Classification) -> LocalizedStringKey {
        switch classification {
        case .sinusRhythm: return "Sinus rhythm"
        case .atrialFibrillation: return "Atrial fibrillation"
        case .inconclusiveLowHeartRate: return "Inconclusive: low heart rate"
        case .inconclusiveHighHeartRate: return "Inconclusive: high heart rate"
        case .inconclusivePoorReading: return "Inconclusive: poor recording"
        case .inconclusiveOther: return "Inconclusive"
        case .unrecognized: return "Unrecognized rhythm"
        default: return "Not classified"
        }
    }
}

/// The Apple Watch section of the saved-ECG list: loads on request, newest first.
struct AppleWatchEcgSection: View {
    let noopReadings: [EcgReadingRow]
    /// Bumped by the list's pull-to-refresh; any change reloads once access was asked for.
    var refreshToken: Int = 0
    @State private var ecgs: [AppleWatchEcg] = []
    @State private var state: LoadState = .idle
    /// Once the user loaded Apple Watch ECGs, the section loads on its own every time it appears.
    @AppStorage("noopEcgAppleWatchLoaded") private var loadedBefore = false
    private enum LoadState { case idle, loading, loaded, failed }

    var body: some View {
        Section {
            switch state {
            case .idle:
                Button("Load Apple Watch ECGs") { Task { await load() } }
            case .loading:
                ProgressView()
            case .failed:
                Text("Apple Health did not return ECGs.")
                    .foregroundStyle(StrandPalette.textSecondary)
                Button("Try again") { Task { await load() } }
            case .loaded:
                if ecgs.isEmpty {
                    Text("No Apple Watch ECGs found, or NOOP is not allowed to read them. Apple Health settings decide that.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                ForEach(ecgs) { ecg in
                    NavigationLink {
                        AppleWatchEcgDetailView(ecg: ecg, noopReadings: noopReadings)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "applewatch")
                                .foregroundStyle(StrandPalette.textSecondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(AppleWatchEcgSource.title(ecg.classification))
                                    .font(StrandFont.body)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(ecg.start, format: .dateTime.day().month().year().hour().minute())
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                            Spacer()
                            if let hr = ecg.averageHeartRate {
                                Text("\(Int(hr.rounded())) bpm")
                                    .font(StrandFont.bodyNumber)
                                    .foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                Button("Reload") { Task { await load() } }
            }
        } header: {
            Text("Apple Watch")
        } footer: {
            Text("Measured with the same method as the strap, for comparison. Read from Apple Health, not stored by NOOP.")
        }
        .task(id: refreshToken) {
            if loadedBefore || refreshToken > 0 { await load() }
        }
    }

    private func load() async {
        guard state != .loading else { return }
        loadedBefore = true
        state = .loading
        do {
            try await AppleWatchEcgSource.requestAccess()
            ecgs = try await AppleWatchEcgSource.recent()
            state = .loaded
        } catch {
            state = .failed
        }
    }
}

/// One Apple Watch ECG: its trace, its measurements and a side-by-side with the nearest strap reading.
struct AppleWatchEcgDetailView: View {
    let ecg: AppleWatchEcg
    let noopReadings: [EcgReadingRow]
    @EnvironmentObject var repo: Repository
    @State private var nearest: (row: EcgReadingRow, samples: [Int16?])?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(AppleWatchEcgSource.title(ecg.classification), systemImage: "applewatch")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(ecg.start, format: .dateTime.weekday(.wide).day().month(.wide).hour().minute())
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text("Apple's own classification, recorded at \(Int(ecg.samplingHz.rounded())) Hz and shown here at 100 Hz.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(StrandPalette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous))
                EcgPrintout(samples: ecg.samples)
                if let nearest {
                    EcgComparisonCard(noop: nearest.samples, noopDate: Date(timeIntervalSince1970: TimeInterval(nearest.row.startTs)),
                                      apple: ecg.samples, appleDate: ecg.start)
                } else if noopReadings.isEmpty {
                    Text("No strap reading to compare with yet.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                EcgMeasurementsSection(samples: ecg.samples)
            }
            .padding(16)
        }
        .background(StrandPalette.surfaceBase)
        .navigationTitle("Apple Watch ECG")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let target = ecg.start.timeIntervalSince1970
            guard let row = noopReadings.min(by: { abs(Double($0.startTs) - target) < abs(Double($1.startTs) - target) }),
                  let store = await repo.storeHandle(),
                  let packets = try? await store.ecgReadingPackets(id: row.id) else { return }
            nearest = (row, EcgSamples.flatten(packets))
        }
    }
}

/// The strap reading and the Apple Watch reading measured by the same code, side by side.
struct EcgComparisonCard: View {
    let noop: [Int16?]
    let noopDate: Date
    let apple: [Int16?]
    let appleDate: Date
    @State private var results: (noop: EcgAnalysis.Result?, apple: EcgAnalysis.Result?)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Compared with the strap")
                .textCase(.uppercase)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            if let results {
                VStack(spacing: 0) {
                    header
                    Divider()
                    row("Heart rate", results.noop?.meanHeartRate, results.apple?.meanHeartRate, unit: "bpm")
                    Divider()
                    row("PR interval", results.noop?.prMs, results.apple?.prMs, unit: "ms")
                    Divider()
                    row("QRS duration", results.noop?.qrsMs, results.apple?.qrsMs, unit: "ms")
                    Divider()
                    row("QT interval", results.noop?.qtMs, results.apple?.qtMs, unit: "ms")
                    Divider()
                    row("QTc (Fridericia)", results.noop?.qtcFridericiaMs, results.apple?.qtcFridericiaMs, unit: "ms")
                    Divider()
                    row("R wave", rAmplitude(results.noop), rAmplitude(results.apple), unit: "µV")
                    Divider()
                    row("RMSSD", results.noop?.rmssdMs, results.apple?.rmssdMs, unit: "ms")
                }
                .padding(.horizontal, 16)
                .background(StrandPalette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous))
                Text("Strap reading from \(noopDate, format: .dateTime.day().month().hour().minute()). Heart rate and RMSSD differ between two moments by nature; intervals, QTc and the R wave should agree closely if both devices see the same lead.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task {
            let a = noop, b = apple
            results = await Task.detached(priority: .userInitiated) {
                (EcgAnalysis.analyze(a), EcgAnalysis.analyze(b))
            }.value
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Text("Strap").frame(width: 64, alignment: .trailing)
            Text("Watch").frame(width: 64, alignment: .trailing)
            Text("Diff.").frame(width: 56, alignment: .trailing)
        }
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.vertical, 8)
    }

    private func row(_ label: LocalizedStringKey, _ a: Double?, _ b: Double?, unit: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer()
            Text(verbatim: a.map { "\(Int($0.rounded()))" } ?? "–").frame(width: 64, alignment: .trailing)
            Text(verbatim: b.map { "\(Int($0.rounded()))" } ?? "–").frame(width: 64, alignment: .trailing)
            Text(verbatim: diff(a, b)).frame(width: 56, alignment: .trailing)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .font(StrandFont.bodyNumber)
        .padding(.vertical, 8)
    }

    private func diff(_ a: Double?, _ b: Double?) -> String {
        guard let a, let b else { return "–" }
        let d = Int((a - b).rounded())
        return d > 0 ? "+\(d)" : "\(d)"
    }

    /// The R wave's height on the median beat, as a magnitude: its sign depends on how the lead is worn.
    private func rAmplitude(_ result: EcgAnalysis.Result?) -> Double? {
        guard let result, result.template.indices.contains(result.templateRIndex) else { return nil }
        return abs(result.template[result.templateRIndex])
    }
}
#endif
