import Foundation

// MARK: - Daily aggregate model

/// One day's worth of Apple Health metrics, bucketed by the sample's own local
/// day (`start` shifted by `tzOffsetMin`). Mirrors the per-day shape the app
/// stores and charts alongside Whoop.
///
/// All `*Min` fields are minutes; energies are kcal; heart rates are count/min;
/// `spo2Pct` is a 0–100 percentage; `vo2max` is mL/kg/min.
public struct AppleDailyAggregate: Equatable, Sendable {
    /// `yyyy-MM-dd` in the sample's own UTC offset (local civil day).
    public let day: String

    // Cardio / respiratory means
    public let restingHr: Double?
    public let hrvSDNN: Double?
    public let spo2Pct: Double?
    public let respRate: Double?

    // Heart-rate stream
    public let avgHr: Double?
    public let maxHr: Double?
    public let walkingHr: Double?

    // Activity / fitness
    public let steps: Double?
    public let activeKcal: Double?
    public let basalKcal: Double?
    public let vo2max: Double?

    // Body composition (daily latest)
    public let weightKg: Double?
    public let bodyFatPct: Double?
    public let leanMassKg: Double?
    public let bmi: Double?

    // Sleep (minutes per stage), keyed by the wake day
    public let asleepMin: Double?
    public let deepMin: Double?
    public let remMin: Double?
    public let coreMin: Double?
    public let awakeMin: Double?
    public let inBedMin: Double?

    public init(
        day: String,
        restingHr: Double? = nil,
        hrvSDNN: Double? = nil,
        spo2Pct: Double? = nil,
        respRate: Double? = nil,
        avgHr: Double? = nil,
        maxHr: Double? = nil,
        walkingHr: Double? = nil,
        steps: Double? = nil,
        activeKcal: Double? = nil,
        basalKcal: Double? = nil,
        vo2max: Double? = nil,
        weightKg: Double? = nil,
        bodyFatPct: Double? = nil,
        leanMassKg: Double? = nil,
        bmi: Double? = nil,
        asleepMin: Double? = nil,
        deepMin: Double? = nil,
        remMin: Double? = nil,
        coreMin: Double? = nil,
        awakeMin: Double? = nil,
        inBedMin: Double? = nil
    ) {
        self.day = day
        self.restingHr = restingHr
        self.hrvSDNN = hrvSDNN
        self.spo2Pct = spo2Pct
        self.respRate = respRate
        self.avgHr = avgHr
        self.maxHr = maxHr
        self.walkingHr = walkingHr
        self.steps = steps
        self.activeKcal = activeKcal
        self.basalKcal = basalKcal
        self.vo2max = vo2max
        self.weightKg = weightKg
        self.bodyFatPct = bodyFatPct
        self.leanMassKg = leanMassKg
        self.bmi = bmi
        self.asleepMin = asleepMin
        self.deepMin = deepMin
        self.remMin = remMin
        self.coreMin = coreMin
        self.awakeMin = awakeMin
        self.inBedMin = inBedMin
    }
}

// MARK: - Aggregator

/// Turns a parsed Apple Health export into per-day aggregates.
public enum AppleHealthAggregator {

    // MARK: Type identifiers
    //
    // `HealthSample.type` is stored with the `HKQuantityTypeIdentifier` /
    // `HKCategoryTypeIdentifier` prefix already stripped (see
    // `AppleHealthImporter.stripPrefix`). We still accept the full identifier
    // form so callers feeding raw HK strings get the same mapping.

    static let restingHR = "RestingHeartRate"
    static let hrvSDNN = "HeartRateVariabilitySDNN"
    static let spo2 = "OxygenSaturation"
    static let respRate = "RespiratoryRate"
    static let walkingHR = "WalkingHeartRateAverage"
    static let heartRate = "HeartRate"
    static let stepCount = "StepCount"
    static let activeEnergy = "ActiveEnergyBurned"
    static let basalEnergy = "BasalEnergyBurned"
    static let vo2max = "VO2Max"
    static let bodyMass = "BodyMass"
    static let bodyFat = "BodyFatPercentage"
    static let leanMass = "LeanBodyMass"
    static let bodyMassIndex = "BodyMassIndex"

