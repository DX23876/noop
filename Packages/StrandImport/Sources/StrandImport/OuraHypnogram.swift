import Foundation

// MARK: - Oura compact per-epoch sleep strings (DOCUMENTED Oura API v2 encodings; NOOP's own decoder)
//
// The Oura `sleep` object carries two compact strings. Their digit legends are DIFFERENT — never share a
// decoder between them:
//   • sleep_phase_5_min / sleep_phase_30_sec — the hypnogram: '1'=deep, '2'=light, '3'=REM, '4'=awake.
//   • movement_30_sec                         — motion:      '1'=no motion, '2'=restless, '3'=tossing, '4'=active.

public enum OuraHypnogram {

    /// `sleep_phase_*` digit → NOOP stage string ("deep"/"light"/"rem"/"wake", matching
    /// `WearableSleepStageInterval`). Unknown digits → nil (skipped, the epoch clock still advances).
    public static func stageName(_ ch: Character) -> String? {
        switch ch {
        case "1": return "deep"
        case "2": return "light"
        case "3": return "rem"
        case "4": return "wake"
        default:  return nil
        }
    }

    /// Decode a `sleep_phase_5_min` (epochSeconds 300) or `sleep_phase_30_sec` (epochSeconds 30) string into
    /// contiguous [{stage,start,end}] segments, epoch-aligned from `start`. Adjacent equal stages are merged.
    public static func decode(_ phases: String, start: Date, epochSeconds: Int) -> [WearableSleepStageInterval] {
        var out: [WearableSleepStageInterval] = []
        for (i, ch) in phases.enumerated() {
            guard let stage = stageName(ch) else { continue }
            let segStart = start.addingTimeInterval(Double(i * epochSeconds))
            let segEnd = segStart.addingTimeInterval(Double(epochSeconds))
            if var last = out.last, last.stage == stage, last.end == segStart {
                last.end = segEnd
                out[out.count - 1] = last
            } else {
                out.append(WearableSleepStageInterval(stage: stage, start: segStart, end: segEnd))
            }
        }
        return out
    }

    /// Decode `movement_30_sec` into per-epoch motion magnitudes 1…4 (unknown digit → 0). 30-sec epochs.
    public static func movement(_ s: String) -> [Int] {
        s.map { ch in
            switch ch { case "1": return 1; case "2": return 2; case "3": return 3; case "4": return 4
                        default: return 0 }
        }
    }
}
