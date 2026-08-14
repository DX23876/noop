import Foundation

/// The measurement rules behind goal tracking: how a goal's "where am I now" number is derived, and
/// how many planned commitments a week must actually deliver to count.
///
/// Lives here rather than in the app target for the usual reason — this is arithmetic, it must be
/// covered by `swift test` with no app, no strap and no database, and it is the half of goal tracking
/// most likely to be argued about. `GoalTrackingEngine` keeps the calendar/plan logic and calls in.
///
/// Nothing here reads a store or a clock: callers pass the values they already hold, pre-filtered to
/// the window they want (the window LENGTHS are defined here so both sides agree on them).
public enum GoalMeasure {

    // MARK: - Windows
    //
    // Reasoned starting values, not validated constants — they live together here on purpose so they
    // can be re-tuned in one place instead of drifting apart across call sites.

    /// Longest run is judged over a training block, not "ever". Without a window a half-marathon from
    /// eleven months ago keeps a goal permanently satisfied and progress can never fall.
    public static let runWindowDays = 56

    /// Sessions-per-week is averaged over four weeks: long enough to survive one quiet week, short
    /// enough that a month off actually shows.
    public static let consistencyWindowDays = 28

    /// One week of nights. Matches the weekly rhythm the rest of goal tracking already runs on.
    public static let sleepWindowNights = 7

    /// Derived daily scores (stress, recovery) are averaged over a week for the same reason.
    public static let scoreWindowDays = 7

    /// History fed to the SMOOTHED score trend. Longer than `scoreWindowDays` on purpose: a 7-day
    /// half-life needs more than seven samples to settle, so the window that feeds the EWMA is not the
    /// window a plain mean would use.
    public static let scoreTrendWindowDays = 28

    /// Weigh-ins older than this don't describe "now". Body weight was the one measure with no window
    /// at all — it read the whole stored year — so someone who stopped weighing in months ago kept a
    /// stale number presented as current, complete with an on-track verdict derived from it. Longer
    /// than the other windows because weighing in is sporadic for most people: a month of silence is
    /// normal, half a year is not.
    public static let weightWindowDays = 90

    /// Settings for a smoothed goal trend.
    public struct TrendCfg: Equatable, Sendable {
        /// Hard plausibility bounds. These reject garbage (a 0 kg sample, a pounds value mistaken for
        /// kg) — they are NOT there to police the metric itself.
        public let minVal: Double
        public let maxVal: Double
        /// Days for the centre to move half-way to a new, sustained level.
        public let halfLifeDays: Double
        public init(minVal: Double, maxVal: Double, halfLifeDays: Double) {
            self.minVal = minVal
            self.maxVal = maxVal
            self.halfLifeDays = halfLifeDays
        }
    }

    /// Body-weight trend config. A 10-day half-life is the usual trend-weight setting: it follows a
    /// real change within a couple of weeks while ignoring the 1-2 kg of daily water/food swing that
    /// makes a raw scale reading useless for judging a goal.
    public static let weightTrend = TrendCfg(minVal: 25.0, maxVal: 400.0, halfLifeDays: 10.0)

    /// Trend config for the derived daily 0-100 scores (stress, recovery). Shorter half-life: these
    /// are already smooth relative to a scale reading, and a week-scale goal wants a week-scale trend.
    public static let scoreTrend = TrendCfg(minVal: 0.0, maxVal: 100.0, halfLifeDays: 7.0)

    // MARK: - Weekly execution threshold

    /// How many of a week's planned commitments must be completed for that week to count.
    ///
    /// The rule is "80%, but a small week may drop one". The plain `ceil(planned × 0.8)` it replaces
    /// demanded **100%** for every week of 1-4 commitments — ceil(0.8)=1, ceil(1.6)=2, ceil(2.4)=3,
    /// ceil(3.2)=4 — so the advertised 80% only ever applied from five sessions up. For the common
    /// 2-4 sessions/week goal that meant a single missed session failed the week, and two such weeks
    /// in a row put the goal "at risk".
    ///
    /// `max(1, planned - 1)` is the "drop one" arm; the `min` keeps the 80% arm binding for larger
    /// weeks, so this is never MORE lenient than 80% and never stricter than the old rule:
    ///
    ///     planned  1  2  3  4  5  6  7
    ///     required 1  1  2  3  4  5  6
    ///
    /// One planned session still has to happen — "drop one" out of one would ask for nothing.
    public static func requiredCompletions(for planned: Int,
                                           successFraction: Double = 0.8) -> Int {
        guard planned > 0 else { return 0 }
        let byFraction = Int(ceil(Double(planned) * successFraction))
        return min(byFraction, max(1, planned - 1))
    }

