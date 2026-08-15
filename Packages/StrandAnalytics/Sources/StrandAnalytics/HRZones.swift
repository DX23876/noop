import Foundation
import WhoopProtocol

// HRZones.swift — HR-max + 5 heart-rate zones and time-in-zone from an HR stream.
//
// HR-max uses Tanaka et al. (2001): HRmax = 208 − 0.7 × age (gender-independent),
// with an optional manual override. The five zones are the conventional %HRmax
// bands used across consumer wearables:
//
//   Zone 1 (50–60% HRmax) — very light / recovery
//   Zone 2 (60–70% HRmax) — light / fat-burn
//   Zone 3 (70–80% HRmax) — moderate / aerobic
//   Zone 4 (80–90% HRmax) — hard / threshold
//   Zone 5 (90–100% HRmax) — maximum
//
// The band edges are user-overridable (`validatedEdges` / `HRZoneEdges`): a lactate test or a
// coach-set scheme puts the boundaries somewhere other than the round tens, and until now the only
// adjustable input was HRmax itself.
//
// NOTE: the Python source (strain.py) uses Karvonen %HRR zones (Edwards 5-zone,
// 50/60/70/80/90 %HRR) for TRIMP/strain. Those are reproduced faithfully in
// StrainScorer.swift. This file provides the simpler %HRmax zone model the task asks for (zones from
// age or a chosen HRmax, time-in-zone from [HRSample]); it is the "display" zone model and is
// independent of the HRR-based strain math.
//
// That independence is deliberate and load-bearing: CUSTOM BANDS MUST NOT REACH `StrainScorer`.
// Effort is a port of a published method whose own zone thresholds are part of the method, and it is
// compared against the user's own history — re-basing TRIMP on a band the user moved yesterday would
// silently rewrite every Effort they have ever seen. Custom bands change what is DISPLAYED as
// time-in-zone and what the coach prescribes; they never change what a day scored.

/// A single heart-rate zone defined as a bpm interval [lower, upper).
public struct HRZone: Equatable, Sendable {
    /// Zone number 1...5.
    public let number: Int
    /// Lower bound (bpm), inclusive.
    public let lower: Double
    /// Upper bound (bpm); exclusive except for the top zone where it is inclusive.
    public let upper: Double
    /// Fraction-of-HRmax lower bound (e.g. 0.50 for Zone 1).
    public let lowerPct: Double
    /// Fraction-of-HRmax upper bound (e.g. 0.60 for Zone 1).
    public let upperPct: Double

    public init(number: Int, lower: Double, upper: Double, lowerPct: Double, upperPct: Double) {
        self.number = number
        self.lower = lower
        self.upper = upper
        self.lowerPct = lowerPct
        self.upperPct = upperPct
    }
}

/// Five HR zones derived from a max HR, plus the max HR itself and its source.
public struct HRZoneSet: Equatable, Sendable {
    /// The five zones, z1...z5, in ascending order.
    public let zones: [HRZone]
    /// Max HR (bpm) the zones were built from.
    public let maxHR: Double
    /// "tanaka" (age formula), "manual" (caller HRmax override), or "custom" (user-edited bands).
    public let source: String

    public init(zones: [HRZone], maxHR: Double, source: String) {
        self.zones = zones
        self.maxHR = maxHR
        self.source = source
    }

    /// Tolerance (bpm) on a band boundary, so a bound lands in its own zone despite binary rounding.
    ///
    /// `lower = pct × maxHR` is not exact: 0.55 × 200 is 110.000000000000014, so a strict `bpm >= lower`
    /// put a reading of exactly 110 BELOW Zone 1. The default 50/60/70/80/90 set happens to divide
    /// cleanly on round maxHRs and never showed this, but a user-set band (#user-feedback) lands on it
    /// routinely. Applied to BOTH bounds so a reading on an internal edge moves up exactly one zone
    /// rather than being claimed by the band below it. 1e-9 bpm is ~5 orders of magnitude under the
    /// smallest real difference (samples are whole bpm) and ~5 above the error it absorbs.
    public static let edgeEpsilon: Double = 1e-9

