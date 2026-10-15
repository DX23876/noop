import Foundation

// RhythmAge.swift — the weekly daily-rhythm readout built on CosinorAge, for WHOOP 5.0 and MG.
//
// CosinorAge expects minute-level ENMO in milli-g, computed the UK Biobank way from a raw accelerometer. The
// strap stores its own per-second motion figure instead (`dynamic_acceleration@41`, `gravitySample.dynAccel`),
// whose on-chip definition is unknown: none of twelve candidate formulas reproduces it per second. Per MINUTE it
// tracks ENMO closely, so this file converts minute means of `@41` to ENMO through a monotone table fitted on a
// week of the strap's own 100 Hz IMU (Raw Data Collector, WHOOP MG, 2026-10-08…15, 9018 minutes;
// `Tools/cosinor_calib.py`). Held out on half the week the conversion is off by 4.9 mg per minute with no bias,
// worth at most 0.36 years at that wearer's rhythm and about 1.8 years for a much more active one.
//
// BETA: the table comes from one person. How someone moves decides how `@41` relates to ENMO, so the error for
// very active wearers is unverified and likely larger. Wellness information, not a clinical age.
public enum RhythmAge {

    // MARK: - @41 → ENMO conversion

    /// Isotonic (monotone non-decreasing) fit of minute-mean ENMO on minute-mean `@41`, both in mg, thinned to
    /// 32 knots. Linear between knots, held at the end values outside them.
    static let dyn41ToEnmoKnots: [(dyn41: Double, enmo: Double)] = [
        (5.5568, 0.6061), (7.2441, 0.7666), (7.6151, 0.9157), (8.6507, 1.1029), (9.2082, 1.2958),
        (10.0543, 1.4323), (10.8197, 1.5696), (12.0942, 1.8888), (13.276, 2.0617), (15.0849, 2.2816),
        (15.847, 2.5362), (17.5155, 2.9455), (19.9242, 3.4208), (23.3743, 4.2557), (27.2912, 5.2179),
        (29.6872, 5.886), (35.9109, 7.0823), (39.9092, 7.8121), (44.771, 8.9164), (54.3701, 10.2011),
        (59.3946, 12.0838), (65.1086, 13.8102), (78.0602, 17.4196), (98.0348, 31.21), (110.5267, 39.8782),
        (144.5483, 56.074), (167.0366, 63.3905), (219.5482, 76.0719), (297.1744, 95.9317),
        (384.3585, 111.9902), (448.2628, 123.345), (654.4341, 175.1409),
    ]

    /// A minute counts only with at least this many seconds of `@41`, as in the calibration.
    public static let minSecondsPerMinute = 50

    public static func enmo(fromDyn41Mg x: Double) -> Double {
        let k = dyn41ToEnmoKnots
        guard let first = k.first, let last = k.last else { return x }
        if x <= first.dyn41 { return first.enmo }
        if x >= last.dyn41 { return last.enmo }
        for (a, b) in zip(k, k.dropFirst()) where x <= b.dyn41 {
            return a.enmo + (b.enmo - a.enmo) * (x - a.dyn41) / (b.dyn41 - a.dyn41)
        }
        return last.enmo
    }

    /// Per-second `@41` (in g) → local-day minute series of converted ENMO in mg. A minute is the mean of its
    /// seconds, converted after averaging (the table was fitted on minute means), and left empty below
    /// `minSecondsPerMinute`. Days without a single usable minute are dropped.
    public static func daySeries(dyn41 samples: [CosinorAgeEngine.ActivitySample],
                                 tzOffsetSeconds: Int) -> [CosinorAgeEngine.DaySeries] {
        let raw = CosinorAgeEngine.dailyMinuteSeriesWithCounts(samples, tzOffsetSeconds: tzOffsetSeconds)
        return raw.compactMap { day in
            var minutes = [Double?](repeating: nil, count: CosinorAgeEngine.minutesPerDay)
            var valid = 0
            for m in 0..<CosinorAgeEngine.minutesPerDay {
                guard let mean = day.meansMg[m], day.counts[m] >= minSecondsPerMinute else { continue }
                minutes[m] = enmo(fromDyn41Mg: mean)
                valid += 1
            }
            return valid > 0 ? CosinorAgeEngine.DaySeries(minutes: minutes, validMinutes: valid) : nil
        }
    }