    /// Normalize a sample's `type` to the stripped HK identifier so matching
    /// works whether the caller passed `HeartRate` or
    /// `HKQuantityTypeIdentifierHeartRate`.
    static func normalizedType(_ raw: String) -> String {
        let prefixes = [
            "HKQuantityTypeIdentifier",
            "HKCategoryTypeIdentifier",
            "HKDataTypeIdentifier",
        ]
        for p in prefixes where raw.hasPrefix(p) {
            return String(raw.dropFirst(p.count))
        }
        return raw
    }

    /// Whether a HealthKit mass unit string denotes pounds (`lb`, `lbs`).
    /// HealthKit normally exports BodyMass/LeanBodyMass in kg, but guard against
    /// pound-denominated exports.
    static func unitLooksLikePounds(_ unit: String?) -> Bool {
        guard let u = unit?.lowercased() else { return false }
        return u == "lb" || u == "lbs" || u.contains("pound")
    }

    /// Apple exports overlapping cumulative energy from multiple producers. Prefer the Watch source
    /// and otherwise take one source's total; adding sources measures the same activity twice.
    static func preferredEnergyTotal(_ values: [String: Double]) -> Double? {
        let usable = values.filter { !$0.key.lowercased().contains("noop") }
        let watch = usable.filter { $0.key.lowercased().contains("watch") }.map(\.value).max()
        return watch ?? usable.values.max()
    }

    // MARK: Day bucketing