    /// Return the zone number (1...5) for a bpm value, or 0 when below Zone 1.
    public func zoneNumber(forBPM bpm: Double) -> Int {
        let eps = HRZoneSet.edgeEpsilon
        for z in zones {
            // Top zone is inclusive at its upper edge so HRmax itself lands in z5.
            if z.number == 5 {
                if bpm >= z.lower - eps { return 5 }
            } else if bpm >= z.lower - eps && bpm < z.upper - eps {
                return z.number
            }
        }
        return 0
    }
}

/// Time spent in each zone (seconds), including below-Zone-1 time as `belowZone1`.
public struct TimeInZone: Equatable, Sendable {
    /// Seconds in each of the five zones, indexed z1...z5 (zone[0] == Zone 1).
    public let seconds: [Double]
    /// Seconds spent below Zone 1 (HR under 50% HRmax).
    public let belowZone1: Double

    public init(seconds: [Double], belowZone1: Double) {
        self.seconds = seconds
        self.belowZone1 = belowZone1
    }

    /// Total counted seconds (Zone 1...5 plus below-Zone-1).
    public var total: Double { seconds.reduce(0, +) + belowZone1 }

    /// Seconds in a specific zone (1...5); 0 for out-of-range zone numbers.
    public func seconds(inZone zone: Int) -> Double {
        guard zone >= 1 && zone <= 5 else { return 0 }
        return seconds[zone - 1]
    }
}

/// How a wearer wants their zone bands defined. Persisted per profile; resolved through
/// ``HRZones/zones(config:maxHR:autoSource:)``.
///
/// Three modes rather than one, because the two ways people know their zones are genuinely different
/// quantities and neither converts cleanly into the other over time:
///  - `.auto` — the conventional 50/60/70/80/90 % of HRmax. What everyone starts on.
///  - `.percent` — the wearer's own %HRmax bounds. They scale WITH HRmax, so a re-estimated maximum
///    moves the bands, which is what you want if you think in percentages.
///  - `.bpm` — absolute bounds. What a threshold or lactate test actually hands you. They stay PUT
///    when HRmax changes, which is what you want if you think in heart rates.
///
/// Both custom modes store five LOWER bounds; the top is HRmax either way (Zone 5 ends at the maximum
/// by definition), so there is one rule to explain rather than two.
public struct HRZoneConfig: Equatable, Sendable {

    public enum Mode: String, Sendable, CaseIterable {
        case auto, percent, bpm
    }

    public let mode: Mode
    /// Five lower bounds as FRACTIONS of HRmax. Meaningful only in `.percent`.
    public let percentLowerBounds: [Double]
    /// Five lower bounds in bpm. Meaningful only in `.bpm`.
    public let bpmLowerBounds: [Double]

    public init(mode: Mode = .auto,
                percentLowerBounds: [Double] = [],
                bpmLowerBounds: [Double] = []) {
        self.mode = mode
        self.percentLowerBounds = percentLowerBounds
        self.bpmLowerBounds = bpmLowerBounds
    }

    /// The conventional bands — what every profile starts on and what an invalid config degrades to.
    public static let auto = HRZoneConfig()

    /// Whether this config actually resolves to custom bands. False for `.auto` AND for a custom mode
    /// whose stored bounds no longer validate, so callers asking "has the user customised?" get the
    /// same answer the resolver acts on rather than a promise the zones don't keep.
    public func isCustom(maxHR: Double) -> Bool {
        switch mode {
        case .auto:    return false
        case .percent: return HRZones.validatedEdges(lowerPercents: percentLowerBounds) != nil
        case .bpm:     return HRZones.validatedBpmEdges(lowerBpm: bpmLowerBounds, maxHR: maxHR) != nil
        }
    }
}

public enum HRZones {

    /// %HRmax band edges for zones 1...5: [0.50, 0.60, 0.70, 0.80, 0.90, 1.00].
    public static let zoneEdges: [Double] = [0.50, 0.60, 0.70, 0.80, 0.90, 1.00]

    /// Tanaka (2001) age-predicted max HR: 208 − 0.7 × age (gender-independent).
    public static func tanakaMaxHR(age: Double) -> Double {
        208.0 - 0.7 * age
    }

