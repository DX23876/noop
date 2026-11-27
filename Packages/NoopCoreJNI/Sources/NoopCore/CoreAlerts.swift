import Foundation
import StrandAnalytics

/// What the Android alert settings need from the shared code (Android parity, Settings): the Training Load alert's
/// once-per-high-phase decision (`TrainingLoadAlert`) and the heart-rate ceiling's buzz decision
/// (`HRCeilingAlertEngine`), the two rules the Apple Notifications and Strap Actions pages run. Pure and without a
/// store; Kotlin keeps the switches, the notification and the buzz itself.
enum CoreAlerts {

    static func run(_ op: String, _ args: [String: Any]) -> String? {
        switch op {
        case "alerts.trainingLoad": return trainingLoad(args)
        case "alerts.hrCeiling": return hrCeiling(args)
        default: return nil
        }
    }

    // MARK: - Training load alert

    struct LaneAnswer: Encodable {
        let kind: String
        /// Whether to post for this lane now.
        let notify: Bool
        /// The lane's new episode state, to be kept for the next read.
        let episodeOpen: Bool
    }

    /// `lanes`: `[{kind, band, episodeOpen}]` as the Training Load read states them (`band` is the
    /// `RelativeLoadBand` raw value or absent); `enabled`: the alert's switch. One answer per lane, in order.
    static func trainingLoad(_ args: [String: Any]) -> String {
        let enabled = args["enabled"] as? Bool ?? false
        let lanes = (args["lanes"] as? [[String: Any]]) ?? []
        let answers = lanes.map { lane -> LaneAnswer in
            let band = (lane["band"] as? String).flatMap(RelativeLoadBand.init(rawValue:))
            let decision = TrainingLoadAlert.decide(enabled: enabled, band: band, episodeOpen: lane["episodeOpen"] as? Bool ?? false)
            return LaneAnswer(kind: lane["kind"] as? String ?? "", notify: decision.notify, episodeOpen: decision.episodeOpen)
        }
        return CoreRead.json(["lanes": answers])
    }

    // MARK: - Heart-rate ceiling

    struct StateWire: Encodable {
        let recoverySince: Int?, lastWarningAt: Int?, lastSampleAt: Int?, warningCount: Int
        /// What the engine last ran with, so a changed ceiling, gate or frequency starts a fresh episode.
        let lastCeiling: Double?, lastGate: Bool, lastReminder: String?
    }

    struct CeilingAnswer: Encodable {
        /// The ceiling in force (bpm), nil when it cannot be resolved.
        let ceiling: Double?
        /// The whole-bpm value the wearer crosses ("Buzz at N BPM"); nil with the ceiling.
        let displayBpm: Int?
        /// `warning`, `recovered` or nil: what the engine asks of the strap on this sample.
        let cue: String?
        /// How many loops the strap buzzes for the cue (0 without one).
        let loops: Int
        /// Whether a ceiling episode is running, which owns the wrist over lower-priority cues.
        let episodeActive: Bool
        let state: StateWire
    }

