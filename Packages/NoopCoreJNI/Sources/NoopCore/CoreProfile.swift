import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// What the Android Profile page needs from the shared code (Android parity, Settings): the maximum heart rate
/// and where it came from, the hint under an entered VO₂max, and the heart-rate zone editor. The rules are the
/// ones the Apple Profile page reads (`MaxHeartRate`, `PeakMETResolver`, `HRZones`); Kotlin keeps the screen.
enum CoreProfile {

    static func run(_ op: String, _ args: [String: Any]) async -> String? {
        switch op {
        case "profile.maxHeartRate": return await maxHeartRate(args)
        case "profile.vo2Hint": return await vo2Hint(args)
        case "profile.zones": return zones(args)
        default: return nil
        }
    }

    // MARK: - Maximum heart rate

    struct MaxHeartRateAnswer: Encodable {
        /// The value in force, whole bpm.
        let bpm: Int
        /// `MaxHeartRate.Source` raw value: override, measured, gellish or default.
        let source: String
        /// The day a measured level was last confirmed; only with source "measured".
        let confirmedOn: String?
    }

    /// The maximum heart rate for an age and an optional manual setting, with the level the daily pass measured
    /// in workouts when there is one. `override` 0 asks for the automatic value.
    @MainActor
    static func resolveMaxHeartRate(age: Int, override: Int, measured: MaxHeartRate.Level?) -> MaxHeartRateAnswer {
        let resolved = MaxHeartRate.resolve(overrideBpm: override, age: Double(age), measured: measured?.bpm)
        return MaxHeartRateAnswer(bpm: resolved.wholeBpm, source: resolved.source.rawValue,
                                  confirmedOn: resolved.source == .measured ? measured?.confirmedOn : nil)
    }

    private static func maxHeartRate(_ args: [String: Any]) async -> String {
        let age = (args["age"] as? NSNumber)?.intValue ?? 0
        let override = (args["override"] as? NSNumber)?.intValue ?? 0
        return CoreRead.json(await resolveMaxHeartRate(age: age, override: override,
                                                       measured: CoreAnalysis.measuredMaxHeartRate))
    }

    // MARK: - Hint under an entered VO₂max

    /// Whether the aerobic ceiling in use comes from the formula for a body outside what it was fitted on
    /// (`PeakMETResolver.measurementAdvised`), read from the newest energy day the store holds.
    private static func vo2Hint(_ args: [String: Any]) async -> String {
        let weight = (args["weightKg"] as? NSNumber)?.doubleValue ?? 0
        let height = (args["heightCm"] as? NSNumber)?.doubleValue ?? 0
        var source: PeakMETResolution.Source?
        var rowWeight: Double?
        if let (store, _) = ShadowSession.storeAndPath {
            let today = StoreReader.localDayKey(Date())
            let rows = (try? await store.whoopDailyEnergy(deviceId: ShadowSession.activeDeviceId,
                                                          from: WeeklyDigestEngine.addDays(today, -7), to: today)) ?? []
            let row = rows.filter { $0.modelVersion == WhoopDailyEnergyEstimate.modelVersion }.max { $0.day < $1.day }
            source = row?.peakMETSource.flatMap(PeakMETResolution.Source.init(rawValue:))
            rowWeight = row?.weightKg
        }
        let advised = PeakMETResolver.measurementAdvised(source: source, weightKg: rowWeight ?? weight, heightCm: height)
        return CoreRead.json(["advised": advised])
    }

    // MARK: - Heart-rate zone editor

    struct ZoneRow: Encodable {
        let number: Int
        let lowerBpm: Int
        /// The last whole bpm that still counts as this zone (zone 5 ends on the maximum itself).
        let upperBpm: Int
        /// Shortest exact percent texts ("65", "62.5") of the band's edges, as the Apple editor prints them.
        let lowerPercentText: String
        let upperPercentText: String
    }

    struct ZonesAnswer: Encodable {
        let mode: String
        /// The draft's five lower bounds in each unit, seeded when the caller sent none.
        let percents: [Double]
        let bpms: [Double]
        /// Whether the draft is a legal set; the preview shows the stored zones while it is not.
        let legal: Bool
        let zones: [ZoneRow]
        /// The row summary: whether the resolved zones are the wearer's own and the five bounds as text.
        let custom: Bool
        let bounds: String
        /// The bounds as the effective bpm lower bounds, for the readers that bucket a heart rate.
        let lowerBpm: [Double]
    }