    /// `yyyy-MM-dd` for a UTC `Date` shifted into its own local offset.
    /// We add the offset to the UTC instant and read the calendar fields in
    /// UTC, which yields the civil (wall-clock) date the sample was recorded on.
    static func localDay(_ utc: Date, tzOffsetMin: Int) -> String {
        let shifted = utc.addingTimeInterval(TimeInterval(tzOffsetMin * 60))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month, .day], from: shifted)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - Sample daily aggregation

    /// Group `HealthSamples` by local day and apply the per-type reduction rules.
    ///
    /// This is the **batch** form. It is a thin wrapper over
    /// `AppleDailySampleAccumulator` so the running (incremental) fold and the
    /// batch fold share ONE set of reduction rules — the accumulator is the
    /// single source of truth. The streaming importer feeds samples one-by-one
    /// into the same accumulator so a multi-year export never has to hold the raw
    /// `[HealthSample]` array in RAM.
    public static func daily(samples: [HealthSample]) -> [AppleDailyAggregate] {
        var acc = AppleDailySampleAccumulator()
        for s in samples { acc.add(s) }
        return acc.finish()
    }

    // MARK: - Sleep daily aggregation

    /// Collapse sleep-stage intervals into per-night totals keyed by the **wake
    /// day** — the local civil day of each interval's `end`. Minutes are summed
    /// per stage; `asleep = core + deep + rem` (+ any legacy "asleep
    /// unspecified" intervals, which Apple emitted before staged sleep).
    public static func sleepDaily(
        _ intervals: [SleepStageInterval]
    ) -> [String: (asleep: Double, deep: Double, rem: Double, core: Double, awake: Double, inBed: Double)] {
        struct Night {
            var deep = 0.0, rem = 0.0, core = 0.0, unspecified = 0.0, awake = 0.0, inBed = 0.0
        }
        var byDay: [String: Night] = [:]

        for iv in intervals {
            let minutes = max(0, iv.end.timeIntervalSince(iv.start)) / 60.0
            // Wake day = local day of the interval end.
            let day = localDay(iv.end, tzOffsetMin: iv.tzOffsetMin)
            var n = byDay[day] ?? Night()
            switch iv.stage {
            case .asleepDeep:        n.deep += minutes
            case .asleepREM:         n.rem += minutes
            case .asleepCore:        n.core += minutes
            case .asleepUnspecified: n.unspecified += minutes
            case .awake:             n.awake += minutes
            case .inBed:             n.inBed += minutes
            case .unknown:           break
            }
            byDay[day] = n
        }

        var out: [String: (asleep: Double, deep: Double, rem: Double, core: Double, awake: Double, inBed: Double)] = [:]
        for (day, n) in byDay {
            let asleep = n.core + n.deep + n.rem + n.unspecified
            out[day] = (asleep: asleep, deep: n.deep, rem: n.rem, core: n.core, awake: n.awake, inBed: n.inBed)
        }
        return out
    }

    // MARK: - Full merge

    /// Full merge of sample-daily + sleep-daily into `[AppleDailyAggregate]`,
    /// one row per day present in either source, sorted ascending by day.
    public static func aggregate(_ result: AppleHealthImportResult) -> [AppleDailyAggregate] {
        // When the importer pre-aggregated the samples incrementally (bounded
        // memory — issue #355), `sampleDailies` is already populated and the raw
        // `samples` array may have been dropped. Use the pre-aggregated form in
        // that case; otherwise fall back to folding the raw samples here (the
        // path tests take when they construct a result from raw `samples`). An
        // empty export leaves both empty → daily([]) → [] — fine.
        let sampleDaily = result.sampleDailies.isEmpty
            ? daily(samples: result.samples)
            : result.sampleDailies
        let sleep = sleepDaily(result.sleepIntervals)

        var byDay: [String: AppleDailyAggregate] = [:]
        for d in sampleDaily { byDay[d.day] = d }

        // Union of days from both sources.
        var days = Set(byDay.keys)
        days.formUnion(sleep.keys)

        let merged: [AppleDailyAggregate] = days.map { day in
            let base = byDay[day]
            let s = sleep[day]
            return AppleDailyAggregate(
                day: day,
                restingHr: base?.restingHr,
                hrvSDNN: base?.hrvSDNN,
                spo2Pct: base?.spo2Pct,
                respRate: base?.respRate,
                avgHr: base?.avgHr,
                maxHr: base?.maxHr,
                walkingHr: base?.walkingHr,
                steps: base?.steps,
                activeKcal: base?.activeKcal,
                basalKcal: base?.basalKcal,
                vo2max: base?.vo2max,
                weightKg: base?.weightKg,
                bodyFatPct: base?.bodyFatPct,
                leanMassKg: base?.leanMassKg,
                bmi: base?.bmi,
                asleepMin: s?.asleep,
                deepMin: s?.deep,
                remMin: s?.rem,
                coreMin: s?.core,
                awakeMin: s?.awake,
                inBedMin: s?.inBed
            )
        }
        return merged.sorted { $0.day < $1.day }
    }

    // MARK: - Metric point flattening

    /// Flatten daily aggregates into generic `(day, key, value)` metric points
    /// for the metricSeries store. Only present (non-nil) values are emitted.
    /// Keys are stable, snake_case identifiers.
    public static func metricPoints(_ daily: [AppleDailyAggregate]) -> [(day: String, key: String, value: Double)] {
        var out: [(day: String, key: String, value: Double)] = []
        for d in daily {
            func add(_ key: String, _ value: Double?) {
                if let v = value { out.append((day: d.day, key: key, value: v)) }
            }
            add("resting_hr", d.restingHr)
            add("hrv", d.hrvSDNN)
            add("spo2", d.spo2Pct)
            add("resp_rate", d.respRate)
            add("avg_hr", d.avgHr)
            add("max_hr", d.maxHr)
            add("walking_hr", d.walkingHr)
            add("steps", d.steps)
            add("active_kcal", d.activeKcal)
            add("basal_kcal", d.basalKcal)
            add("vo2max", d.vo2max)
            add("weight", d.weightKg)
            add("body_fat", d.bodyFatPct)
            add("lean_mass", d.leanMassKg)
            add("bmi", d.bmi)
            add("asleep_min", d.asleepMin)
            add("deep_min", d.deepMin)
            add("rem_min", d.remMin)
            add("core_min", d.coreMin)
            add("awake_min", d.awakeMin)
            add("in_bed_min", d.inBedMin)
        }
        return out
    }
}

// MARK: - Incremental (bounded-memory) sample accumulator

