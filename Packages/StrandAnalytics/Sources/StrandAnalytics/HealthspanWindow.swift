import Foundation

// HealthspanWindow.swift — turns banked per-day values into `HealthspanEngine.Inputs` for a window: 182 days
// for the age, the last 30 for Pace of Aging.
//
// Raw heart rate is kept for only about five weeks, so anything derived from it (zone minutes) is banked per
// day while it exists; workouts, sleep sessions and daily rows are kept for good. Everything here is pure and
// re-derived from those per-day values each time, so a weekly result never goes stale.

/// One calendar day of healthspan inputs. nil = unknown for that day (not worn, not banked), not zero.
public struct HealthspanDay: Equatable, Sendable {
    public let day: String                  // "yyyy-MM-dd", local
    public var sleepHours: Double?
    public var steps: Double?
    public var sleepMeanHR: Double?         // mean HR of the main sleep ("rhr_primary_session")
    public var sleepConsistencyPct: Double? // SleepTimingConsistency for the night ending this day
    public var zone13Min: Double?           // banked activity minutes at 40–80 % HR reserve
    public var zone45Min: Double?           // banked activity minutes at ≥ 80 % HR reserve
    public var strengthMin: Double?         // minutes of strength-type activities
    public var strengthSessions: Int?       // strength-type sessions starting this day, overlaps merged
    public init(day: String, sleepHours: Double? = nil, steps: Double? = nil, sleepMeanHR: Double? = nil,
                sleepConsistencyPct: Double? = nil, zone13Min: Double? = nil, zone45Min: Double? = nil,
                strengthMin: Double? = nil, strengthSessions: Int? = nil) {
        self.day = day; self.sleepHours = sleepHours; self.steps = steps; self.sleepMeanHR = sleepMeanHR
        self.sleepConsistencyPct = sleepConsistencyPct; self.zone13Min = zone13Min; self.zone45Min = zone45Min
        self.strengthMin = strengthMin; self.strengthSessions = strengthSessions
    }
}

public enum HealthspanWindow {

    public static let ageWindowDays = 182
    public static let paceWindowDays = 30
    /// Days of raw heart rate the store keeps (about five weeks): how far back zone minutes can be banked on a
    /// first run.
    public static let rawRetentionDays = 35
    /// Nights of sleep data before an age is stated at all (spec S5).
    public static let minimumNights = 30
    /// ASSUMPTION: nights in the last 30 days before a pace is stated.
    public static let minimumPaceNights = 14
    /// ASSUMPTION: banked days before a weekly zone-minute rate is stated.
    static let minimumZoneDays = 7

    /// One week's healthspan: the age result, its pace, and how much of the 182-day window had data.
    public struct Weekly: Equatable, Sendable {
        public let inputs: HealthspanEngine.Inputs
        /// The last 30 days' inputs behind the pace; nil until there are enough nights for one.
        public let recentInputs: HealthspanEngine.Inputs?
        public let result: HealthspanEngine.Result
        public let pace: Double?
        public let coveredDays: Int
        /// How much of the 182-day window stands behind each measure (`HealthspanBasis.counts`).
        public let counts: [HealthspanEngine.Component: Int]
        /// Fewer than 182 days of data so far: the age will still move as the window fills.
        public var isProvisional: Bool { coveredDays < HealthspanWindow.ageWindowDays }
    }

    /// The measures the band always supplies. Without all four there is no age at all; any other measure may
    /// be missing, and the screens then say how many of the nine the age stands on rather than letting a gap
    /// read as a met recommendation.
    public static let coreComponents: [HealthspanEngine.Component] = [.sleepDuration, .sleepConsistency,
                                                                      .dailySteps, .restingHR]

    /// The week ending on `end`; nil before `minimumNights` nights of sleep data, without one of the
    /// `coreComponents`, or without a result. `recentVO2max` is the VO₂max behind the pace (defaults to
    /// `vo2max`).
    public static func weekly(days: [HealthspanDay], endingOn end: String, age: Double, sex: HealthspanEngine.Sex,
                              vo2max: Double?, recentVO2max: Double? = nil, leanMassPct: Double?) -> Weekly? {
        let ageDays = slice(days, endingOn: end, windowDays: ageWindowDays)
        guard ageDays.filter({ $0.sleepHours != nil }).count >= minimumNights,
              let window = inputs(days: ageDays, endingOn: end, windowDays: ageWindowDays, age: age, sex: sex,
                                  vo2max: vo2max, leanMassPct: leanMassPct),
              coreComponents.allSatisfy({ window.value($0) != nil }),
              let result = HealthspanEngine.compute(window) else { return nil }
        let paceDays = slice(days, endingOn: end, windowDays: paceWindowDays)
        var pace: Double?
        var recentInputs: HealthspanEngine.Inputs?
        if paceDays.filter({ $0.sleepHours != nil }).count >= minimumPaceNights,
           let recent = inputs(days: paceDays, endingOn: end, windowDays: paceWindowDays, age: age, sex: sex,
                               vo2max: recentVO2max ?? vo2max, leanMassPct: leanMassPct) {
            pace = HealthspanEngine.paceOfAging(window: window, last30Days: recent)
            recentInputs = recent
        }
        return Weekly(inputs: window, recentInputs: recentInputs, result: result, pace: pace,
                      coveredDays: span(ageDays, endingOn: end), counts: HealthspanBasis.counts(ageDays))
    }

