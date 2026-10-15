import Foundation

// CosinorAgeEngine.swift — the "CosinorAge" circadian biological-age biomarker. Pure, deterministic,
// DB-free.
//
// INDEPENDENT reimplementation of the published CosinorAge method (Shim, Fleisch & Barata,
// npj Digital Medicine 2024 — https://www.nature.com/articles/s41746-024-01111-x). The regression
// weights and the Gompertz proportional-hazards mapping are the published OPEN WEIGHTS from the
// Apache-2.0 reference package ADAMMA-CDHI-ETH-Zurich/CosinorAge (`bioages/cosinorage.py`,
// `features/utils/cosinor_analysis.py`); this file is a clean-room Swift port of the maths, not the code.
//
// Pipeline: minute-level activity (a gravity-removed acceleration magnitude, in mg) → a single-component
// cosinor fit on the FULL 1,440-minute-per-day series (τ = 1440 min; NOT folded to 24 hourly means) →
// MESOR / amplitude / acrophase → a sex-specific Gompertz model → a "biological age" in years.
//
// WELLNESS ESTIMATE — NOT a medical device and NOT a clinical/diagnostic age. It is presented with a
// ±band and gated on data coverage; on thin or arrhythmic data it returns nil rather than guessing. The
// weights are calibrated to a per-minute accelerometer activity metric in the milli-g range, so the
// input MUST be a real accelerometer activity signal (e.g. the strap's `dynamic_acceleration`), never a
// heart-rate / step / movement-volume proxy on a different scale.
public enum CosinorAgeEngine {

    public enum Sex: String, Equatable, Sendable, Codable { case male, female, unknown }

    // MARK: - Published model weights (verbatim)

    struct Coeffs: Equatable { let mesor, amp1, phi1, age, rate: Double }
    static let coeffGeneric = Coeffs(mesor: -0.03204933, amp1: -0.01971357, phi1: -0.01664718,
                                     age: 0.10033692, rate: -13.36715309)
    static let coeffFemale  = Coeffs(mesor: -0.02569062, amp1: -0.02170987, phi1: -0.13191562,
                                     age: 0.08840283, rate: -13.28530410)
    static let coeffMale    = Coeffs(mesor: -0.023988922, amp1: -0.030620390, phi1: 0.008960155,
                                     age: 0.101726103, rate: -13.016951633)
    // Shared scalars of the Gompertz mapping (sex-independent in the reference).
    static let mN = -1.405276, mD = 0.01462774
    static let baN = -0.01447851, baD = 0.112165, baI = 133.5989

    static func coeffs(for sex: Sex) -> Coeffs {
        switch sex {
        case .female: return coeffFemale
        case .male: return coeffMale
        case .unknown: return coeffGeneric
        }
    }

    // MARK: - Coverage / rhythm gates (pinned by test)

    public static let minutesPerDay = 1440
    /// A day needs at least this many non-missing minutes to count (≈ 2/3 of the day worn).
    public static let minValidMinutesPerDay = 960
    /// Minimum whole qualifying days before a fit is reported (aligned with CircadianEngine.minDaysForFit).
    public static let minQualifyingDays = 7
    /// A fit whose amplitude is below this fraction of the MESOR is too flat to phase (arrhythmic).
    public static let minRelativeAmplitude = 0.10
    /// The ±band shown alongside the biological age (years), at FULL coverage (`minQualifyingDays`).
    public static let bandYears = 5.0

    // MARK: - Provisional ("forecast") gates — the relaxed path only, never `compute`

    /// Fewest whole days `computeProvisional` will fit at all (default: a single day).
    public static let minProvisionalDays = 1
    /// There is deliberately NO per-day minute floor on the provisional path. Measured against a clean
    /// 5-full-day reference, folding in daytime-only partial days costs at most ~0.3 years (1 h: −0.05,
    /// 4 h: −0.03, 8 h: +0.28, 10 h: +0.30), so a day threshold buys no bias control — it only discards
    /// information. Bias is controlled at the WINDOW level by the circadian-coverage gates below, which
    /// are what actually catch the pathological case (every day worn daytime-only).
    public static let minProvisionalMinutesPerDay = 0