    /// Build the 5-zone set from age (Tanaka) or a manual `maxHROverride`.
    ///
    /// - Parameters:
    ///   - age: age in years (used only when `maxHROverride` is nil).
    ///   - maxHROverride: explicit HRmax (bpm); when provided, `source == "manual"`.
    public static func zones(age: Double, maxHROverride: Double? = nil) -> HRZoneSet {
        let maxHR: Double
        let source: String
        if let override = maxHROverride {
            maxHR = override
            source = "manual"
        } else {
            maxHR = tanakaMaxHR(age: age)
            source = "tanaka"
        }
        return zones(maxHR: maxHR, source: source)
    }

    /// Build the 5-zone set directly from a known max HR, over `edges` (default: the conventional
    /// `zoneEdges`). `edges` must be the 6 band boundaries as fractions of HRmax, ascending — the shape
    /// `validatedEdges(lowerPercents:)` returns. An `edges` array of any other length falls back to the
    /// default, so a malformed stored value can never render four zones or crash a readout.
    public static func zones(maxHR: Double, edges: [Double] = zoneEdges,
                             source: String = "manual") -> HRZoneSet {
        let e = edges.count == 6 ? edges : zoneEdges
        var built: [HRZone] = []
        for i in 0..<5 {
            let loPct = e[i]
            let hiPct = e[i + 1]
            built.append(HRZone(
                number: i + 1,
                lower: loPct * maxHR,
                upper: hiPct * maxHR,
                lowerPct: loPct,
                upperPct: hiPct
            ))
        }
        return HRZoneSet(zones: built, maxHR: maxHR, source: source)
    }

    /// Build the 5-zone set from ABSOLUTE bpm bounds — the shape `validatedBpmEdges` returns (5 lower
    /// bounds plus HRmax on top). The `%HRmax` figures are then DERIVED for display; in this mode the
    /// bpm numbers are the truth and the percentages follow, which is the opposite of the percent mode
    /// and the whole reason the mode exists: a threshold or lactate test hands you bpm, and those bounds
    /// should not move when HRmax is re-estimated.
    public static func zones(bpmEdges: [Double], maxHR: Double,
                             source: String = "custom-bpm") -> HRZoneSet {
        guard bpmEdges.count == 6, maxHR > 0 else { return zones(maxHR: maxHR, source: source) }
        var built: [HRZone] = []
        for i in 0..<5 {
            built.append(HRZone(
                number: i + 1,
                lower: bpmEdges[i],
                upper: bpmEdges[i + 1],
                lowerPct: bpmEdges[i] / maxHR,
                upperPct: bpmEdges[i + 1] / maxHR
            ))
        }
        return HRZoneSet(zones: built, maxHR: maxHR, source: source)
    }

    /// Resolve a stored `HRZoneConfig` into the zone set to use. THE entry point for anything that owns
    /// a user configuration; `autoSource` is what `.auto` should call itself ("tanaka" when HRmax came
    /// from the age formula, "manual" when the user set HRmax by hand) — that distinction lives in the
    /// profile, not here.
    ///
    /// A config whose bounds no longer validate degrades to `.auto` rather than to a broken partition,
    /// so a hand-edited defaults plist or a truncated restore costs the user their customisation, never
    /// a screen full of nonsense zones.
    public static func zones(config: HRZoneConfig, maxHR: Double,
                             autoSource: String = "manual") -> HRZoneSet {
        switch config.mode {
        case .auto:
            return zones(maxHR: maxHR, source: autoSource)
        case .percent:
            guard let edges = validatedEdges(lowerPercents: config.percentLowerBounds) else {
                return zones(maxHR: maxHR, source: autoSource)
            }
            return zones(maxHR: maxHR, edges: edges, source: "custom-percent")
        case .bpm:
            guard let edges = validatedBpmEdges(lowerBpm: config.bpmLowerBounds, maxHR: maxHR) else {
                return zones(maxHR: maxHR, source: autoSource)
            }
            return zones(bpmEdges: edges, maxHR: maxHR)
        }
    }

    // MARK: - Custom bands (#user-feedback: "I'd like to change my HR zone bands")

    /// Lowest band boundary a user may set, as a fraction of HRmax. Below ~30 % HRmax the "zone" is
    /// resting heart rate, so a Zone 1 floor under this is a data-entry slip, not a training choice.
    public static let minEdge: Double = 0.30
    /// Smallest gap between two adjacent boundaries (1 percentage point). Bands that touch would make
    /// a zone zero-wide, which `zoneNumber(forBPM:)` could never return.
    public static let minEdgeGap: Double = 0.01

