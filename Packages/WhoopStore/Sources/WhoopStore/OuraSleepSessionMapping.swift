import Foundation
import OuraProtocol

/// Pure, testable mapping from a reconstructed Oura hypnogram (the anchored per-code stage sequence
/// `OuraHypnogramAssembler.codesWithTimes` lays at the 30 s SleepNet epoch) onto a `CachedSleepSession`
/// whose `stagesJSON` is the SAME `[{start,end,stage}]` segment shape the on-device `SleepStager` and the
/// Apple-Health / Health-Connect importers write (see `SleepStageTotals.minutes`).
///
/// WHY a session and not just the stream: the raw per-code stages already persist as `OURA_SLEEP_PHASE`
/// events (`OuraStreamMapping`), but nothing turns them into a NIGHT with a stage breakdown that the sleep
/// surfaces read. Banking the ring-PROVIDED hypnogram as a `CachedSleepSession` under the ring's OWN
/// deviceId (the imported/measured side, not the `-noop` computed sibling) lets `SleepMerge`'s existing
/// imported-over-computed rule make Oura's own SleepNet staging win over NOOP's sparse-motion computed
/// staging for that night — "richer record wins", reusing the exact arbitration that already picks a
/// WHOOP/HC import over a computed night (ryanbr/noop#240). The richness exception in `SleepMerge` still
/// protects a stage-rich computed night from a stage-less import, and vice-versa.
///
/// HONEST-DATA: this is PROVIDED data (Oura's on-ring classifier), not a NOOP-COMPUTED derivation — it is
/// the Tier-A sleep-phase codes already surfaced, only reshaped into the session's segment JSON. No new
/// physiological signal is invented here.
///
/// PARITY: the `stagesJSON` string is built by hand in a FIXED key order (`start`,`end`,`stage`) so Swift
/// and Kotlin emit the BYTE-IDENTICAL segment JSON for the same codes (the cross-platform stored-value
/// contract). Must stay in lockstep with the Kotlin twin (`OuraSleepSessionMapping.kt`).
public enum OuraSleepSessionMapping {

    /// Stage token per code — the on-device stager / importer convention `SleepStageTotals` decodes:
    /// "deep"/"light"/"rem"/"wake" (awake is written "wake"). `OuraSleepStage`: 0=deep,1=light,2=rem,3=awake.
    static func token(_ stage: OuraSleepStage) -> String {
        switch stage {
        case .deep:  return "deep"
        case .light: return "light"
        case .rem:   return "rem"
        case .awake: return "wake"
        }
    }

    /// Build a `CachedSleepSession` from the anchored per-code stage sequence (ascending `ts`, one code per
    /// `secondsPerCode` epoch, exactly as `OuraHypnogramAssembler.codesWithTimes` produces after the burst
    /// end is anchored + 0x49-refined). Adjacent equal stages are merged into one `[start,end]` segment.
    /// `startTs` = first code's ts; `endTs` = last code's ts + one epoch (the anchored true sleep end).
    /// `efficiency` = asleep / (asleep + awake) as a 0–1 fraction (nil when nothing is in bed). Returns nil
    /// for an empty sequence (never a zero-length night). `restingHr`/`avgHrv` stay nil — those are NOOP's
    /// own downstream computations from the ring's IBI stream, not part of the ring's provided hypnogram.
    public static func session(fromCodes codes: [(ts: Int, stage: OuraSleepStage)],
                               secondsPerCode: Int = 30) -> CachedSleepSession? {
        guard let first = codes.first, let last = codes.last else { return nil }

        // Merge adjacent equal stages into contiguous [start,end] segments.
        struct Seg { var start: Int; var end: Int; let stage: OuraSleepStage }
        var segs: [Seg] = []
        for c in codes {
            let segEnd = c.ts + secondsPerCode
            if var lastSeg = segs.last, lastSeg.stage == c.stage, lastSeg.end == c.ts {
                lastSeg.end = segEnd
                segs[segs.count - 1] = lastSeg
            } else {
                segs.append(Seg(start: c.ts, end: segEnd, stage: c.stage))
            }
        }

        // Hand-built JSON, fixed key order → byte-identical to the Kotlin twin.
        let json = "[" + segs.map {
            "{\"start\":\($0.start),\"end\":\($0.end),\"stage\":\"\(token($0.stage))\"}"
        }.joined(separator: ",") + "]"

        var asleepSec = 0, awakeSec = 0
        for c in codes {
            if c.stage == .awake { awakeSec += secondsPerCode } else { asleepSec += secondsPerCode }
        }
        let inBedSec = asleepSec + awakeSec
        let efficiency = inBedSec > 0 ? Double(asleepSec) / Double(inBedSec) : nil

        return CachedSleepSession(startTs: first.ts, endTs: last.ts + secondsPerCode,
                                  efficiency: efficiency, restingHr: nil, avgHrv: nil,
                                  stagesJSON: json)
    }
}
