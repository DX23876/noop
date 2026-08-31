import Foundation

/// How much of a sleep session's `[startTs, endTs)` span its stage segments actually account for.
///
/// WHY THIS EXISTS. A session's stage timeline is supposed to TILE its span — `SleepStageTotals`
/// says so explicitly ("the segment stages noop stores ... TILE the window ... Σ stage minutes equals
/// the clock span"), and every consumer is written as though it does. One producer breaks that
/// invariant: a device-PROVIDED hypnogram assembled from records that arrived INCOMPLETE. The Oura
/// path (`OuraSleepSessionMapping`) merges only CONTIGUOUS codes, so a sleep-phase page that never
/// arrived leaves a hole in `stagesJSON` while `startTs`/`endTs` still span the whole night. The
/// result is a session that looks well-formed — non-empty, many segments, a plausible efficiency —
/// but describes a fraction of the night it claims.
///
/// Measured on 31 consecutive ring nights, 8 of them came in under 95% and one covered 23% of its
/// own span (601 min claimed, 140 min of segments). Downstream that night was stored as 70 minutes of
/// sleep against a paired strap's 494, and nothing flagged it: the merge's richness rule tests only
/// that stages are PRESENT, and Rest's two confidence guards are `gravitySparse` (inert here — Oura
/// stores no gravity at all, so `isGravitySparse` returns false for every ring night) and the #H9
/// restorative floor (needs efficiency ≥ 0.85; the holed night read 0.50).
///
/// So the missing quantity is not a new measurement — it is a RATIO of two numbers already stored.
/// Nothing here is persisted and no migration is needed: coverage is derived on read, which also means
/// it applies retroactively to nights already in the database.
///
/// HONEST-DATA: this only ever reports how much of the night was OBSERVED. It never fills a hole in,
/// and in particular it must not let a caller treat unobserved time as awake — we do not know what
/// happened there, and asserting wake would be the same overreach in the opposite direction.
///
/// PARITY: pure + deterministic, byte-identical to the Kotlin twin
/// (`com.noop.analytics.HypnogramCoverage`). Keep the two in lockstep.
public enum HypnogramCoverage {

    /// Coverage at or above which a stage timeline is treated as describing its whole span.
    ///
    /// The observed split is wide: healthy nights land at 99–100%, the broken ones at 23–93%. 0.95
    /// sits in the empty middle, so the gate is not balanced on the edge of the data.
    public static let minCoverage: Double = 0.95

    /// The covered fraction of `spanSeconds`, or nil when the question does not apply.
    ///
    /// Returns nil — meaning "unknown, do not judge" — rather than 0 when there is nothing to measure,
    /// so an unknown coverage can never be mistaken for a bad one by a caller that compares against
    /// `minCoverage`. Clamped to at most 1: segments that overlap or overhang would otherwise report
    /// more than a full night, and for a completeness gate the safe direction is to read that as
    /// "complete" rather than to invent a failure out of malformed input.
    public static func fraction(coveredSeconds: Double, spanSeconds: Double) -> Double? {
        guard spanSeconds > 0, coveredSeconds > 0 else { return nil }
        return min(1.0, coveredSeconds / spanSeconds)
    }

    /// The covered fraction of `spanSeconds` for a session's stored `stagesJSON`, or nil when coverage
    /// is not a meaningful question for that payload.
    ///
    /// nil for: a nil/blank/`"[]"` payload (no stages at all — that is the richness question, not this
    /// one), for the IMPORTED minute-dict shape `{light,deep,rem,awake}` and for Health Connect's
    /// `{stage,min}` array, neither of which carries timestamps to compare against a span, and for an
    /// array holding any non-object element (see the Kotlin twin's loop for why that bails rather than
    /// measuring the remainder).
    ///
    /// SCOPE, precisely. Timestamp-free shapes are what keep this gate off the WHOOP CSV, Apple and
    /// Health Connect imports — they are never judged incomplete, so their behaviour is unchanged. That
    /// is NOT a blanket exemption for imports, and it was originally written as one: the Xiaomi Band
    /// importer emits real `{start,end,stage}` segments, and takes its span from `bedtime`/`wake_up_time`
    /// fields that are independent of the `items` array it builds those segments from. A Xiaomi night
    /// whose items do not reach its own bed/wake bounds IS judged holed here. That is arguably the right
    /// answer — the night genuinely is only partly described — but it is a real behaviour change for
    /// that importer, unvalidated against a Xiaomi export, and it is pinned by test rather than left to
    /// be discovered.
    public static func fraction(stagesJSON: String?, spanSeconds: Double) -> Double? {
        fraction(coveredSeconds: coveredSeconds(stagesJSON: stagesJSON), spanSeconds: spanSeconds)
    }