    /// Resolves, steps and validates one draft of the zone editor.
    ///
    /// Arguments: `mode` (auto, percent or bpm), the stored `percents` (as percents) and `bpms`, `maxHR`,
    /// `autoSource`, and optionally `step: {index, up}` to move one bound a notch the way the Apple editor does.
    /// Unset bounds are seeded from the zones in force, so the mode the wearer is not on still has numbers.
    static func zones(_ args: [String: Any]) -> String {
        let maxHR = max(1, (args["maxHR"] as? NSNumber)?.doubleValue ?? 0)
        let mode = HRZoneConfig.Mode(rawValue: args["mode"] as? String ?? "") ?? .auto
        let autoSource = args["autoSource"] as? String ?? "manual"
        func numbers(_ key: String) -> [Double] {
            (args[key] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
        }
        var percents = numbers("percents"), bpms = numbers("bpms")
        let stored = HRZoneConfig(mode: mode, percentLowerBounds: percents.map { $0 / 100 }, bpmLowerBounds: bpms)
        let inForce = HRZones.zones(config: stored, maxHR: maxHR, autoSource: autoSource)
        if percents.count != 5 { percents = inForce.zones.map { ($0.lowerPct * 1000).rounded() / 10 } }
        if bpms.count != 5 { bpms = inForce.zones.map { $0.lower.rounded(.up) } }

        if let step = args["step"] as? [String: Any], let index = (step["index"] as? NSNumber)?.intValue {
            let up = step["up"] as? Bool ?? true
            switch mode {
            case .auto: break
            case .percent:
                guard percents.indices.contains(index) else { break }
                let notch = 0.5
                let next = ((percents[index] + (up ? notch : -notch)) / notch).rounded() * notch
                percents[index] = min(max(next, HRZones.minEdge * 100), (1.0 - HRZones.minEdgeGap) * 100)
            case .bpm:
                guard bpms.indices.contains(index) else { break }
                let next = ((bpms[index] + (up ? 1 : -1)) / 1).rounded()
                bpms[index] = min(max(next, HRZones.minBpmEdge), max(HRZones.minBpmEdge, maxHR - HRZones.minBpmGap))
            }
        }

        let edges: [Double]?
        switch mode {
        case .auto: edges = HRZones.zoneEdges
        case .percent: edges = HRZones.validatedEdges(lowerPercents: percents.map { $0 / 100 })
        case .bpm: edges = HRZones.validatedBpmEdges(lowerBpm: bpms, maxHR: maxHR)
        }
        let preview: HRZoneSet
        if let edges {
            switch mode {
            case .auto, .percent: preview = HRZones.zones(maxHR: maxHR, edges: edges)
            case .bpm: preview = HRZones.zones(bpmEdges: edges, maxHR: maxHR)
            }
        } else {
            preview = inForce
        }
        let draft = HRZoneConfig(mode: mode, percentLowerBounds: percents.map { $0 / 100 }, bpmLowerBounds: bpms)
        let resolved = edges == nil ? inForce : HRZones.zones(config: draft, maxHR: maxHR, autoSource: autoSource)
        let custom = edges != nil && draft.isCustom(maxHR: maxHR)
        let bounds: String
        if mode == .bpm {
            bounds = resolved.zones.map { String(format: "%.0f", $0.lower.rounded()) }.joined(separator: "/") + " bpm"
        } else {
            bounds = resolved.zones.map { percentText($0.lowerPct) }.joined(separator: "/") + "%"
        }
        let rows = preview.zones.map { zone in
            ZoneRow(number: zone.number, lowerBpm: Int(zone.lower.rounded()),
                    upperBpm: zone.number == 5 ? Int(zone.upper.rounded()) : Int(zone.upper.rounded()) - 1,
                    lowerPercentText: percentText(zone.lowerPct), upperPercentText: percentText(zone.upperPct))
        }
        return CoreRead.json(ZonesAnswer(mode: mode.rawValue, percents: percents, bpms: bpms, legal: edges != nil,
                                         zones: rows, custom: custom, bounds: bounds,
                                         lowerBpm: preview.zones.map(\.lower)))
    }

    /// A band bound (a fraction of the maximum) as the shortest exact percent text: "65", or "62.5".
    static func percentText(_ fraction: Double) -> String {
        let v = (fraction * 1000).rounded() / 10
        return abs(v - v.rounded()) < 1e-9 ? String(format: "%.0f", v.rounded()) : String(format: "%.1f", v)
    }
}