    /// What keeps a week from an age, so the screens can name it instead of a fixed guess.
    public struct Gap: Equatable, Sendable {
        /// Nights of sleep data in the 182-day window.
        public let nights: Int
        /// Core measures without a single day in the window, in `coreComponents` order.
        public let missing: [HealthspanEngine.Component]

        public init(nights: Int, missing: [HealthspanEngine.Component]) {
            self.nights = nights
            self.missing = coreComponents.filter(missing.contains)
        }

        /// `missing` as a number for the metric store: bit i set when `coreComponents[i]` is missing.
        public var missingMask: Double {
            Double(coreComponents.enumerated().reduce(0) { missing.contains($1.element) ? $0 | 1 << $1.offset : $0 })
        }

        public init(nights: Int, missingMask: Double) {
            let mask = Int(missingMask)
            self.init(nights: nights,
                      missing: coreComponents.enumerated().filter { mask & 1 << $0.offset != 0 }.map(\.element))
        }
    }

    /// Why the week ending on `end` has no age, read from the same window days `weekly` reads. Call it where
    /// `weekly` returned nil; a gap with enough nights and nothing missing means the engine itself declined.
    public static func gap(days: [HealthspanDay], endingOn end: String) -> Gap {
        let ageDays = slice(days, endingOn: end, windowDays: ageWindowDays)
        let counts = HealthspanBasis.counts(ageDays)
        return Gap(nights: ageDays.filter { $0.sleepHours != nil }.count,
                   missing: coreComponents.filter { (counts[$0] ?? 0) == 0 })
    }

    /// Window inputs: per-day means for sleep, steps, sleep HR and consistency; weekly rates for zone and
    /// strength minutes. nil when the window holds no day at all.
    public static func inputs(days: [HealthspanDay], endingOn end: String, windowDays: Int, age: Double,
                              sex: HealthspanEngine.Sex, vo2max: Double?,
                              leanMassPct: Double?) -> HealthspanEngine.Inputs? {
        let inWindow = slice(days, endingOn: end, windowDays: windowDays)
        guard !inWindow.isEmpty else { return nil }
        func mean(_ f: (HealthspanDay) -> Double?) -> Double? {
            let xs = inWindow.compactMap(f)
            return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
        }
        func bankedWeekly(_ f: (HealthspanDay) -> Double?) -> Double? {
            let xs = inWindow.compactMap(f)
            return xs.count < minimumZoneDays ? nil : xs.reduce(0, +) / Double(xs.count) * 7
        }
        let strength = inWindow.compactMap(\.strengthMin)
        let spanDays = span(inWindow, endingOn: end)
        return HealthspanEngine.Inputs(
            age: age, sex: sex, sleepHours: mean(\.sleepHours), sleepConsistencyPct: mean(\.sleepConsistencyPct),
            dailySteps: mean(\.steps), zone13MinPerWeek: bankedWeekly(\.zone13Min),
            zone45MinPerWeek: bankedWeekly(\.zone45Min),
            strengthMinPerWeek: strength.isEmpty ? nil : strength.reduce(0, +) / Double(spanDays) * 7,
            vo2max: vo2max, restingHR: mean(\.sleepMeanHR), leanMassPct: leanMassPct)
    }

    /// The latest value on or before `end` and no older than `withinDays`.
    public static func latest(_ values: [(day: String, value: Double)], onOrBefore end: String,
                              withinDays: Int) -> Double? {
        let start = dayKey(end, plus: -(withinDays - 1))
        return values.filter { $0.day >= start && $0.day <= end }.max { $0.day < $1.day }?.value
    }

    /// Activities that count as strength: NOOP's strength family plus a published list (yoga, pilates,
    /// barre, HIIT, functional fitness, rucking, …), which NOOP files under other families.
    public static func countsAsStrength(storedName name: String) -> Bool {
        if TrainingActivityClassifier.kind(forStoredName: name) == .strength { return true }
        let key = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return ["yoga", "pilates", "barre", "hiit", "functional", "f45", "ruck", "solidcore", "barrys",
                "boxfitness", "babywearing", "toddlerwearing"].contains { key.contains($0) }
    }

    // MARK: - Days

    static func slice(_ days: [HealthspanDay], endingOn end: String, windowDays: Int) -> [HealthspanDay] {
        let start = dayKey(end, plus: -(windowDays - 1))
        return days.filter { $0.day >= start && $0.day <= end }
    }

    /// Days from the first day with data in `days` through `end`, inclusive.
    static func span(_ days: [HealthspanDay], endingOn end: String) -> Int {
        guard let first = days.map(\.day).min(), let a = date(first), let b = date(end) else { return 0 }
        return Int((b.timeIntervalSince(a) / 86_400).rounded()) + 1
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ key: String) -> Date? { formatter.date(from: key) }

    public static func dayKey(_ key: String, plus days: Int) -> String {
        guard let d = date(key) else { return key }
        return formatter.string(from: d.addingTimeInterval(Double(days) * 86_400))
    }
}

extension HealthspanEngine.Sex {
    /// The profile stores "male", "female" or "nonbinary"; the targets need one of the first two.
    public init?(profileValue: String) {
        switch profileValue.lowercased() {
        case "male": self = .male
        case "female": self = .female
        default: return nil
        }
    }
}
