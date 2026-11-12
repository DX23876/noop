import Foundation
import StrandCore
import StrandAnalytics

/// The live workout's voice on Android (`WorkoutVoiceDecider`, the decision iOS's `WorkoutVoiceCoach` runs): Kotlin
/// hands in the wearer's choices and the running workout each second and gets back whether to warn or announce.
/// One workout at a time; the words and the speech stay with the platform.
enum CoreWorkoutVoice {
    private static var decider = WorkoutVoiceDecider()
    /// GPS auto-pause (`WorkoutAutoPauseEngine`), as iOS's `AppModel.evaluateWorkoutAutoPause` runs it.
    private static var autoPause = WorkoutAutoPauseEngine()
    private static let lock = NSLock()

    static func run(_ op: String, _ args: [String: Any]) -> String? {
        func d(_ k: String) -> Double? { (args[k] as? NSNumber)?.doubleValue }
        func b(_ k: String) -> Bool { args[k] as? Bool ?? false }
        func range(_ lo: String, _ hi: String) -> ClosedRange<Double>? {
            guard let l = d(lo), let h = d(hi), l.isFinite, h.isFinite, l <= h else { return nil }
            return l...h
        }
        let settings = WorkoutVoiceDecider.Settings(
            voiceEnabled: b("voice"), distanceInterval: d("distanceInterval") ?? 1, timeIntervalSeconds: d("timeInterval") ?? 600,
            imperial: b("imperial"), usesRoute: b("usesRoute"), heartRateAlert: b("heartRateAlert"), motionAlert: b("motionAlert"),
            paceRange: range("fastPace", "slowPace"), speedRangeKmh: range("lowSpeed", "highSpeed"))
        // Speed or pace is the catalogue's call (`WorkoutCatalog.usesSpeedReadout`), so both platforms read it alike.
        let usesSpeed = WorkoutCatalog.usesSpeedReadout(for: args["sport"] as? String ?? "")
        let snapshot = WorkoutVoiceDecider.Snapshot(
            now: d("now") ?? Date().timeIntervalSince1970, elapsedSeconds: (args["elapsed"] as? Int) ?? 0,
            distanceMeters: d("distance"), distanceFresh: b("distanceFresh"), isPaused: b("paused"),
            zone: args["zone"] as? Int, targetZone: args["targetZone"] as? Int, speedMps: d("speed"),
            usesSpeed: usesSpeed)
        lock.lock(); defer { lock.unlock() }
        switch op {
        case "workout.voice.begin":
            decider.begin(settings: settings, snapshot: snapshot)
            return #"{"ok":true}"#
        case "workout.voice.autoPause":
            // `stationary` absent means no trustworthy motion this second, which decides nothing.
            let enabled = b("enabled") && WorkoutVoiceDecider.supportsAutoPause(sport: args["sport"] as? String ?? "",
                                                                                gps: b("gps"))
            if b("reset") { autoPause.reset(); return "{}" }
            let action = autoPause.update(now: snapshot.now, stationary: args["stationary"] as? Bool, moving: b("moving"),
                                          enabled: enabled, paused: b("paused"), automaticallyPaused: b("autoPaused"))
            return action.map { #"{"action":"\#($0 == .pause ? "pause" : "resume")"}"# } ?? "{}"
        case "workout.voice.sport":
            // Whether the sport reads speed rather than pace, for the recap after the workout.
            let offers = WorkoutVoiceDecider.supportsAutoPause(sport: args["sport"] as? String ?? "", gps: true)
            return #"{"usesSpeed":\#(usesSpeed),"autoPause":\#(offers)}"#
        case "workout.voice.phase":
            decider.phaseCue(at: snapshot.now)
            return #"{"ok":true}"#
        case "workout.voice.tick":
            switch decider.tick(settings: settings, snapshot: snapshot) {
            case .warning(let w): return #"{"warning":"\#(w.rawValue)","usesSpeed":\#(usesSpeed)}"#
            case .announce(let m):
                return m.map { #"{"announce":true,"distance":\#($0),"usesSpeed":\#(usesSpeed)}"# }
                    ?? #"{"announce":true,"usesSpeed":\#(usesSpeed)}"#
            case nil: return #"{"usesSpeed":\#(usesSpeed)}"#
            }
        default: return nil
        }
    }
}
