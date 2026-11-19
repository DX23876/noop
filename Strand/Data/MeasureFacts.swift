import Foundation

/// What a measure tile knows about itself beyond today's figure, shared by the iPhone and the Android core.
///
/// The owner's correction of 2026-11-18: a tile that is given more room should say MORE FACTS, not the same
/// figure over a longer span. Steps at two columns adds the week and the daily average; weight adds when it
/// was last weighed and which way it has gone. So one read produces one bundle, and each size of each tile
/// picks what it needs from it.
///
/// One bundle, computed once, is the point. The same week must not be averaged in Swift for the iPhone and
/// again in Kotlin for Android: that is exactly where two numbers for one fact start to disagree, which the
/// fork rules forbid above almost everything else. The platforms keep their own WORDS (each writes
/// "diese Woche" or "this week" in its own catalogue), as they already do for `MeasureTileReading.summary`.
///
/// Pure: dates in, numbers out, no store and no clock of its own. Analysis migration required: no.
enum MeasureFacts {

    /// A day and its value, oldest first, as every series on both platforms is already ordered.
    struct Point: Equatable, Sendable {
        let day: String
        let value: Double
        init(day: String, value: Double) { self.day = day; self.value = value }
    }

    /// Everything a tile can ask about one measure. A field is nil when the data cannot answer it, never a
    /// stand-in: a measure with no reading today has no `today`, and a tile must say so rather than show
    /// the last one as if it were current.
    struct Facts: Equatable, Sendable {
        /// Today's reading, nil when nothing was recorded today.
        let today: Double?
        /// The mean of the days that HAVE a reading in the last seven, nil when none do. Missing days are
        /// skipped rather than counted as zero: a day without a weigh-in is not a weight of nothing.
        let weekAverage: Double?
        /// The sum over the last seven days. Only meaningful for day totals (steps, minutes, calories), and
        /// the tile decides whether to show it.
        let weekTotal: Double?
        /// The newest reading there is, however old. This is what "last weighed" reads.
        let lastValue: Double?
        let lastDay: String?
        /// Whole days between `lastDay` and today. 0 means today, 1 yesterday.
        let daysSinceLast: Int?
        /// The newest reading minus the newest one at least seven days older, nil without both. The honest
        /// way to say "which way it has gone this week" for a measure that is not recorded daily.
        let weekChange: Double?
        /// The same against a reading at least ninety days older. What a measure that moves too slowly for a
        /// week to show can say instead: VO2max, the fitness age, the body ages.
        let quarterChange: Double?
        /// The day's goal, when the caller has one (calories, protein, water, steps).
        let target: Double?
        /// `target` minus today's reading, floored at zero, nil without both.
        let targetLeft: Double?
        /// The last thirty readings in order, for the row-wide form's curve.
        let last30: [Double]
        /// The best of the last thirty readings and the day it fell on, in the direction that counts as
        /// better for THIS measure (`direction(forKey:)`). Nil where no direction can be claimed: whether
        /// a weight going up is good depends on the wearer's goal, and a skin temperature is read by how
        /// far it is from its own baseline, not by being high or low.
        let best: Double?
        let bestDay: String?
        /// The same within the SEVEN days ending today. A measure whose wider form draws the week must
        /// name a best the picture can show: "highest 13,729 on 26 Oct" under seven bars that start on
        /// Friday is a figure the reader cannot find.
        let weekBest: Double?
        let weekBestDay: String?
        /// Of the days in the week that have a reading, how many reached the goal. Nil without a goal.
        let daysAboveTarget: Int?
        /// How many of the seven days have a reading at all, so "5 of 7 days" can say what the 7 counts.
        let weekDaysWithEntry: Int
        /// How many of the last thirty days have a reading. What "days with a weigh-in" means.
        let daysWithEntry: Int
        /// Of the last ten readings, how many are above the usual (the median of the thirty before the
        /// newest, the same usual the change chip is read against). Nil under eleven readings, because a
        /// count out of ten that is really out of four says something untrue about its own denominator.
        let aboveUsualRecently: Int?
    }