    // MARK: - Circadian coverage gates (window-level; adapted from the study protocol)

    /// Total wear hours before an estimate counts as reportable rather than a forecast. The published
    /// study excluded participants with "<72 h of wear time" over its 7 × 24-hour protocol; this is that
    /// threshold verbatim. Note it gates the WINDOW, not the individual day — a night worn across
    /// midnight must not be punished for landing in two calendar days.
    public static let minWearHoursForReport = 72.0
    /// Pooled minutes a given clock-hour bin needs across the window before it counts as observed.
    public static let minMinutesPerHourBin = 30
    /// Longest run of consecutive UNOBSERVED clock hours tolerated in the 24-hour cycle. The study's own
    /// rule ("no wear data in each 1 h period of the 24-hour cycle" → exclude) is stricter than the data
    /// warrants for a strap that has to be charged: measured error against a fully-worn reference is
    /// −0.24 y for a fixed 1 h gap and −0.43 y for 2 h, but −0.93 y at 3 h and +3.17 y once the whole
    /// 8 h night is missing. The knee is at 3, so 2 is the tolerance.
    public static let maxBlindSpotHours = 2

    // MARK: - Inputs

    /// One per-second activity sample: `g` is a gravity-removed acceleration magnitude, in g
    /// (e.g. the strap's `dynamic_acceleration`). Scaled ×1000 to mg internally.
    public struct ActivitySample: Equatable, Sendable {
        public let ts: Int      // wall-clock unix seconds
        public let g: Double
        public init(ts: Int, g: Double) { self.ts = ts; self.g = g }
    }

    /// A full local-civil-day minute vector of mean activity in mg (`nil` = a minute with no samples).
    public struct DaySeries: Equatable, Sendable {
        public let minutes: [Double?]   // count == minutesPerDay
        public let validMinutes: Int
        public init(minutes: [Double?], validMinutes: Int) {
            self.minutes = minutes; self.validMinutes = validMinutes
        }
    }

    /// How the observed minutes are spread across the 24-hour CLOCK — the thing that decides whether a
    /// CosinorAge estimate is trustworthy, and which raw wear time alone cannot express.
    ///
    /// Fitting a 24-hour cosine to data that only ever covers the waking half of the day cuts out the
    /// rhythm's trough: the MESOR rises, the amplitude collapses, and the Gompertz mapping reads the
    /// result as OLDER. Simulated over 7 days of identical behaviour, wearing 07:00–23:00 instead of
    /// round the clock moves MESOR 37 → 51 mg, amplitude 32 → 10 mg and the age 39.8 → 43.0 years. The
    /// relative-amplitude gate cannot catch it (10/51 = 0.19, comfortably above `minRelativeAmplitude`),
    /// which is exactly why coverage has to be measured separately and reported.
    public struct Coverage: Equatable, Sendable {
        /// Observed (non-missing) minutes across every day in the window.
        public let observedMinutes: Int
        /// Days the window spans, whether or not they carried data.
        public let spanDays: Int
        /// Pooled observed minutes per clock hour, index 0…23 in LOCAL time.
        public let hourBinMinutes: [Int]
        /// Longest run of consecutive under-observed clock hours, measured CYCLICALLY so a night gap
        /// spanning 23:00→06:00 reads as one run of 8 and not two of 1 and 7.
        public let largestBlindSpotHours: Int
        /// Clock hour the largest blind spot starts at; nil when there is none. Lets a caller say WHERE
        /// the hole is — and, against the fitted trough, which DIRECTION the estimate is skewed.
        public let blindSpotStartHour: Int?

        public init(observedMinutes: Int, spanDays: Int, hourBinMinutes: [Int],
                    largestBlindSpotHours: Int, blindSpotStartHour: Int?) {
            self.observedMinutes = observedMinutes; self.spanDays = spanDays
            self.hourBinMinutes = hourBinMinutes
            self.largestBlindSpotHours = largestBlindSpotHours
            self.blindSpotStartHour = blindSpotStartHour
        }