    // MARK: - Comparison with the published cohort

    /// Where a value sits against the CosinorAge development cohort: Shim, Fleisch & Barata 2024, Table 1,
    /// UK Biobank training set (n = 53 218, aged 40–69), median and interquartile range.
    public enum Level: String, Equatable, Sendable { case below, typical, above }

    /// The cohort's median and interquartile range of one cosinor parameter.
    public struct CohortRange: Equatable, Sendable {
        public let low: Double
        public let median: Double
        public let high: Double
    }

    /// MESOR 27.62 mg [23.02, 33.00].
    public static let mesorQuartiles = CohortRange(low: 23.02, median: 27.62, high: 33.00)
    /// Amplitude 23.53 mg [18.74, 29.43].
    public static let amplitudeQuartiles = CohortRange(low: 18.74, median: 23.53, high: 29.43)
    /// Acrophase 13:57 [13:15, 14:35], as clock hours.
    public static let peakQuartiles = CohortRange(low: 13.25, median: 13.0 + 57.0 / 60.0, high: 14.0 + 35.0 / 60.0)

    static func level(_ v: Double, _ q: CohortRange) -> Level {
        v < q.low ? .below : (v > q.high ? .above : .typical)
    }

    public static func movementLevel(mesorMg: Double) -> Level { level(mesorMg, mesorQuartiles) }
    public static func contrastLevel(amplitudeMg: Double) -> Level { level(amplitudeMg, amplitudeQuartiles) }
    /// `.below` = an earlier peak than most of the cohort, `.above` = a later one.
    public static func peakLevel(hour: Double) -> Level { level(hour, peakQuartiles) }

    // MARK: - Weekly outcome

    public struct Reading: Equatable, Sendable {
        public let result: CosinorAgeEngine.Result
        /// Clock hour of the fitted activity peak, 0..<24. The model's figure; on screen the wearer's real
        /// busiest hours (`busiestWindowStart`) say when they move most, which a single cosine can miss.
        public let peakHour: Double
        /// Converted activity per local clock hour over the window (`hourlyProfile`).
        public let hourly: [Double?]
        public var movement: Level { movementLevel(mesorMg: result.mesor) }
        public var contrast: Level { contrastLevel(amplitudeMg: result.amplitude) }
        public var peak: Level { peakLevel(hour: peakHour) }
    }

    public enum Outcome: Equatable, Sendable {
        /// No `@41` at all: a WHOOP 4.0, or nothing worn yet.
        case noData
        /// Not yet the study's bar (≥ 72 h of wear, no unobserved stretch of more than 2 clock hours).
        case collecting(hours: Double)
        case reading(Reading)
    }

    /// The fitted activity in mg at a clock hour, for a curve with this MESOR, amplitude and peak. The same
    /// single-component cosine the model fits; never below zero, which ENMO cannot be.
    public static func fittedActivity(hour: Double, mesor: Double, amplitude: Double, peakHour: Double) -> Double {
        max(0, mesor + amplitude * cos(2 * Double.pi * (hour - peakHour) / 24))
    }

