import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Saved WHOOP MG ECG readings on Android (parity plan 2.3), after Apple's `EcgReadingListView` and
/// `EcgReadingDetailView`: the list, one reading's sample strip with the strap's result, and the measurements
/// `EcgAnalysis` takes from the strip on display (nothing is stored). Recording itself needs the strap's Bluetooth
/// path and stays with the device.
enum CoreEcg {
    /// One sample every 10 ms (`EcgPaper.sampleRate`).
    static let sampleRate = 100

    struct Row: Encodable {
        var id: String, startTs: Int, category: String, title: String, tone: String
        var averageHr: Int?, variability: Int?, seconds: Int
        var wrist: String, resultCode: Int, quality: Int?, missingSegments: Int, interruptions: Int, status: String
        var unreadable: [String]
    }
    struct Detail: Encodable {
        var reading: Row
        /// The strip with lost seconds as gaps (null).
        var samples: [Int?]
        var analysis: Analysis?
    }
    struct Analysis: Encodable {
        var meanHeartRate: Double, minHeartRate: Double, maxHeartRate: Double, irregularBeats: Int
        var rmssdMs: Double?, sdnnMs: Double?, pnn50: Double?
        var template: [Double], templateRIndex: Int, beatsAveraged: Int, beatsDetected: Int
        var pOnsetMs: Double?, qrsOnsetMs: Double?, jPointMs: Double?, tEndMs: Double?
        var prMs: Double?, qrsMs: Double?, qtMs: Double?, qtcFridericiaMs: Double?
    }

    static func run(_ op: String, args: [String: Any], store: WhoopStore) async -> String {
        let id = args["id"] as? String ?? ""
        switch op {
        case "ecg.readings":
            return CoreRead.json(["readings": ((try? await store.ecgReadings()) ?? []).map(row)])
        case "ecg.reading":
            guard let reading = try? await store.ecgReadings().first(where: { $0.id == id }) else { return "null" }
            let samples = flatten((try? await store.ecgReadingPackets(id: id)) ?? [])
            return CoreRead.json(Detail(reading: row(reading), samples: samples.map { $0.map(Int.init) },
                                        analysis: analysis(samples)))
        case "ecg.delete":
            try? await store.deleteEcgReading(id: id)
            return CoreRead.json(["readings": ((try? await store.ecgReadings()) ?? []).map(row)])
        default:
            return #"{"error":"unknownOp"}"#
        }
    }

    /// `EcgSamples.flatten`: a lost packet becomes one second of gap.
    static func flatten(_ packets: [EcgReadingPacketRow]) -> [Int16?] {
        packets.flatMap { $0.isPlaceholder ? Array(repeating: nil, count: sampleRate) : $0.samples.map { Optional($0) } }
    }

    /// `EcgMeasurementsSection`: the strap's high-pass undone, then rhythm, HRV and the average beat's intervals.
    static func analysis(_ samples: [Int16?]) -> Analysis? {
        guard !samples.isEmpty,
              let a = EcgAnalysis.analyze(samples, compensatingHighPassHz: EcgAnalysis.strapHighPassHz) else { return nil }
        return Analysis(meanHeartRate: a.meanHeartRate, minHeartRate: a.minHeartRate, maxHeartRate: a.maxHeartRate,
                        irregularBeats: a.irregularBeats, rmssdMs: a.rmssdMs, sdnnMs: a.sdnnMs, pnn50: a.pnn50,
                        template: a.template, templateRIndex: a.templateRIndex, beatsAveraged: a.beatsAveraged,
                        beatsDetected: a.beatsDetected, pOnsetMs: a.fiducials?.pOnsetMs, qrsOnsetMs: a.fiducials?.qrsOnsetMs,
                        jPointMs: a.fiducials?.jPointMs, tEndMs: a.fiducials?.tEndMs, prMs: a.prMs, qrsMs: a.qrsMs,
                        qtMs: a.qtMs, qtcFridericiaMs: a.qtcFridericiaMs)
    }

    static func row(_ r: EcgReadingRow) -> Row {
        Row(id: r.id, startTs: r.startTs, category: r.category, title: title(r.category), tone: tone(r.category),
            averageHr: r.averageHr, variability: r.variabilityRaw, seconds: r.sampleCount / sampleRate, wrist: r.wrist,
            resultCode: r.resultCode, quality: r.quality, missingSegments: r.missingSegments,
            interruptions: r.interruptions, status: r.status, unreadable: unreadable(UInt8(clamping: r.unreadableMask)))
    }

    /// `EcgCategoryText.title`.
    static func title(_ raw: String) -> String {
        switch EcgCategory(rawValue: raw) {
        case .sinusRhythm: return String(localized: "Sinus rhythm")
        case .lowHeartRate: return String(localized: "Low heart rate")
        case .possibleAfib: return String(localized: "Signs of atrial fibrillation")
        case .afibHighHeartRate: return String(localized: "Signs of atrial fibrillation, high heart rate")
        case .highHeartRate: return String(localized: "High heart rate")
        case .highHeartRateNoAfib: return String(localized: "High heart rate, no signs of atrial fibrillation")
        case .inconclusive: return String(localized: "Inconclusive")
        case .unreadable, .none: return String(localized: "Unreadable")
        }
    }

    /// `EcgCategoryText.tint` as a tone the Android palette resolves.
    static func tone(_ raw: String) -> String {
        switch EcgCategory(rawValue: raw) {
        case .sinusRhythm: return "positive"
        case .possibleAfib, .afibHighHeartRate: return "critical"
        case .lowHeartRate, .highHeartRate, .highHeartRateNoAfib: return "warning"
        default: return "neutral"
        }
    }

    /// `EcgCategoryText.unreadableReasons`.
    static func unreadable(_ mask: UInt8) -> [String] {
        let m = EcgUnreadableMask(raw: mask)
        var out: [String] = []
        if m.lowAmplitude { out.append(String(localized: "The signal was too weak.")) }
        if m.significantNoise { out.append(String(localized: "There was too much noise.")) }
        if m.unstableSignal { out.append(String(localized: "The signal was unstable.")) }
        if m.notEnoughData { out.append(String(localized: "There was not enough data.")) }
        return out
    }
}