        public var observedHours: Double { Double(observedMinutes) / 60.0 }
        /// Observed minutes as a fraction of the window's wall-clock length.
        public var coveredFraction: Double {
            spanDays > 0 ? Double(observedMinutes) / Double(spanDays * minutesPerDay) : 0
        }
        /// The study's ≥72 h wear-time criterion.
        public var meetsWearTime: Bool { observedHours >= minWearHoursForReport }
        /// The adapted "data in every part of the 24-hour cycle" criterion. Subsumes the per-bin rule:
        /// one isolated thin hour is a run of 1 and passes, a missing night is a run of 8 and does not.
        public var meetsCircadianCoverage: Bool { largestBlindSpotHours <= maxBlindSpotHours }
        /// Both criteria — the bar for a REPORTABLE estimate rather than a labelled forecast.
        public var isReportable: Bool { meetsWearTime && meetsCircadianCoverage }
    }

    /// A single-component cosinor: y ≈ mesor + amplitude·cos(2π·t/1440 + acrophaseRadians).
    public struct CosinorFit: Equatable, Sendable {
        public let mesor: Double            // mg
        public let amplitude: Double        // mg (≥ 0)
        public let acrophaseRadians: Double // fit phase φ in radians, in (−2π, 0]
        public init(mesor: Double, amplitude: Double, acrophaseRadians: Double) {
            self.mesor = mesor; self.amplitude = amplitude; self.acrophaseRadians = acrophaseRadians
        }
    }

    public struct Result: Equatable, Sendable {
        public let cosinorAge: Double       // years
        public let advance: Double          // cosinorAge − chronoAge (+ = older than your age)
        public let chronoAge: Double
        public let mesor: Double            // mg
        public let amplitude: Double        // mg
        public let acrophaseRadians: Double
        public let bandYears: Double
        public let daysUsed: Int
        public let minutesUsed: Int
        /// How the observed minutes sit across the 24-hour clock — see `Coverage`.
        public let coverage: Coverage
        /// Spread of the estimate under leave-one-day-out refitting, in years; nil below three days.
        /// This is the uncertainty implied by the user's OWN gaps, with no distributional assumption.
        public let jackknifeSDYears: Double?
        /// True when the window fails the circadian-coverage bar — a forecast, not the reportable
        /// estimate. `bandYears` is widened accordingly. Callers MUST label it, and should name the
        /// reason: too few wear hours reads differently from a missing night.
        public let provisional: Bool
        public init(cosinorAge: Double, advance: Double, chronoAge: Double, mesor: Double,
                    amplitude: Double, acrophaseRadians: Double, bandYears: Double,
                    daysUsed: Int, minutesUsed: Int, coverage: Coverage,
                    jackknifeSDYears: Double? = nil, provisional: Bool = false) {
            self.cosinorAge = cosinorAge; self.advance = advance; self.chronoAge = chronoAge
            self.mesor = mesor; self.amplitude = amplitude; self.acrophaseRadians = acrophaseRadians
            self.bandYears = bandYears; self.daysUsed = daysUsed; self.minutesUsed = minutesUsed
            self.coverage = coverage; self.jackknifeSDYears = jackknifeSDYears
            self.provisional = provisional
        }

        /// The clock hour the fitted rhythm bottoms out — the acrophase half a cycle on. A blind spot
        /// sitting over THIS is the case that reads too old.
        public var troughHour: Double {
            // acrophaseRadians is the cosine phase offset φ in (−2π, 0]: peak at t where ωt + φ = 0.
            let peak = (-acrophaseRadians / (2 * Double.pi)) * 24.0
            return (peak + 12.0).truncatingRemainder(dividingBy: 24.0)
        }

        /// Does the largest blind spot sit over the rhythm's trough? That is the specific failure the
        /// coverage gate exists for — an unobserved trough inflates the MESOR, collapses the amplitude
        /// and makes the estimate read OLDER than it should. Lets a caller state the DIRECTION of the
        /// error instead of only its size.
        public var blindSpotCoversTrough: Bool {
            guard let start = coverage.blindSpotStartHour,
                  coverage.largestBlindSpotHours > maxBlindSpotHours else { return false }
            // Cyclic containment: is troughHour inside [start, start + length)?
            let offset = (troughHour - Double(start)).truncatingRemainder(dividingBy: 24.0)
            let normalised = offset < 0 ? offset + 24.0 : offset
            return normalised < Double(coverage.largestBlindSpotHours)
        }
    }