    /// Which way is better for a measure, decided in one place because both phones word a best mark from it.
    ///
    /// Unlisted means `neither`, on purpose: a tile then shows no best mark at all rather than calling the
    /// highest of thirty days a record when nobody said high was good. Weight and skin temperature are the
    /// worked examples — a weight going up is good or bad depending on the goal, and a skin temperature is
    /// read by its distance from its own baseline.
    enum Direction: String, Sendable { case higherIsBetter, lowerIsBetter, neither }

    /// Whether a measure's row-wide form draws the WEEK as bars rather than thirty days as a line.
    ///
    /// These are the day totals: what you did that day, not what you were, where the question is which days
    /// you did it on (owner, 2026-11-19). Kept here because the drawn window decides which best mark the
    /// strip may name, so the picture and the figure under it cannot disagree about what they cover.
    static func drawsTheWeek(forKey key: String) -> Bool {
        ["steps", "active_kcal", "calories_in", "water_ml", "protein_g",
         "hr_zones13_min", "hr_zones45_min"].contains(key)
    }

    static func direction(forKey key: String) -> Direction {
        switch key {
        case "hrv", "steps", "spo2", "sleep_total_min", "sleep_performance", "recovery", "vo2max_est",
             "water_ml", "protein_g", "mood", "lean_mass", "hr_zones13_min", "hr_zones45_min":
            return .higherIsBetter
        case "rhr", "resp_rate", "fitness_age", "body_age", "vitality", "stress", "sleep_debt_min",
             "body_fat":
            return .lowerIsBetter
        default:
            return .neither
        }
    }

    /// The day's goal for the measures that have one, from the one place it is stored.
    ///
    /// Read here rather than on each phone: the step goal lives under one key both apps already write
    /// (`momentum.stepGoal`, Android's `CorePrefs.STEP_GOAL`), and a tile that read it itself would be a
    /// second readout of a number the goals screen owns. Zero or unset means no goal, which is not the same
    /// as a goal of nothing: the tile then shows no goal bar and no count of days over it.
    /// Whether a measure's goal has to be RESOLVED rather than read from a key.
    ///
    /// Protein is the only one: its goal is the day's macro goal, which comes out of the diet plan's own
    /// day, the plan without that day's context, the wearer's fixed goal or the energy plan, in that order
    /// (`FoodTargets.dayGoal`). No key holds it, so a tile has to ask for it and hand it in; what it must
    /// not do is work it out for itself, because then the tile and the Food page would each have their own
    /// protein goal.
    static func resolvesItsTarget(forKey key: String) -> Bool { key == "protein_g" }

    static func storedTarget(forKey key: String, defaults: UserDefaults = .standard) -> Double? {
        switch key {
        case "steps":
            let goal = defaults.integer(forKey: "momentum.stepGoal")
            return goal > 0 ? Double(goal) : nil
        default:
            return nil
        }
    }

    // MARK: - What the wider forms put beside the chart

    /// One of the kit's named blocks (owner, 2026-11-19). A row-wide tile must say at least five things, so
    /// the figure, its change and its chart are not enough on their own; these are what goes underneath.
    enum StripItem: String, Sendable, Encodable {
        /// The best of the drawn thirty days, with the day it fell on.
        case best
        /// The mean of the days in the last seven that have a reading.
        case weekAverage
        /// The sum over the last seven days, for a measure that is a day total.
        case weekTotal
        /// The lowest and highest of the drawn thirty days.
        case range
        /// How the newest reading sits against the wearer's usual.
        case weekChange
        /// The same over ninety days, for a measure a week cannot move.
        case quarterChange
        /// How many of the week's days reached the goal, out of how many have a reading.
        case daysOverGoal
        /// How many of the drawn thirty days have a reading at all.
        case daysWithEntry
        /// How many of the last ten readings are above the usual.
        case aboveUsual
        /// What is left of today's goal.
        case targetLeft
    }

    /// A block with its figures already formatted, so the two phones round alike and each only writes the
    /// words around them. Every field is nil unless the block uses it.
    struct StripEntry: Equatable, Sendable, Encodable {
        let item: StripItem
        /// The figure, as the tile writes it.
        let text: String?
        /// A second figure, where the block is a span (the range's high).
        let text2: String?
        /// The day the figure fell on, "yyyy-MM-dd", for the best mark. Each phone writes the date itself.
        let day: String?
        /// A count and what it is out of, for the two counting blocks.
        let count: Int?
        let total: Int?

