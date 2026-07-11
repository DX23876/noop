import Foundation

/// Pure mapping from NOOP's persisted sleep-stage JSON to the interval list the iOS HealthKit
/// write-back turns into `sleepAnalysis` category samples. Lives here (not in the app target) so
/// the parsing/clamping logic is covered by `swift test` — HealthKit itself can't be unit-tested.
public enum HealthWriteback {

    /// A HealthKit-agnostic sleep stage. The bridge maps these onto `HKCategoryValueSleepAnalysis`
    /// (`awake → .awake`, `light → .asleepCore`, `deep → .asleepDeep`, `rem → .asleepREM`).
    public enum StageKind: String, Equatable {
        case awake, light, deep, rem
    }

    public struct StageInterval: Equatable {
        public let start: Int   // unix seconds
        public let end: Int     // unix seconds, > start
        public let kind: StageKind
        public init(start: Int, end: Int, kind: StageKind) {
            self.start = start; self.end = end; self.kind = kind
        }
    }

    /// Decode a session's `stagesJSON` into clamped stage intervals for HealthKit.
    ///
    /// Only the on-device SleepStager segment shape (`[{"start","end","stage"}]`, unix seconds)
    /// carries timing, so only it yields intervals. The two aggregate shapes NOOP has also
    /// persisted (`{"deep":min,…}` and `[{"stage","min"}]` — see `WhoopCsvExporter.stageMinutes`)
    /// have no placement information; fabricating positions for them would write fiction into
    /// Health, so they return `[]` and the caller falls back to one `.asleepUnspecified` block.
    ///
    /// Normalization: the stager labels awake as `"wake"`, importers as `"awake"` — both map to
    /// `.awake`. Unknown labels are dropped. Segments are clamped to `[sessionStart, sessionEnd]`
    /// and zero/negative-length segments (before or after clamping) are dropped.
    public static func stageIntervals(stagesJSON: String?,
                                      sessionStart: Int,
                                      sessionEnd: Int) -> [StageInterval] {
        guard sessionEnd > sessionStart,
              let stagesJSON, let data = stagesJSON.data(using: .utf8),
              let segments = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return [] }
        var out: [StageInterval] = []
        for seg in segments {
            // Aggregate shape ([{"stage","min"}]) has no start/end — bail to the no-timing path
            // for the WHOLE session rather than emit a partial mix.
            guard let rawStart = intValue(seg["start"]), let rawEnd = intValue(seg["end"]) else {
                return []
            }
            guard let stage = (seg["stage"] as? String)?.lowercased() else { continue }
            let kind: StageKind?
            switch stage {
            case "wake", "awake": kind = .awake
            case "light":         kind = .light
            case "deep":          kind = .deep
            case "rem":           kind = .rem
            default:              kind = nil
            }
            guard let kind else { continue }
            let start = max(rawStart, sessionStart)
            let end = min(rawEnd, sessionEnd)
            guard end > start else { continue }
            out.append(StageInterval(start: start, end: end, kind: kind))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// JSON numbers arrive as Int, Double, or NSNumber depending on the writer; accept all.
    private static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let d as Double: return Int(d)
        default: return nil
        }
    }
}