    /// Turn the five user-entered LOWER bounds (fractions of HRmax, ascending) into the 6-edge array
    /// `zones(maxHR:edges:)` takes, or nil when the set isn't a legal partition.
    ///
    /// The ONE place that decides what a legal band set is, so the editor's validation, the stored
    /// value's sanity check and the tests can't drift apart. The top edge is always 1.00 (HRmax) — Zone 5
    /// ends at your max by definition, so it isn't the user's to move.
    public static func validatedEdges(lowerPercents: [Double]) -> [Double]? {
        guard lowerPercents.count == 5 else { return nil }
        guard let first = lowerPercents.first, first >= minEdge else { return nil }
        // Strictly ascending with a real gap, and the top band must still leave room under HRmax.
        for i in 1..<5 where lowerPercents[i] < lowerPercents[i - 1] + minEdgeGap { return nil }
        guard lowerPercents[4] <= 1.0 - minEdgeGap else { return nil }
        return lowerPercents + [1.0]
    }

    /// The conventional five lower bounds expressed in whole bpm, for seeding a bpm editor.
    ///
    /// Rounds UP rather than to nearest, which is what keeps the seeded bands classifying integer
    /// samples exactly as the percentage bands did: a 93.4 bpm edge rounded DOWN to 93 pulls a 93 bpm
    /// reading up a zone, while 94 leaves it where the percentage model put it. (Upstream ryanbr/noop
    /// makes the same point in `defaultLowerBounds(maxHR:)`.)
    public static func defaultBpmLowerBounds(maxHR: Double) -> [Double] {
        zoneEdges.prefix(5).map { ($0 * maxHR).rounded(.up) }
    }

    /// True when `edges` is the conventional 50/60/70/80/90 set — i.e. the user has NOT customised.
    public static func isDefaultEdges(_ edges: [Double]) -> Bool {
        guard edges.count == zoneEdges.count else { return false }
        return zip(edges, zoneEdges).allSatisfy { abs($0 - $1) < 1e-9 }
    }

    /// Lowest ABSOLUTE band boundary a user may set (bpm). A Zone 1 floor under this is below almost
    /// anyone's resting heart rate, so it is a slip rather than a training choice.
    public static let minBpmEdge: Double = 40
    /// Smallest gap between two adjacent bpm boundaries. One beat is the resolution of the data itself;
    /// closer would make a zone no reading could land in.
    public static let minBpmGap: Double = 1

    /// Turn five ABSOLUTE lower bounds (bpm, ascending) into the 6-edge bpm array `zones(bpmEdges:maxHR:)`
    /// takes, or nil when the set isn't a legal partition. The top edge is HRmax — the same rule as the
    /// percent mode, so Zone 5 ends at the maximum in both.
    ///
    /// Requiring the top bound to sit below HRmax is what keeps the two settings honest with each other:
    /// bands entered above the stated maximum would leave Zone 5 empty and the maximum unreachable, and
    /// the fix is for the user to correct HRmax, not for the app to quietly stretch it.
    public static func validatedBpmEdges(lowerBpm: [Double], maxHR: Double) -> [Double]? {
        guard lowerBpm.count == 5, maxHR > 0 else { return nil }
        guard let first = lowerBpm.first, first >= minBpmEdge else { return nil }
        for i in 1..<5 where lowerBpm[i] < lowerBpm[i - 1] + minBpmGap { return nil }
        guard lowerBpm[4] <= maxHR - minBpmGap else { return nil }
        return lowerBpm + [maxHR]
    }