    // MARK: - Minute-level activity series

    /// Bucket per-second samples into full 1,440-slot per-local-civil-day minute vectors of mean
    /// activity in **mg**. Empty minutes are `nil`; days below `minValidMinutes` are dropped.
    /// Days are returned in chronological order.
    ///
    /// `minValidMinutes` defaults to the strict `minValidMinutesPerDay`, so every existing caller is
    /// unchanged; only `computeProvisional` passes the relaxed threshold.
    public static func dailyMinuteSeries(_ samples: [ActivitySample],
                                         tzOffsetSeconds: Int,
                                         minValidMinutes: Int = minValidMinutesPerDay) -> [DaySeries] {
        dailyMinuteSeriesWithCounts(samples, tzOffsetSeconds: tzOffsetSeconds).compactMap { day in
            let valid = day.counts.filter { $0 > 0 }.count
            guard valid >= minValidMinutes else { return nil }
            return DaySeries(minutes: day.meansMg, validMinutes: valid)
        }
    }

    /// One local day of minute means in mg with the number of seconds behind each (0 = empty minute).
    public struct MinuteBuckets: Equatable, Sendable {
        public let meansMg: [Double?]   // count == minutesPerDay
        public let counts: [Int]        // count == minutesPerDay
    }

    /// The bucketing behind `dailyMinuteSeries`, with per-minute sample counts kept so a caller can apply its
    /// own minute-level rule. Days in chronological order, none dropped.
    public static func dailyMinuteSeriesWithCounts(_ samples: [ActivitySample],
                                                   tzOffsetSeconds: Int) -> [MinuteBuckets] {
        guard !samples.isEmpty else { return [] }
        struct Acc { var sum = [Double](repeating: 0, count: 1440); var cnt = [Int](repeating: 0, count: 1440) }
        var byDay: [Int: Acc] = [:]
        for s in samples {
            let local = s.ts + tzOffsetSeconds
            let dayNum = Int((Double(local) / 86400.0).rounded(.down))
            let secOfDay = local - dayNum * 86400
            let minute = min(minutesPerDay - 1, max(0, secOfDay / 60))
            var acc = byDay[dayNum] ?? Acc()
            acc.sum[minute] += s.g * 1000.0     // g → mg
            acc.cnt[minute] += 1
            byDay[dayNum] = acc
        }
        return byDay.keys.sorted().map { dayNum in
            let acc = byDay[dayNum]!
            let means: [Double?] = (0..<minutesPerDay).map { acc.cnt[$0] > 0 ? acc.sum[$0] / Double(acc.cnt[$0]) : nil }
            return MinuteBuckets(meansMg: means, counts: acc.cnt)
        }
    }

    // MARK: - Coverage

    /// Measure how the observed minutes are spread across the 24-hour clock. The slot index within a
    /// `DaySeries` IS the minute of the local day, so the hour histogram is a straight tally.
    public static func coverage(_ days: [DaySeries]) -> Coverage {
        var bins = [Int](repeating: 0, count: 24)
        var observed = 0
        for day in days {
            for slot in 0..<minutesPerDay where day.minutes[slot] != nil {
                bins[slot / 60] += 1
                observed += 1
            }
        }
        let (run, start) = largestBlindSpot(bins)
        return Coverage(observedMinutes: observed, spanDays: days.count, hourBinMinutes: bins,
                        largestBlindSpotHours: run, blindSpotStartHour: start)
    }

