import Foundation

// MARK: - One home for body measurements, and two ways to ask
//
// Body data used to have up to three homes: an undated scalar in the profile, a dated series, and
// Apple Health. The scalar and the series were kept in step by a VIEW writing one into the other,
// while the energy path deliberately refused the scalar and resolved weight per day — because using
// today's weight for history "leaks future information backwards and can rewrite old calorie totals".
// Two parts of the app disagreed about where the truth was. This resolver is the answer to that: every
// measurement is a dated reading, and every read goes through here.
//
// TWO SHAPES, because callers ask two genuinely different questions:
//
//   latest      — what is true NOW. HR zones, the planner, the Settings row.
//   asOf(day:)  — what was true THEN. The energy path, Fitness Age, any chart of history.
//
// Mixing them up is the bug this type exists to prevent, so they are separate calls rather than one
// call with a default.
//
// ON STALENESS, and why it is not decided here. A measurement does not expire on a fixed schedule:
// an adult's height never goes stale, a weigh-in goes stale in weeks, a tape measurement somewhere in
// between. Baking one window in would be wrong for at least two of those, and baking in five would be
// five invented numbers. So `asOf` answers with the most recent reading and its AGE, and the caller
// applies the policy its own question deserves. `CausalWeightResolver` keeps its separate 90-day,
// EWMA-smoothed answer for the energy path: that path is load-bearing and already correct, and this
// type is not a reason to change what it computes.

/// One dated measurement.
public struct BodyReading: Equatable, Sendable {
    /// Local day key (`yyyy-MM-dd`) the reading belongs to.
    public let day: String
    /// Precise instant, used to order two readings on the same day.
    public let takenAt: Int
    public let value: Double
    /// Where it came from — `manual`, `apple-health`, `dexa`, `caliper`, `profile`, …. Carried through
    /// so a chart can keep a DEXA result and a tape estimate on separate series rather than one line.
    public let source: String
    /// The stored row's id, for readings NOOP owns and can therefore change or remove.
    ///
    /// Nil for a reading that arrived some other way — a weigh-in resolved through the weight series,
    /// or an Apple Health import. Those are not ours to edit here: Health's copy is edited in Health,
    /// and a weigh-in has its own screen. Carrying nil rather than a synthetic id is what stops an edit
    /// surface from offering to change something it cannot.
    public let id: String?

    public init(day: String, takenAt: Int, value: Double, source: String, id: String? = nil) {
        self.day = day
        self.takenAt = takenAt
        self.value = value
        self.source = source
        self.id = id
    }

    /// How many days before `day` this reading was taken. Negative if it is in that day's future.
    public func ageDays(on day: String) -> Int {
        StrengthSession.daysBetween(self.day, and: day)
    }
}

/// Every body measurement, answerable at any point in time.
public struct BodyMetrics: Equatable, Sendable {

    /// Ascending by (day, takenAt) within each key.
    private let readings: [String: [BodyReading]]

    /// Builds the resolver. Input order does not matter; readings are sorted here so every lookup is
    /// deterministic regardless of how the store returned them.
    public init(readings: [String: [BodyReading]]) {
        self.readings = readings.mapValues { list in
            list.filter { $0.value.isFinite }
                .sorted { $0.day == $1.day ? $0.takenAt < $1.takenAt : $0.day < $1.day }
        }
    }

    /// An empty resolver — every question answers nil. What a fresh install starts from.
    public static let empty = BodyMetrics(readings: [:])

    /// Every reading for `key`, oldest first.
    public func series(_ key: String) -> [BodyReading] {
        readings[key] ?? []
    }

    /// The newest reading for `key`, whenever it was taken.
    public func latest(_ key: String) -> BodyReading? {
        readings[key]?.last
    }

    /// The reading in force on `day`: the newest one taken on or before it.
    ///
    /// Never looks forward. That is the whole point — a value measured after a day cannot be what was
    /// true during it, and letting one through is exactly how history gets quietly rewritten.
    public func asOf(_ key: String, day: String) -> BodyReading? {
        guard let list = readings[key], !list.isEmpty else { return nil }
        var low = 0
        var high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid].day <= day { low = mid + 1 } else { high = mid }
        }
        return low > 0 ? list[low - 1] : nil
    }

    /// The reading in force on `day`, but only if it is no older than `maximumAgeDays`.
    ///
    /// The caller names the window because the right window depends on the measurement — see the note
    /// at the top of this file.
    public func asOf(_ key: String, day: String, maximumAgeDays: Int) -> BodyReading? {
        guard let reading = asOf(key, day: day),
              reading.ageDays(on: day) <= maximumAgeDays else { return nil }
        return reading
    }

    /// Convenience for the common case: the value in force on `day`, without its metadata.
    public func value(_ key: String, on day: String) -> Double? {
        asOf(key, day: day)?.value
    }

    /// The keys that hold at least one reading.
    public var measuredKeys: [String] {
        readings.filter { !$0.value.isEmpty }.keys.sorted()
    }

}