    /// Compute time-in-zone (seconds) from a time-ordered HR stream.
    ///
    /// Each sample is credited with the duration until the next sample (the
    /// "hold until next reading" convention). The final sample is credited with
    /// the median inter-sample interval (so a constant-rate stream is fully
    /// accounted for). Samples are sorted defensively by ts.
    ///
    /// - Parameters:
    ///   - hr: time-ordered (or unordered) `[HRSample]`.
    ///   - zoneSet: the zone definitions to bucket against.
    public static func timeInZone(_ hr: [HRSample], zoneSet: HRZoneSet) -> TimeInZone {
        let sorted = hr.sorted { $0.ts < $1.ts }
        var zoneSeconds = [Double](repeating: 0, count: 5)
        var below: Double = 0

        guard !sorted.isEmpty else {
            return TimeInZone(seconds: zoneSeconds, belowZone1: 0)
        }

        // Tail sample gets the median inter-sample gap so the series is fully counted.
        let tailDuration = medianInterval(sorted)

        for i in 0..<sorted.count {
            let dur: Double
            if i < sorted.count - 1 {
                let gap = Double(sorted[i + 1].ts - sorted[i].ts)
                // Guard against zero/negative or pathological gaps; cap at the median
                // so a single huge wall-clock gap doesn't blow up one bucket.
                dur = (gap > 0) ? min(gap, tailDuration) : tailDuration
            } else {
                dur = tailDuration
            }
            let z = zoneSet.zoneNumber(forBPM: Double(sorted[i].bpm))
            if z >= 1 {
                zoneSeconds[z - 1] += dur
            } else {
                below += dur
            }
        }
        return TimeInZone(seconds: zoneSeconds, belowZone1: below)
    }

    /// Median spacing between consecutive timestamps, restricted to plausible
    /// (0, 300 s] gaps. Falls back to 1.0 s when no plausible gap exists.
    static func medianInterval(_ sorted: [HRSample]) -> Double {
        guard sorted.count >= 2 else { return 1.0 }
        var gaps: [Double] = []
        for i in 1..<sorted.count {
            let g = Double(sorted[i].ts - sorted[i - 1].ts)
            if g > 0 && g < 300 { gaps.append(g) }
        }
        guard !gaps.isEmpty else { return 1.0 }
        gaps.sort()
        return max(gaps[gaps.count / 2], 1.0)
    }
}

/// Serialisation for custom zone bands: five lower bounds in one compact string — percents in the
/// percent mode (`"55,65,75,85,92"`), bpm in the bpm mode (`"110,130,150,170,184"`).
///
/// Deliberately hand-rolled rather than `NumberFormatter`/`JSONEncoder`: this string rides the
/// `.noopbak` settings whitelist as a plain String, and a backup written on a German device must
/// restore on an English one. A locale-aware formatter would write `"62,5"` for sixty-two-and-a-half
/// and the comma-separated list would silently gain a field. `String(format:)` (no locale argument)
/// and `Double(_:)` are both POSIX, so the wire form is identical everywhere.
public enum HRZoneEdges {

    /// Encode the LOWER bounds of `edges` (the first five of six) as percents. Returns "" for the
    /// default set, so "not customised" is stored as absence rather than as a value to keep in sync.
    public static func encode(_ edges: [Double]) -> String {
        guard edges.count == 6, !HRZones.isDefaultEdges(edges) else { return "" }
        return encodeValues(edges.prefix(5).map { $0 * 100.0 })
    }

    /// Encode five raw values (bpm, or already-scaled percents) as the same comma-separated form.
    /// Returns "" for an empty list so "unset" round-trips as absence in both modes.
    public static func encodeValues<S: Sequence>(_ values: S) -> String where S.Element == Double {
        let list = Array(values)
        guard !list.isEmpty else { return "" }
        return list.map(trimmed).joined(separator: ",")
    }

    /// Decode five raw values, or nil when the string isn't five numbers. Unlike ``decode(_:)`` this
    /// applies NO band validation — the bpm mode can only be validated against the profile's HRmax,
    /// which this type deliberately knows nothing about. The caller runs
    /// `HRZones.validatedBpmEdges(lowerBpm:maxHR:)`.
    public static func decodeValues(_ raw: String) -> [Double]? {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return nil }
        var out: [Double] = []
        for p in parts {
            guard let v = Double(p.trimmingCharacters(in: .whitespaces)) else { return nil }
            out.append(v)
        }
        return out
    }

    /// Decode a stored string back into the 6-edge array, or nil when it is empty, malformed, or
    /// describes an illegal partition. A nil result means "use the default bands" at every call site —
    /// never a crash and never a half-applied custom set.
    public static func decode(_ raw: String) -> [Double]? {
        guard let values = decodeValues(raw) else { return nil }
        return HRZones.validatedEdges(lowerPercents: values.map { $0 / 100.0 })
    }

    /// One value as the shortest exact text: "60" not "60.0", but "62.5" keeps its half.
    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if abs(rounded - rounded.rounded()) < 1e-9 {
            return String(format: "%.0f", rounded.rounded())
        }
        return String(format: "%.1f", rounded)
    }
}