    /// One readout for a window of per-second `@41`. A reading needs the engine's reportable coverage; anything
    /// short of it is `collecting`, so a forecast is never shown as a weekly value.
    public static func evaluate(dyn41 samples: [CosinorAgeEngine.ActivitySample], age: Double,
                                sex: CosinorAgeEngine.Sex, tzOffsetSeconds: Int) -> Outcome {
        let days = daySeries(dyn41: samples, tzOffsetSeconds: tzOffsetSeconds)
        guard !days.isEmpty else { return .noData }
        let coverage = CosinorAgeEngine.coverage(days)
        guard coverage.isReportable,
              let result = CosinorAgeEngine.compute(days: days, age: age, sex: sex),
              !result.provisional else {
            return .collecting(hours: coverage.observedHours)
        }
        let peak = (result.troughHour + 12).truncatingRemainder(dividingBy: 24)
        return .reading(Reading(result: result, peakHour: peak, hourly: hourlyProfile(days)))
    }

    // MARK: - Hour of day

    /// Mean converted activity per local clock hour over every minute of every day; nil for an hour no day
    /// observed. What the wearer's day actually looked like, hour by hour.
    public static func hourlyProfile(_ days: [CosinorAgeEngine.DaySeries]) -> [Double?] {
        var sum = [Double](repeating: 0, count: 24), count = [Int](repeating: 0, count: 24)
        for day in days {
            for (slot, value) in day.minutes.enumerated() {
                guard let value else { continue }
                sum[slot / 60] += value
                count[slot / 60] += 1
            }
        }
        return (0..<24).map { count[$0] > 0 ? sum[$0] / Double(count[$0]) : nil }
    }

    /// The study's typical day: the cohort's median MESOR, amplitude and acrophase through the model's own
    /// cosine, at the middle of each clock hour. A smooth curve, not the cohort's measured hourly averages.
    public static let typicalDay: [Double] = (0..<24).map {
        fittedActivity(hour: Double($0) + 0.5, mesor: mesorQuartiles.median,
                       amplitude: amplitudeQuartiles.median, peakHour: peakQuartiles.median)
    }

    public enum PartOfDay: String, CaseIterable, Sendable {
        case morning, afternoon, evening

        /// Local clock hours: 06–12, 12–18, 18–22.
        public var hours: Range<Int> {
            switch self {
            case .morning: return 6..<12
            case .afternoon: return 12..<18
            case .evening: return 18..<22
            }
        }
    }

    /// ASSUMPTION: a part of the day reads "less" below 60 % of the typical day's movement in the same hours and
    /// "more" above 140 %; between them it is "like most". Plain bands for wording, not from the study.
    static let partBands = (below: 0.6, above: 1.4)

    /// Each part of the day against the typical day over the same hours. A part with any unobserved hour has no
    /// level, so a charging gap never reads as sitting still.
    public static func partLevels(_ profile: [Double?]) -> [PartOfDay: Level] {
        var out: [PartOfDay: Level] = [:]
        for part in PartOfDay.allCases {
            let mine = part.hours.compactMap { profile.indices.contains($0) ? profile[$0] : nil }
            guard mine.count == part.hours.count else { continue }
            let typical = part.hours.map { typicalDay[$0] }.reduce(0, +)
            guard typical > 0 else { continue }
            let ratio = mine.reduce(0, +) / typical
            out[part] = ratio < partBands.below ? .below : (ratio > partBands.above ? .above : .typical)
        }
        return out
    }

    /// Start hour of the three consecutive waking hours (06 to 22) with the most movement; nil without a fully
    /// observed window. The earliest wins a tie.
    public static func busiestWindowStart(_ profile: [Double?], length: Int = 3) -> Int? {
        var best: (start: Int, total: Double)?
        for start in 6...(22 - length) {
            let values = (start..<start + length).compactMap { profile.indices.contains($0) ? profile[$0] : nil }
            guard values.count == length else { continue }
            let total = values.reduce(0, +)
            if best == nil || total > best!.total { best = (start, total) }
        }
        return best?.start
    }

    /// The profile's sex string to the model variant; anything else uses the sex-neutral weights.
    public static func sex(profileValue: String) -> CosinorAgeEngine.Sex {
        switch profileValue.lowercased() {
        case "male": return .male
        case "female": return .female
        default: return .unknown
        }
    }
}