    /// Longest CYCLIC run of under-observed hour bins, with the hour it starts at. Wrapping matters: a
    /// night gap runs 23 → 06 and must read as one run of 8, not 1 + 7.
    static func largestBlindSpot(_ bins: [Int]) -> (hours: Int, startHour: Int?) {
        let thin = bins.map { $0 < minMinutesPerHourBin }
        if thin.allSatisfy({ $0 }) { return (24, 0) }        // nothing observed anywhere
        if thin.allSatisfy({ !$0 }) { return (0, nil) }      // every hour observed
        var best = 0, bestStart: Int? = nil
        // Walk twice around the clock so a wrapping run is seen whole; a run can't exceed 24 because at
        // least one bin is observed (both degenerate cases returned above).
        var i = 0
        while i < 48 {
            guard thin[i % 24] else { i += 1; continue }
            let start = i
            var len = 0
            while len < 24 && thin[(start + len) % 24] { len += 1 }
            if len > best { best = len; bestStart = start % 24 }
            i = start + len
        }
        return (best, bestStart)
    }

    // MARK: - Minute-axis cosinor

    /// Single-component cosinor over the concatenated qualifying whole days, fit on the running minute
    /// index t = 1…N by ordinary least squares (the reference `cosinor_multiday`, τ = 1440 min). Missing
    /// minutes advance t but are excluded from the sums.
    ///
    /// Model y = M + β·cos(ωt) + γ·sin(ωt), ω = 2π/1440. Since A·cos(ωt + φ) = (A cosφ)·cos − (A sinφ)·sin,
    /// we recover amplitude = √(β²+γ²) and the phase φ = atan2(−γ, β), then shift φ into (−2π, 0] to match
    /// the reference `phi1` convention (this is the cosine phase OFFSET, not a peak clock time).
    public static func cosinorMinuteLevel(_ days: [DaySeries]) -> CosinorFit? {
        guard !days.isEmpty else { return nil }
        let w = 2.0 * Double.pi / Double(minutesPerDay)
        var sumY = 0.0, sumC = 0.0, sumS = 0.0
        var sumCC = 0.0, sumSS = 0.0, sumCS = 0.0
        var sumYC = 0.0, sumYS = 0.0
        var n = 0.0
        var t = 0                               // running minute index; reference uses 1…N
        for day in days {
            for slot in 0..<minutesPerDay {
                t += 1
                guard let y = day.minutes[slot] else { continue }
                let c = cos(w * Double(t))
                let s = sin(w * Double(t))
                sumY += y; sumC += c; sumS += s
                sumCC += c * c; sumSS += s * s; sumCS += c * s
                sumYC += y * c; sumYS += y * s
                n += 1
            }
        }
        guard n >= 3 else { return nil }

        // Solve the 3×3 normal equations for (M, β, γ) via Cramer's rule.
        let a11 = n,    a12 = sumC,  a13 = sumS
        let a21 = sumC, a22 = sumCC, a23 = sumCS
        let a31 = sumS, a32 = sumCS, a33 = sumSS
        let det = a11 * (a22 * a33 - a23 * a32)
                - a12 * (a21 * a33 - a23 * a31)
                + a13 * (a21 * a32 - a22 * a31)
        guard abs(det) > 1e-12 else { return nil }

        let detM = sumY * (a22 * a33 - a23 * a32)
                 - a12  * (sumYC * a33 - a23 * sumYS)
                 + a13  * (sumYC * a32 - a22 * sumYS)
        let detB = a11 * (sumYC * a33 - a23 * sumYS)
                 - sumY * (a21 * a33 - a23 * a31)
                 + a13  * (a21 * sumYS - sumYC * a31)
        let detG = a11 * (a22 * sumYS - sumYC * a32)
                 - a12 * (a21 * sumYS - sumYC * a31)
                 + sumY * (a21 * a32 - a22 * a31)

        let m = detM / det
        let beta = detB / det
        let gamma = detG / det

        let amplitude = (beta * beta + gamma * gamma).squareRoot()
        var phi = atan2(-gamma, beta)           // cosine phase offset, in (−π, π]
        if phi > 0 { phi -= 2.0 * Double.pi }    // → (−2π, 0], matching the reference shift
        return CosinorFit(mesor: m, amplitude: amplitude, acrophaseRadians: phi)
    }

    // MARK: - Gompertz biological age

