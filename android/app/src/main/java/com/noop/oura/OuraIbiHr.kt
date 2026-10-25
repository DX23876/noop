package com.noop.oura

/**
 * Derive `hrSample`-shaped HR from the ring's BANKED IBI ([OuraIBI]). The Oura ring banks overnight IBI
 * (0x60/0x80/0x6E) but NO heart-rate stream, so an Oura night otherwise lands only in `rrInterval` — and
 * the nightly analytics pipeline gates on `hrSample` (the day-owner presence probe + the `hr.count >= 200`
 * guard), so with zero overnight HR the day-owner falls back off the ring and the whole night scores NULL
 * (no restingHr / HRV, and skin temp is gated behind the same probe). Materialising a per-record HR from
 * the banked IBI unblocks that (issue #728).
 *
 * Pure + fixture-tested. Called ONLY from the banked/history path (OuraLiveSource.ingestHistory); the
 * live-HR push already emits its own `.hr`, so live HR is never double-counted here. Twin of the Swift
 * OuraIbiHr.
 */
object OuraIbiHr {

    /**
     * One median HR per IBI-RECORD. Every IBI decoded from a single record carries that record's ring-time,
     * so grouping by [OuraIBI.ringTimestamp] == grouping by record; `HR = round(60000 / median(IBI))` over
     * the record's PHYSIOLOGICAL beats (IBI 300..2000 ms), gated to a plausible 30..220 bpm. Records are
     * returned oldest-ring-time first. A record with no in-range beat, or whose median HR is implausible,
     * yields nothing (honest-data invariant). Grouping by ring-time also collapses a record's 6-or-7
     * same-timestamped beats into ONE row, matching the `hrSample (deviceId, ts)` key.
     */
    fun perRecordMedianHR(ibis: List<OuraIBI>): List<OuraHR> {
        val byRingTime = HashMap<Long, MutableList<Int>>()
        for (ibi in ibis) {
            if (ibi.ibiMs in 300..2000) byRingTime.getOrPut(ibi.ringTimestamp) { ArrayList() }.add(ibi.ibiMs)
        }
        val out = ArrayList<OuraHR>()
        for (rt in byRingTime.keys.sorted()) {
            val intervals = byRingTime[rt] ?: continue
            if (intervals.isEmpty()) continue
            val medIbi = median(intervals)
            val bpm = Math.round(60_000.0 / medIbi).toInt()
            if (bpm in 30..220) out.add(OuraHR(ringTimestamp = rt, bpm = bpm, ibiMs = medIbi))
        }
        return out
    }

    /** Integer median (even count → mean of the two middle values). Input is copied + sorted. */
    private fun median(xs: List<Int>): Int {
        val s = xs.sorted()
        val n = s.size
        return if (n % 2 == 1) s[n / 2] else (s[n / 2 - 1] + s[n / 2]) / 2
    }
}