/// A running, O(days)-memory accumulator that produces output **identical** to
/// `AppleHealthAggregator.daily(samples:)` without ever holding the raw
/// `[HealthSample]` array.
///
/// WHY this exists (issue #355): a multi-year Apple Health export with
/// Apple-Watch continuous heart-rate is millions of `HealthSample` structs —
/// hundreds of MB to >1 GB — which iOS jetsam-kills mid-import. The streaming
/// SAX importer feeds each parsed sample straight into this accumulator and (on
/// the app path) drops the raw struct, so peak memory is bounded to the number
/// of distinct civil days, not the number of samples.
///
/// It mirrors `daily(samples:)` EXACTLY: same `normalizedType` + per-type switch,
/// the same spo2/bodyFat fraction (0..1→percent) guards, the same pounds→kg unit
/// check, the same "latest by `end`" rule for vo2/weight/bodyFat/lean/bmi, the
/// same first-seen-day order preservation, and the same final
/// `sorted { $0.day < $1.day }`. `daily(samples:)` is implemented as a thin loop
/// over this type, so the existing `AppleHealthAggregatorTests` keep validating
/// both the batch and incremental paths at once.
public struct AppleDailySampleAccumulator {

    /// Per-day running state. Means are kept as (sum, count) — no per-sample
    /// arrays — and max as a running maximum, so memory is O(days).
    private struct DayAcc {
        // Means: running sum + count.
        var restingSum = 0.0; var restingN = 0
        var hrvSum = 0.0;     var hrvN = 0
        var spo2Sum = 0.0;    var spo2N = 0
        var respSum = 0.0;    var respN = 0
        var walkingSum = 0.0; var walkingN = 0
        var hrSum = 0.0;      var hrN = 0
        // HeartRate max (running).
        var hrMax: Double?
        // Sums + presence flags.
        // #589: per-SOURCE step sums. Apple Health keeps overlapping step samples from EACH device
        // (an iPhone AND an Apple Watch both count the same walk); summing across sources double-counts
        // (~2x). We sum WITHIN a source but take the MAX source per day at finish() — the de-overlap
        // Apple's own Health app shows instead of a raw sum.
        var stepsBySource: [String: Double] = [:]
        var activeBySource: [String: Double] = [:]
        var basalBySource: [String: Double] = [:]
        // Latest-by-end values.
        var vo2: Double?;     var vo2At: Date?
        var weight: Double?;  var weightAt: Date?
        var bodyFat: Double?; var bodyFatAt: Date?
        var lean: Double?;    var leanAt: Date?
        var bmi: Double?;     var bmiAt: Date?
    }

    private var byDay: [String: DayAcc] = [:]
    /// Preserve first-seen day order for deterministic output before the sort
    /// (mirrors `daily(samples:)`'s `order` array).
    private var order: [String] = []

    public init() {}