    /// The CosinorAge Gompertz proportional-hazards mapping (verbatim from `bioages/cosinorage.py`).
    /// `acrophaseRadians` is the cosinor phase offset φ (radians, the reference `phi1`).
    public static func biologicalAge(mesor: Double, amplitude: Double, acrophaseRadians: Double,
                                     age: Double, sex: Sex) -> Double {
        let c = coeffs(for: sex)
        let xb = mesor * c.mesor + amplitude * c.amp1 + acrophaseRadians * c.phi1 + age * c.age + c.rate
        let mVal = 1.0 - exp((mN * exp(xb)) / mD)
        return (log(baN * log(1.0 - mVal)) / baD) + baI
    }

    // MARK: - End-to-end

    /// Compute CosinorAge from per-second activity samples. Returns nil unless there are at least
    /// `minQualifyingDays` whole days with adequate coverage AND the rhythm is readable (amplitude vs
    /// MESOR above `minRelativeAmplitude`) AND the result is finite.
    ///
    /// This is the REPORTABLE entry point and the faithful port of the published gating. Do not relax it —
    /// `computeProvisional` exists for the early/forecast case and marks its output.
    ///
    /// Note it can still come back `provisional`: passing the day count says nothing about WHERE in the
    /// 24-hour cycle those minutes fell, and seven daytime-only days are a forecast whichever entry point
    /// produced them.
    public static func compute(activity: [ActivitySample], age: Double, sex: Sex,
                               tzOffsetSeconds: Int) -> Result? {
        guard age > 0 else { return nil }
        let days = dailyMinuteSeries(activity, tzOffsetSeconds: tzOffsetSeconds)
        guard days.count >= minQualifyingDays else { return nil }
        return score(days: days, age: age, sex: sex)
    }

    /// The EARLY / forecast variant: the identical cosinor + Gompertz maths, but it will fit as little as
    /// `minDays` day(s) and applies no per-day minute floor, so an estimate exists from the first hours of
    /// wear. Whether the outcome is a forecast is decided by COVERAGE, not by the day count — at full
    /// coverage it returns exactly what `compute` returns, same code path and same band.
    ///
    /// A thin fit is heavily under-determined and the estimate can move by many years as days accumulate.
    /// It is a directional forecast for the experimental surface, never a reportable biological age, and it
    /// must never feed a downstream gate.
    public static func computeProvisional(activity: [ActivitySample], age: Double, sex: Sex,
                                          tzOffsetSeconds: Int,
                                          minDays: Int = minProvisionalDays,
                                          minMinutesPerDay: Int = minProvisionalMinutesPerDay) -> Result? {
        guard age > 0 else { return nil }
        let days = dailyMinuteSeries(activity, tzOffsetSeconds: tzOffsetSeconds,
                                     minValidMinutes: minMinutesPerDay)
        guard days.count >= max(1, minDays) else { return nil }
        return score(days: days, age: age, sex: sex)
    }

    /// Score day series a caller has already built, e.g. from a converted signal (`RhythmAge`). The same
    /// core as both entry points above, with no day-count gate of its own: coverage still decides
    /// `provisional`.
    public static func compute(days: [DaySeries], age: Double, sex: Sex) -> Result? {
        guard age > 0, !days.isEmpty else { return nil }
        return score(days: days, age: age, sex: sex)
    }