        init(_ item: StripItem, text: String? = nil, text2: String? = nil, day: String? = nil,
             count: Int? = nil, total: Int? = nil) {
            self.item = item; self.text = text; self.text2 = text2
            self.day = day; self.count = count; self.total = total
        }
    }

    /// Which blocks a measure puts under its chart, in order, from the owner's table of 2026-11-19.
    ///
    /// Decided here and not per platform: the two phones would otherwise answer "what else does this tile
    /// say" differently, which is the same class of fault as two figures for one fact. A block whose data is
    /// missing is dropped rather than drawn empty, so a measure with a short history simply says less.
    static func strip(key: String, facts: Facts, values: [Double]) -> [StripEntry] {
        let wanted: [StripItem] = switch key {
        case "steps", "active_kcal", "calories_in", "hr_zones13_min", "hr_zones45_min":
            [.best, .daysOverGoal, .weekTotal]
        case "hrv", "spo2", "sleep_performance", "recovery":
            [.best, .aboveUsual, .weekAverage]
        case "rhr", "resp_rate":
            [.best, .aboveUsual, .weekAverage]
        // Weight claims no best, so what is left is the move, the goal and how often it was actually
        // stepped on: "tracking down 0.4 kg a week" means nothing without the days behind it.
        case "weight", "body_fat", "lean_mass":
            [.weekChange, .targetLeft, .daysWithEntry]
        case "skin_temp":
            [.range, .weekAverage, .daysWithEntry]
        // These move too slowly for a week to show anything, so the strip carries the quarter's move.
        case "vo2max_est", "fitness_age", "vitality", "body_age":
            [.quarterChange, .range, .weekAverage]
        default:
            [.best, .range, .weekAverage]
        }
        let summary = MeasureTileReading.summary(key: key, values: values)
        func figure(_ value: Double?) -> String? {
            value.map { MeasureTileReading.figure(key: key, value: $0) }
        }
        return wanted.compactMap { item -> StripEntry? in
            switch item {
            case .best:
                // A measure whose picture is the week names its best within that week, so the mark and the
                // bars cover the same days.
                let week = drawsTheWeek(forKey: key)
                guard let text = figure(week ? facts.weekBest : facts.best),
                      let day = week ? facts.weekBestDay : facts.bestDay else { return nil }
                return StripEntry(.best, text: text, day: day)
            case .weekAverage:
                return figure(facts.weekAverage).map { StripEntry(.weekAverage, text: $0) }
            case .weekTotal:
                return figure(facts.weekTotal).map { StripEntry(.weekTotal, text: $0) }
            case .range:
                guard let s = summary else { return nil }
                return StripEntry(.range, text: s.low, text2: s.high)
            case .weekChange, .quarterChange:
                // Signed, because which way it went IS the fact; the sign is the word each phone writes.
                guard let change = item == .weekChange ? facts.weekChange : facts.quarterChange else { return nil }
                return StripEntry(item, text: figure(abs(change)), count: change > 0 ? 1 : change < 0 ? -1 : 0)
            case .daysOverGoal:
                guard let count = facts.daysAboveTarget else { return nil }
                return StripEntry(.daysOverGoal, count: count, total: 7)
            case .daysWithEntry:
                guard facts.daysWithEntry > 0 else { return nil }
                return StripEntry(.daysWithEntry, count: facts.daysWithEntry, total: 30)
            case .aboveUsual:
                guard let count = facts.aboveUsualRecently else { return nil }
                return StripEntry(.aboveUsual, count: count, total: 10)
            case .targetLeft:
                return figure(facts.targetLeft).map { StripEntry(.targetLeft, text: $0) }
            }
        }
    }