    /// Seconds of `stagesJSON` accounted for by timestamped segments, or 0 when the payload carries no
    /// measurable ones.
    ///
    /// Zero, not nil, because this is a SUMMABLE quantity: a caller accumulating several fragments needs
    /// "this one contributed nothing" to add cleanly, and the "is coverage even a meaningful question"
    /// decision belongs to `fraction`, which turns a zero total back into nil. Callers that want the
    /// unknown/known distinction for a SINGLE session must therefore keep using `fraction`, not this.
    ///
    /// Returns 0 for every shape `fraction(stagesJSON:spanSeconds:)` documents as unmeasurable — a
    /// nil/blank/`"[]"` payload, the imported minute-dict `{light,deep,rem,awake}`, Health Connect's
    /// `{stage,min}` array, and an array holding any non-object element (the whole payload bails rather
    /// than measuring the remainder). Splitting it out is behaviour-preserving for that function: a 0
    /// total fails `fraction`'s `coveredSeconds > 0` guard and still yields nil.
    public static func coveredSeconds(stagesJSON: String?) -> Double {
        guard let json = stagesJSON?.trimmingCharacters(in: .whitespacesAndNewlines),
              !json.isEmpty, json != "[]",
              let data = json.data(using: .utf8),
              let segs = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
        else { return 0 }
        var covered = 0.0
        for seg in segs {
            guard let s = (seg["start"] as? NSNumber)?.doubleValue,
                  let e = (seg["end"] as? NSNumber)?.doubleValue, e > s else { continue }
            covered += e - s
        }
        return covered
    }

    /// Coverage summed across a bridged main-night GROUP — the quantity a night is actually judged on.
    ///
    /// A night is not one row. `AnalyticsEngine.analyzeDay` bridges the day's main-sleep fragments into a
    /// group (#561) and accumulates coverage over ALL of them before testing the gate, so a per-row answer
    /// is the wrong question for anything presenting a night: two fragments that are individually 90% and
    /// 99% covered are one night at neither figure. This exists so a UI can ask the same question the
    /// engine asked without restating the accumulation, which is where a twin rule would drift.
    ///
    /// PARITY WITH THE ENGINE, exactly. Every fragment contributes its full `[startTs, endTs)` to the
    /// denominator whether or not its payload is measurable, and contributes cover only from timestamped
    /// segments — which reproduces `analyzeDay`'s decoded-segment accumulation term for term, including
    /// the mixed-source case it calls out (a timestamp-free fragment adds span and no cover, so a group
    /// mixing one with a timestamped fragment reads as holed). A group whose fragments are ALL
    /// timestamp-free totals 0 covered seconds and comes back nil — unknown, not holed.
    /// The accumulation itself, over `(payload, span)` fragments. This is the shape the Kotlin twin
    /// implements — entity-free, because `HypnogramCoverage` sits in `com.noop.analytics` over there and
    /// must not reach into `com.noop.data` for a row type. The session overload below is a thin adapter,
    /// so both platforms run the identical arithmetic and only the packaging differs.
    public static func groupFraction(_ fragments: [(stagesJSON: String?, spanSeconds: Double)]) -> Double? {
        var covered = 0.0, span = 0.0
        for f in fragments {
            span += f.spanSeconds
            covered += coveredSeconds(stagesJSON: f.stagesJSON)
        }
        return fraction(coveredSeconds: covered, spanSeconds: span)
    }

    public static func groupFraction(_ sessions: [CachedSleepSession]) -> Double? {
        groupFraction(sessions.map { (stagesJSON: $0.stagesJSON,
                                      spanSeconds: Double($0.endTs - $0.startTs)) })
    }

    /// `isHoled` for a bridged main-night GROUP. Unknown coverage (nil) is NOT holed — same fail-open
    /// contract as every other guard here.
    public static func isHoledGroup(_ sessions: [CachedSleepSession]) -> Bool {
        guard let f = groupFraction(sessions) else { return false }
        return f < minCoverage
    }

    /// True when the timeline is known to cover less than `minCoverage` of its span — i.e. the session
    /// demonstrably describes only part of the night it claims. Unknown coverage (nil) is NOT holed:
    /// every guard built on this fails OPEN, so a payload shape this cannot measure keeps its existing
    /// behaviour instead of being silently downgraded.
    public static func isHoled(stagesJSON: String?, spanSeconds: Double) -> Bool {
        guard let f = fraction(stagesJSON: stagesJSON, spanSeconds: spanSeconds) else { return false }
        return f < minCoverage
    }

    /// `isHoled` for a stored session, using its own `[startTs, endTs)` as the span.
    public static func isHoled(_ s: CachedSleepSession) -> Bool {
        isHoled(stagesJSON: s.stagesJSON, spanSeconds: Double(s.endTs - s.startTs))
    }
}