    /// Shared scoring core for BOTH entry points, so the strict and provisional paths can never drift:
    /// fit → rhythm gate → Gompertz → plausibility → coverage + uncertainty. `provisional` is DERIVED
    /// from coverage rather than passed in, so "is this a forecast?" has exactly one definition.
    private static func score(days: [DaySeries], age: Double, sex: Sex) -> Result? {
        guard let fit = cosinorMinuteLevel(days) else { return nil }
        // The rhythm gate stays in force on BOTH paths: it asks whether there is a day-night rhythm at
        // all, not how much data there is. A flat trace yields no age on either path.
        guard fit.mesor > 0, fit.amplitude / abs(fit.mesor) >= minRelativeAmplitude else { return nil }
        let ba = biologicalAge(mesor: fit.mesor, amplitude: fit.amplitude,
                               acrophaseRadians: fit.acrophaseRadians, age: age, sex: sex)
        // Finite AND physiologically possible. With the per-day floor gone, a sliver of data can fit a
        // wildly extrapolated cosine; a "biological age" outside human range is a fit artefact, not a
        // wide estimate, so it is withheld rather than shown with a big band.
        guard ba.isFinite, ba > 0, ba < 120 else { return nil }
        let cov = coverage(days)
        let sd = jackknifeSD(days: days, age: age, sex: sex)
        let minutesUsed = days.reduce(0) { $0 + $1.validMinutes }
        return Result(cosinorAge: ba, advance: ba - age, chronoAge: age,
                      mesor: fit.mesor, amplitude: fit.amplitude, acrophaseRadians: fit.acrophaseRadians,
                      bandYears: band(observedHours: cov.observedHours, jackknifeSD: sd),
                      daysUsed: days.count, minutesUsed: minutesUsed, coverage: cov,
                      jackknifeSDYears: sd, provisional: !cov.isReportable)
    }

    /// The ±band on the estimate. Prefer the MEASURED spread — twice the leave-one-day-out standard
    /// deviation — because it reflects the user's actual gaps rather than a formula. Without enough days
    /// for that, fall back to scaling `bandYears` by √(72 h / observed hours): the standard-error scaling
    /// of a mean, expressed in the study's own wear-time unit rather than in whole calendar days, so
    /// half an hour of data reads as the ±60 years it deserves instead of a tidy ±13. Never NARROWER
    /// than `bandYears`, however much data piles up.
    public static func band(observedHours: Double, jackknifeSD: Double?) -> Double {
        if let sd = jackknifeSD { return max(bandYears, 2 * sd) }
        guard observedHours > 0 else { return bandYears }
        return max(bandYears, bandYears * (minWearHoursForReport / observedHours).squareRoot())
    }

    /// Leave-one-day-out spread of the biological age, in years — the estimate's sensitivity to any one
    /// day of the user's real data. nil below three days, where a "spread" over one or two refits says
    /// nothing.
    ///
    /// Dropping a WHOLE day is safe here: each day is exactly one 1,440-minute period, so removing it
    /// shifts every later day's running index by exactly 2π and leaves the cosine basis — and therefore
    /// the phase — untouched.
    public static func jackknifeSD(days: [DaySeries], age: Double, sex: Sex) -> Double? {
        guard days.count >= 3 else { return nil }
        var ages: [Double] = []
        for skip in days.indices {
            var subset = days
            subset.remove(at: skip)
            guard let fit = cosinorMinuteLevel(subset), fit.mesor > 0,
                  fit.amplitude / abs(fit.mesor) >= minRelativeAmplitude else { continue }
            let ba = biologicalAge(mesor: fit.mesor, amplitude: fit.amplitude,
                                   acrophaseRadians: fit.acrophaseRadians, age: age, sex: sex)
            if ba.isFinite, ba > 0, ba < 120 { ages.append(ba) }
        }
        guard ages.count >= 3 else { return nil }
        let mean = ages.reduce(0, +) / Double(ages.count)
        let variance = ages.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(ages.count - 1)
        return variance.squareRoot()
    }

    // MARK: - Display only (NOT the model input)

    /// Fold the qualifying days to 24 per-clock-hour mean-activity bins, for the card's curve ONLY.
    /// This is deliberately separate from the model, which fits the full minute-level series.
    public static func hourlyChartBins(_ days: [DaySeries]) -> [CircadianEngine.ActivityBin] {
        guard !days.isEmpty else { return [] }
        var sum = [Double](repeating: 0, count: 24)
        var cnt = [Int](repeating: 0, count: 24)
        for day in days {
            for slot in 0..<minutesPerDay {
                guard let y = day.minutes[slot] else { continue }
                let hour = slot / 60
                sum[hour] += y; cnt[hour] += 1
            }
        }
        var bins: [CircadianEngine.ActivityBin] = []
        for h in 0..<24 where cnt[h] > 0 {
            bins.append(CircadianEngine.ActivityBin(hour: Double(h), activity: sum[h] / Double(cnt[h])))
        }
        return bins
    }
}
