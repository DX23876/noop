import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Re-stages the nights the wearer corrected, moved from `Repository` so the Apple and Android analysis passes heal
/// them alike (Android parity plan 1.1). A night edited before the strap sync imported its raw streams got
/// fabricated stages at edit time, and its `userEdited` flag then froze them against every later sync. `heal`,
/// called from the daily pass after each backfill, re-derives the stages from the raw now available over each edited
/// night's locked bounds and rewrites the stage breakdown only, never the wearer's bed and wake correction.
/// Idempotent: a night already staged from raw re-derives to the same JSON and is not written.
public enum EditedSleepHeal {
    /// Which stager and refinement re-stage a window; both are Lab switches the wearer can flip.
    public struct Staging: Sendable, Equatable {
        public var sleepV2: Bool, motionAwareWake: Bool
        public init(sleepV2: Bool, motionAwareWake: Bool) { self.sleepV2 = sleepV2; self.motionAwareWake = motionAwareWake }
        /// The value stored after a heal; a change re-stages every edited night once.
        public var signature: String { "sleepV2=\(sleepV2 ? 1 : 0)|motionAwareWake=\(motionAwareWake ? 1 : 0)" }
    }

    /// The stage JSON the raw streams give over `[start, end]` on `deviceId`, nil while the raw is not dense
    /// enough (about one motion sample per two minutes) to stage from.
    public static func restage(store: WhoopStore, deviceId: String, start: Int, end: Int,
                               staging: Staging) async -> String? {
        let lo = start - 3_600, hi = end + 3_600
        let grav = (try? await store.gravitySamples(deviceId: deviceId, from: lo, to: hi, limit: Int.max)) ?? []
        let inWindowGravity = grav.lazy.filter { $0.ts >= start && $0.ts <= end }.count
        let windowSeconds = max(1, end - start)
        guard inWindowGravity >= max(20, windowSeconds / 120) else { return nil }
        let hr = (try? await store.hrSamples(deviceId: deviceId, from: lo, to: hi, limit: Int.max)) ?? []
        let rr = (try? await store.rrIntervals(deviceId: deviceId, from: lo, to: hi, limit: Int.max)) ?? []
        // Same provenance refusal as the nightly scan: an Oura ring's respiration rows are its own per-window
        // rate, not the ~1 Hz raw waveform this stager reads (`OuraRespScale.forScoring`).
        let resp = OuraRespScale.forScoring(
            (try? await store.respSamples(deviceId: deviceId, from: lo, to: hi, limit: Int.max)) ?? [],
            deviceId: deviceId)
        let steps = staging.motionAwareWake
            ? ((try? await store.stepSamples(deviceId: deviceId, from: lo, to: hi, limit: Int.max)) ?? [])
            : []
        let useV2 = staging.sleepV2, refine = staging.motionAwareWake
        let segs = await Task.detached(priority: .utility) {
            let staged = useV2
                ? SleepStagerV2.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp)
                : SleepStager.stageSession(start: start, end: end, grav: grav, hr: hr, rr: rr, resp: resp)
            return WakeMotionRefinement.apply(staged, grav: grav, steps: steps, enabled: refine)
        }.value
        return AnalyticsEngine.encodeStages(segs)
    }

    /// Heals the edited nights in `[windowStart, windowEnd]` of `computedId` from the raw of `strapId` and returns
    /// the (possibly refreshed) edited rows, so the caller recomputes daily aggregates from the corrected stages.
    /// `unchangedDays` are the days the pass reused unchanged; their nights are skipped unless the staging changed
    /// since `lastSignature`. `saveSignature` records the staging that was applied.
    public static func heal(store: WhoopStore, strapId: String, computedId: String, from windowStart: Int,
                            to windowEnd: Int, unchangedDays: Set<String>, tzOffsetSeconds: Int, staging: Staging,
                            lastSignature: String?, saveSignature: (String) -> Void) async -> [CachedSleepSession] {
        func editedRows() async -> [CachedSleepSession] {
            ((try? await store.sleepSessions(deviceId: computedId, from: windowStart, to: windowEnd,
                                             limit: 100_000)) ?? []).filter { $0.userEdited }
        }
        let edited = await editedRows()
        guard !edited.isEmpty else { return [] }
        let stagingChanged = lastSignature != staging.signature
        var healed = false
        for row in edited where needsHeal(effectiveStartTs: row.effectiveStartTs, endTs: row.endTs,
                                          unchangedDays: stagingChanged ? [] : unchangedDays,
                                          tzOffsetSeconds: tzOffsetSeconds) {
            guard let newJSON = await restage(store: store, deviceId: strapId, start: row.effectiveStartTs,
                                              end: row.endTs, staging: staging),
                  newJSON != row.stagesJSON else { continue }
            let n = (try? await store.updateSleepStages(deviceId: computedId, detectedStartTs: row.startTs,
                                                        stagesJSON: newJSON)) ?? 0
            if n > 0 { healed = true }
        }
        saveSignature(staging.signature)
        return healed ? await editedRows() : edited
    }

    /// Whether an edited night must be re-staged this pass. A night belongs to the day it ends on; it is skipped
    /// only when that day is unchanged and the night lies inside the day's scan window (`StreamReadCap`), since
    /// the day's fingerprint vouches for nothing older.
    public static func needsHeal(effectiveStartTs: Int, endTs: Int, unchangedDays: Set<String>,
                                 tzOffsetSeconds: Int) -> Bool {
        let day = AnalyticsEngine.dayString(endTs, offsetSec: tzOffsetSeconds)
        guard unchangedDays.contains(day) else { return true }
        let dayStart = DailyAnalysis.midnightLocal(endTs, offsetSec: tzOffsetSeconds)
        return effectiveStartTs < dayStart - StreamReadCap.lookbackSeconds
    }
}