    // MARK: - Smoothed trend

    /// A goal measurement plus whether it rests on enough data to judge.
    public struct Smoothed: Equatable, Sendable {
        /// The smoothed centre — the value a goal's progress and trend should be computed from.
        public let value: Double
        /// False while the baseline is still cold-starting. A caller should show the number but must
        /// not turn it into an "at risk" verdict yet.
        public let isReliable: Bool
        public init(value: Double, isReliable: Bool) {
            self.value = value
            self.isReliable = isReliable
        }
    }

    /// Nights before a trend is considered settled enough to judge a goal on.
    public static let trendReliableAfter = 4

    /// Smoothed centre of a measurement series, oldest → newest.
    ///
    /// A plain half-life EWMA over plausibility-bounded values, NOT `Baselines.foldHistory`, and the
    /// difference matters. `Baselines` is built for nightly physiology, where a value far from the
    /// baseline is a sensor artefact: past its `hardOutlierK × spread` gate it discards the reading
    /// entirely and does not fold it. On a flat series the spread sits on its floor, so that gate is
    /// tight — and because a rejected value also fails to widen the spread, a genuine step change gets
    /// rejected *permanently* and the trend freezes at the old level. For body weight the opposite
    /// assumption holds: a 3 kg move after a holiday, an illness or a new scale is real and must be
    /// followed. A goal number frozen at last month's weight is a worse failure than a noisy one.
    ///
    /// So: bounds reject only impossible values, and everything plausible is folded. One absurd
    /// morning still barely moves the result — with a 10-day half-life a single 6 kg spike shifts the
    /// centre by ~0.4 kg — while a sustained change is followed in full.
    public static func smoothedTrend(_ values: [Double], cfg: TrendCfg) -> Smoothed? {
        let centres = smoothedSeries(values, cfg: cfg)
        guard let last = centres.last else { return nil }
        return Smoothed(value: last, isReliable: centres.count >= trendReliableAfter)
    }

    /// The same fold as `smoothedTrend`, keeping EVERY intermediate centre rather than only the final
    /// one — oldest → newest, one entry per plausible input.
    ///
    /// For anything that fits a RATE rather than reading a level: `GoalMilestones.observedRatePerDay`
    /// documents that it wants the smoothed series ("so a day of water weight cannot tilt the fitted
    /// rate"), and a least-squares slope over raw scale readings is exactly the noise that contract
    /// exists to keep out. Sharing the fold with `smoothedTrend` is the point — a rate fitted through
    /// one smoothing and a level read from another would disagree about the same series.
    /// Whether a raw reading is inside `cfg`'s plausibility bounds — i.e. whether the fold below will
    /// keep it. Public because a caller pairing values with DATES has to drop the same readings this
    /// does, or the two lists stop lining up: `smoothedSeries` returns one centre per *kept* value, so
    /// zipping it against unfiltered dates would silently shift every sample's date.
    public static func isPlausible(_ value: Double, cfg: TrendCfg) -> Bool {
        value >= cfg.minVal && value <= cfg.maxVal && value.isFinite
    }

    public static func smoothedSeries(_ values: [Double], cfg: TrendCfg) -> [Double] {
        let usable = values.filter { isPlausible($0, cfg: cfg) }
        guard let first = usable.first else { return [] }
        let lambda = 1.0 - pow(0.5, 1.0 / max(cfg.halfLifeDays, 0.5))
        var centre = first
        var centres = [first]
        for value in usable.dropFirst() {
            centre = lambda * value + (1.0 - lambda) * centre
            centres.append(centre)
        }
        return centres
    }

    // MARK: - Plain aggregates
    //
    // Trivial on their own; named here so every goal kind is measured through one vocabulary and the
    // empty-input case is answered the same way everywhere (nil, never 0 — "no data" is not "zero").

    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public static func maximum(_ values: [Double]) -> Double? {
        values.max()
    }

    /// Convert a count observed over a window into a per-week rate.
    public static func perWeek(count: Int, overDays: Int) -> Double? {
        guard overDays > 0, count >= 0 else { return nil }
        return Double(count) / (Double(overDays) / 7.0)
    }

    /// Total minutes from a list of session durations in seconds, per week over the window.
    /// The measure for a strength goal: NOOP has no load tracking, and time is the honest thing it
    /// can actually count (the same choice WHOOP's "Strength Activity Time" goal makes).
    public static func minutesPerWeek(durationsS: [Double], overDays: Int) -> Double? {
        guard overDays > 0 else { return nil }
        guard !durationsS.isEmpty else { return 0 }
        let minutes = durationsS.reduce(0, +) / 60.0
        return minutes / (Double(overDays) / 7.0)
    }
}