    /// The ceiling the wearer set: a profile zone (`zoneLowerBpm` is the five band starts, `allowedZone` 1 to 4 the
    /// highest zone allowed) or a fixed `fixedBpm`. With `bpm` (nil for no reading), `now` (epoch seconds), `gate`
    /// and `reminderMode` it advances the engine one sample from `state` and answers the cue; without `now` it only
    /// resolves the ceiling for the "Buzz at" line.
    static func hrCeiling(_ args: [String: Any]) -> String {
        func int(_ key: String) -> Int? { (args[key] as? NSNumber)?.intValue }
        let mode = args["mode"] as? String ?? "zone"
        let ceiling: Double?
        if mode == "bpm" {
            ceiling = int("fixedBpm").map { Double(min(max($0, 40), 220)) }
        } else {
            let lower = (args["zoneLowerBpm"] as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
            let maxHR = (args["maxHR"] as? NSNumber)?.doubleValue ?? 0
            if lower.count == 5 {
                let zones = lower.enumerated().map { i, start in
                    HRZone(number: i + 1, lower: start, upper: i < 4 ? lower[i + 1] : max(maxHR, start),
                           lowerPct: maxHR > 0 ? start / maxHR : 0,
                           upperPct: maxHR > 0 ? (i < 4 ? lower[i + 1] : max(maxHR, start)) / maxHR : 0)
                }
                ceiling = HRCeilingAlertEngine.profileZoneCeiling(
                    zoneSet: HRZoneSet(zones: zones, maxHR: maxHR, source: "custom"),
                    allowedZone: min(max(int("allowedZone") ?? 4, 1), 4))
            } else {
                ceiling = nil
            }
        }
        // Whole-bpm boundary the wearer will actually cross. A fractional profile edge (142.4) first admits the
        // integer sample 143, so the readout rounds up rather than to nearest.
        let display: Int? = ceiling.map { mode == "bpm" ? Int($0) : Int(($0 - HRZoneSet.edgeEpsilon).rounded(.up)) }

        let old = args["state"] as? [String: Any] ?? [:]
        func oldInt(_ key: String) -> Int? { (old[key] as? NSNumber)?.intValue }
        let reminderRaw = args["reminderMode"] as? String ?? HRCeilingReminderMode.standard.rawValue
        let reminder = HRCeilingReminderMode(rawValue: reminderRaw) ?? .standard
        let gate = args["gate"] as? Bool ?? false
        guard let now = int("now"), let ceiling else {
            let carried = StateWire(recoverySince: oldInt("recoverySince"), lastWarningAt: oldInt("lastWarningAt"),
                                    lastSampleAt: oldInt("lastSampleAt"), warningCount: oldInt("warningCount") ?? 0,
                                    lastCeiling: (old["lastCeiling"] as? NSNumber)?.doubleValue,
                                    lastGate: old["lastGate"] as? Bool ?? false, lastReminder: old["lastReminder"] as? String)
            return CoreRead.json(CeilingAnswer(ceiling: ceiling, displayBpm: display, cue: nil, loops: 0,
                                               episodeActive: carried.warningCount > 0, state: carried))
        }

        var engine = HRCeilingAlertEngine(state: .init(recoverySince: oldInt("recoverySince"), lastWarningAt: oldInt("lastWarningAt"),
                                                       lastSampleAt: oldInt("lastSampleAt"), warningCount: oldInt("warningCount") ?? 0))
        // Any change of ceiling, gate or frequency starts a fresh episode; an old warning or reminder must never
        // carry into a newly selected zone, fixed value or workout-only activation.
        let lastCeiling = (old["lastCeiling"] as? NSNumber)?.doubleValue
        if lastCeiling != ceiling || (old["lastGate"] as? Bool ?? false) != gate || (old["lastReminder"] as? String) != reminder.rawValue {
            engine.reset()
        }
        let bpm = int("bpm")
        let cue = engine.update(now: now, bpm: bpm, ceilingBPM: ceiling, enabled: gate, reminderMode: reminder)
        let loops: Int
        switch cue {
        case .warning: loops = reminder == .everyTwoSeconds ? 1 : 3
        case .recovered: loops = 1
        case nil: loops = 0
        }
        let next = engine.state
        return CoreRead.json(CeilingAnswer(
            ceiling: ceiling, displayBpm: display,
            cue: cue.map { $0 == .warning ? "warning" : "recovered" }, loops: loops, episodeActive: engine.episodeActive,
            state: StateWire(recoverySince: next.recoverySince, lastWarningAt: next.lastWarningAt, lastSampleAt: next.lastSampleAt,
                             warningCount: next.warningCount, lastCeiling: ceiling, lastGate: gate, lastReminder: reminder.rawValue)))
    }
}
