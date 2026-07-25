import Foundation

/// Derive `hrSample`-shaped HR from the ring's BANKED IBI (`OuraIBI`). The Oura ring banks overnight IBI
/// (`0x60`/`0x80`/`0x6E`) but NO heart-rate stream, so an Oura night otherwise lands only in `rrInterval`
/// — and the nightly analytics pipeline gates on `hrSample` (`resolveDayOwner`'s presence probe + the
/// `hr.count >= 200` guard), so with zero overnight HR the day-owner falls back off the ring and the whole
/// night scores NULL (no restingHr / HRV, and skin temp is gated behind the same probe). Materialising a
/// per-record HR from the banked IBI unblocks that (issue #728).
///
/// Pure + fixture-tested. Called ONLY from the banked/history path (`OuraLiveSource.ingestHistory`); the
/// live-HR push already emits its own `.hr`, so live HR is never double-counted here. Twin of the Kotlin
/// `OuraIbiHr`.
public enum OuraIbiHr {

    /// One median HR per IBI-RECORD. Every IBI decoded from a single record carries that record's ring-time,
    /// so grouping by `ringTimestamp` == grouping by record; `HR = round(60000 / median(IBI))` over the
    /// record's PHYSIOLOGICAL beats (IBI 300..2000 ms), gated to a plausible 30..220 bpm. Records are
    /// returned oldest-ring-time first. A record with no in-range beat, or whose median HR is implausible,
    /// yields nothing (honest-data invariant: never a guessed beat). Grouping by ring-time also collapses a
    /// record's 6-or-7 same-timestamped beats into ONE row, matching the `hrSample (deviceId, ts)` key.
    public static func perRecordMedianHR(_ ibis: [OuraIBI]) -> [OuraHR] {
        var byRingTime: [UInt32: [Int]] = [:]
        for ibi in ibis where ibi.ibiMs >= 300 && ibi.ibiMs <= 2000 {
            byRingTime[ibi.ringTimestamp, default: []].append(ibi.ibiMs)
        }
        var out: [OuraHR] = []
        for rt in byRingTime.keys.sorted() {
            guard let intervals = byRingTime[rt], !intervals.isEmpty else { continue }
            let medIbi = Self.median(intervals)
            let bpm = Int((60_000.0 / Double(medIbi)).rounded())
            guard bpm >= 30 && bpm <= 220 else { continue }
            out.append(OuraHR(ringTimestamp: rt, bpm: bpm, ibiMs: medIbi))
        }
        return out
    }

    /// Integer median (even count → mean of the two middle values). Input is copied + sorted.
    static func median(_ xs: [Int]) -> Int {
        let s = xs.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