    /// Fold one sample into the running per-day state. Applies the SAME
    /// reduction rules as `AppleHealthAggregator.daily(samples:)`.
    public mutating func add(_ s: HealthSample) {
        let type = AppleHealthAggregator.normalizedType(s.type)
        let day = AppleHealthAggregator.localDay(s.start, tzOffsetMin: s.tzOffsetMin)
        if byDay[day] == nil {
            byDay[day] = DayAcc()
            order.append(day)
        }

        switch type {
        case AppleHealthAggregator.restingHR:
            if let v = s.value { byDay[day]!.restingSum += v; byDay[day]!.restingN += 1 }
        case AppleHealthAggregator.hrvSDNN:
            if let v = s.value { byDay[day]!.hrvSum += v; byDay[day]!.hrvN += 1 }
        case AppleHealthAggregator.spo2:
            if let v = s.value {
                // Detect fraction (0..1) → percent. The importer already scales
                // OxygenSaturation by 100, but defend against raw fractional
                // values here too. (Identical to daily().)
                let pct = (v > 0 && v <= 1.0) ? v * 100.0 : v
                byDay[day]!.spo2Sum += pct; byDay[day]!.spo2N += 1
            }
        case AppleHealthAggregator.respRate:
            if let v = s.value { byDay[day]!.respSum += v; byDay[day]!.respN += 1 }
        case AppleHealthAggregator.walkingHR:
            if let v = s.value { byDay[day]!.walkingSum += v; byDay[day]!.walkingN += 1 }
        case AppleHealthAggregator.heartRate:
            if let v = s.value {
                byDay[day]!.hrSum += v; byDay[day]!.hrN += 1
                if let m = byDay[day]!.hrMax { byDay[day]!.hrMax = Swift.max(m, v) }
                else { byDay[day]!.hrMax = v }
            }
        case AppleHealthAggregator.stepCount:
            // Sum WITHIN a source, never across sources (iPhone + Watch overlap → double-count). (#589)
            if let v = s.value { byDay[day]!.stepsBySource[s.sourceName ?? "", default: 0] += v }
        case AppleHealthAggregator.activeEnergy:
            if let v = s.value { byDay[day]!.activeBySource[s.sourceName ?? "", default: 0] += v }
        case AppleHealthAggregator.basalEnergy:
            if let v = s.value { byDay[day]!.basalBySource[s.sourceName ?? "", default: 0] += v }
        case AppleHealthAggregator.vo2max:
            if let v = s.value {
                let acc = byDay[day]!
                if acc.vo2 == nil || (acc.vo2At ?? .distantPast) <= s.end {
                    byDay[day]!.vo2 = v
                    byDay[day]!.vo2At = s.end
                }
            }
        case AppleHealthAggregator.bodyMass:
            if let v = s.value {
                // HealthKit stores BodyMass in kg by default. If the unit looks
                // like pounds, convert to kg; otherwise assume kg.
                let kg = AppleHealthAggregator.unitLooksLikePounds(s.unit) ? v * 0.453592 : v
                let acc = byDay[day]!
                if acc.weight == nil || (acc.weightAt ?? .distantPast) <= s.end {
                    byDay[day]!.weight = kg
                    byDay[day]!.weightAt = s.end
                }
            }
        case AppleHealthAggregator.bodyFat:
            if let v = s.value {
                // HealthKit stores a 0..1 fraction → percent. Defend against
                // already-percent values the same way SpO2 does.
                let pct = (v > 0 && v <= 1.0) ? v * 100.0 : v
                let acc = byDay[day]!
                if acc.bodyFat == nil || (acc.bodyFatAt ?? .distantPast) <= s.end {
                    byDay[day]!.bodyFat = pct
                    byDay[day]!.bodyFatAt = s.end
                }
            }
        case AppleHealthAggregator.leanMass:
            if let v = s.value {
                let kg = AppleHealthAggregator.unitLooksLikePounds(s.unit) ? v * 0.453592 : v
                let acc = byDay[day]!
                if acc.lean == nil || (acc.leanAt ?? .distantPast) <= s.end {
                    byDay[day]!.lean = kg
                    byDay[day]!.leanAt = s.end
                }
            }
        case AppleHealthAggregator.bodyMassIndex:
            if let v = s.value {
                let acc = byDay[day]!
                if acc.bmi == nil || (acc.bmiAt ?? .distantPast) <= s.end {
                    byDay[day]!.bmi = v
                    byDay[day]!.bmiAt = s.end
                }
            }
        default:
            break
        }
    }

    /// Emit the per-day aggregates (mean = sum/count, running max, sums, latest),
    /// in first-seen order then sorted ascending by day — identical to
    /// `daily(samples:)`.
    public func finish() -> [AppleDailyAggregate] {
        func mean(_ sum: Double, _ n: Int) -> Double? { n == 0 ? nil : sum / Double(n) }

        let result: [AppleDailyAggregate] = order.map { day in
            let a = byDay[day]!
            return AppleDailyAggregate(
                day: day,
                restingHr: mean(a.restingSum, a.restingN),
                hrvSDNN: mean(a.hrvSum, a.hrvN),
                spo2Pct: mean(a.spo2Sum, a.spo2N),
                respRate: mean(a.respSum, a.respN),
                avgHr: mean(a.hrSum, a.hrN),
                maxHr: a.hrMax,
                walkingHr: mean(a.walkingSum, a.walkingN),
                steps: a.stepsBySource.isEmpty ? nil : a.stepsBySource.values.max(),   // #589 max source, not cross-source sum
                activeKcal: AppleHealthAggregator.preferredEnergyTotal(a.activeBySource),
                basalKcal: AppleHealthAggregator.preferredEnergyTotal(a.basalBySource),
                vo2max: a.vo2,
                weightKg: a.weight,
                bodyFatPct: a.bodyFat,
                leanMassKg: a.lean,
                bmi: a.bmi
            )
        }
        return result.sorted { $0.day < $1.day }
    }
}