    /// Read one measure's facts from its series.
    ///
    /// - Parameters:
    ///   - points: the series, oldest first, one point per day that HAS a reading. Days without one are
    ///     simply absent; nothing is interpolated.
    ///   - today: the logical day key the caller counts from, passed in rather than read, so a test can
    ///     place "today" where it wants it and the two platforms cannot disagree about when today is.
    ///   - target: the day's goal, where the caller has one.
    ///   - direction: which way counts as better, for the best mark. Taken from `direction(forKey:)` by
    ///     the callers that have a catalogue key; passed in so a caller with a goal of its own (a weight
    ///     plan going down) can say so.
    static func read(points: [Point], today: String, target: Double? = nil,
                     direction: Direction = .neither) -> Facts {
        let ordered = points.sorted { $0.day < $1.day }
        let todayValue = ordered.last(where: { $0.day == today })?.value
        let last = ordered.last

        // The seven days ending today, by day key rather than by position: a gappy series would otherwise
        // reach weeks back and call it a week.
        let weekStart = dayKey(today, minusDays: 6)
        let week = ordered.filter { $0.day >= weekStart && $0.day <= today }
        let weekValues = week.map(\.value)

        let daysSince = last.flatMap { days(from: $0.day, to: today) }
        func changeOver(_ days: Int) -> Double? {
            guard let newest = last else { return nil }
            let cutoff = dayKey(newest.day, minusDays: days)
            guard let before = ordered.last(where: { $0.day <= cutoff }) else { return nil }
            return newest.value - before.value
        }
        let change = changeOver(7)
        let left = target.flatMap { t in todayValue.map { max(0, t - $0) } }

        // The last thirty days by day key, as the row-wide chart draws them, so a best mark names a day
        // inside the drawn window rather than the thirtieth entry back in a gappy series.
        let windowStart = dayKey(today, minusDays: 29)
        let window = ordered.filter { $0.day >= windowStart && $0.day <= today }
        func pick(_ points: [Point]) -> Point? {
            switch direction {
            case .higherIsBetter: return points.max { $0.value < $1.value }
            case .lowerIsBetter: return points.min { $0.value < $1.value }
            case .neither: return nil
            }
        }
        let best = pick(window)
        let weekBest = pick(week)
        let above = target.map { t in week.filter { $0.value >= t }.count }
        // The same usual the change chip is read against (`MeasureTileReading`): the median of the thirty
        // readings before the newest. Both counts then stand on one number instead of two.
        let aboveUsual: Int? = {
            guard ordered.count >= 11 else { return nil }
            let before = ordered.dropLast().suffix(30).map(\.value).sorted()
            let usual = before[before.count / 2]
            return ordered.suffix(10).filter { $0.value > usual }.count
        }()

        return Facts(today: todayValue,
                     weekAverage: weekValues.isEmpty ? nil : weekValues.reduce(0, +) / Double(weekValues.count),
                     weekTotal: weekValues.isEmpty ? nil : weekValues.reduce(0, +),
                     lastValue: last?.value, lastDay: last?.day, daysSinceLast: daysSince,
                     weekChange: change, quarterChange: changeOver(90),
                     target: target, targetLeft: left,
                     last30: Array(ordered.suffix(30).map(\.value)),
                     best: best?.value, bestDay: best?.day,
                     weekBest: weekBest?.value, weekBestDay: weekBest?.day, daysAboveTarget: above,
                     weekDaysWithEntry: week.count, daysWithEntry: window.count,
                     aboveUsualRecently: aboveUsual)
    }

    // MARK: - Day keys

    /// Day keys are "yyyy-MM-dd" on both platforms, so they are compared as text and shifted as dates. A key
    /// that does not parse yields the key itself, which keeps a malformed series harmless rather than fatal.
    static func dayKey(_ day: String, minusDays: Int) -> String {
        guard let date = formatter.date(from: day) else { return day }
        return formatter.string(from: date.addingTimeInterval(-Double(minusDays) * 86_400))
    }

    static func days(from: String, to: String) -> Int? {
        guard let a = formatter.date(from: from), let b = formatter.date(from: to) else { return nil }
        return Int(((b.timeIntervalSince1970 - a.timeIntervalSince1970) / 86_400).rounded())
    }

    /// UTC, because a day key is a label and not a moment: shifting it must not depend on where the phone is
    /// or on whether the clocks changed last night.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
