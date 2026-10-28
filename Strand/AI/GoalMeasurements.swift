import Foundation
import WhoopStore
import StrandAnalytics
import StrandCore

/// Measured goal inputs, shared unchanged by Apple tracking and the Android core.
enum GoalMeasurements {
    /// Derive "where am I now" per goal kind. `weights` arrives already windowed and ordered (the rate
    /// fit needs the same series, so the caller does it once). The window lengths and the smoothing live in
    /// `GoalMeasure` (StrandAnalytics) so they are unit-tested and defined once.
    static func values(workouts: [WorkoutRow], weights: [(day: String, value: Double)],
                              stress: [(day: String, value: Double)],
                              days: [DailyMetric], hardSetsPerWeek: Double?,
                              now: Date) -> [CoachGoal.Kind: GoalMeasurement] {
        var result: [CoachGoal.Kind: GoalMeasurement] = [:]

        func within(_ windowDays: Int) -> [WorkoutRow] {
            let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400).timeIntervalSince1970
            return workouts.filter { Double($0.startTs) >= cutoff }
        }
        func latestDate(_ rows: [WorkoutRow]) -> Date? {
            rows.map(\.startTs).max().map { Date(timeIntervalSince1970: Double($0)) }
        }

        // Longest run inside a training block. Unwindowed this was "longest run ever": a half
        // marathon eleven months ago kept the goal permanently satisfied and progress could never fall.
        let runs = within(GoalMeasure.runWindowDays)
            .filter { $0.sport.lowercased().contains("run") && ($0.distanceM ?? 0) > 0 }
        if let longest = runs.max(by: { ($0.distanceM ?? 0) < ($1.distanceM ?? 0) }) {
            result[.run] = GoalMeasurement(value: (longest.distanceM ?? 0) / 1000,
                                           date: Date(timeIntervalSince1970: Double(longest.startTs)))
        }

        // Sessions per week over four weeks. An empty window is a real 0/week, not "unknown": the
        // goal IS measurable, it is simply not being served, and hiding that reads as no data.
        let consistencyRows = within(GoalMeasure.consistencyWindowDays)
        if let rate = GoalMeasure.perWeek(count: consistencyRows.count,
                                          overDays: GoalMeasure.consistencyWindowDays) {
            result[.consistency] = GoalMeasurement(value: rate, date: latestDate(consistencyRows))
        }

        // Strength as MINUTES PER WEEK — strength ACTIVITY TIME, the same choice WHOOP's "Strength
        // Activity Time" goal makes, and the honest measure for someone with no lifting log connected.
        // A goal about training VOLUME is the separate `.hardSets` kind below.
        //
        // Matched on the SOURCE first and the sport name only as a fallback. The name test alone —
        // `sport.contains("strength")` and three siblings — misses every session whose sport arrived
        // localized ("Krafttraining", "Musculation"), and those are exactly the sessions a German or
        // French user's strength goal is made of. A row from the Hevy or the lifting-import lane IS a
        // strength session whatever its label says, so the lane answers first and the name only has to
        // catch what reaches us from elsewhere (Apple Health, a strap, a manual entry).
        let strengthRows = consistencyRows.filter { row in
            switch WorkoutSource.classify(row.source) {
            case .hevy, .lifting:
                return true
            default:
                let sport = row.sport.lowercased()
                return sport.contains("strength") || sport.contains("bodybuilding")
                    || sport.contains("weight training") || sport.contains("lifting")
                    || sport.contains("kraft") || sport.contains("musculation")
                    || sport.contains("gewichtheben")
            }
        }
        if let minutes = GoalMeasure.minutesPerWeek(durationsS: strengthRows.compactMap(\.durationS),
                                                    overDays: GoalMeasure.consistencyWindowDays) {
            result[.strength] = GoalMeasurement(value: minutes, date: latestDate(strengthRows))
        }

        // Working sets per week — the unit strength training is actually prescribed in, available since
        // the Hevy lane landed. Dated from the newest strength row rather than the strength lane's own
        // sessions: the two are mirrors of each other, and a `WorkoutRow` is what every other measure
        // here is dated by.
        if let sets = hardSetsPerWeek {
            result[.hardSets] = GoalMeasurement(value: sets, date: latestDate(strengthRows))
        }

        let ascending = days.sorted { $0.day < $1.day }

        // Mean nightly sleep over a week — the same rhythm the weekly goal grid runs on.
        let sleepDays = Array(ascending.suffix(GoalMeasure.sleepWindowNights))
        if let mean = GoalMeasure.mean(sleepDays.compactMap { $0.totalSleepMin }) {
            let lastDay = sleepDays.last(where: { $0.totalSleepMin != nil })?.day
            result[.sleep] = GoalMeasurement(value: mean / 60, date: lastDay.flatMap(parseDay))
        }

        // Recovery / Charge and Stress as SMOOTHED trends, for the reason body weight already is: a
        // plain mean over the last seven ROWS can rest on two populated days and still hand back a
        // fully judgeable number, which is how "at risk" got raised off a single rough night. The EWMA
        // carries `isProvisional`, so a thin window now says so instead of pretending.
        //
        // A derived score, not a clinical quantity — it answers "is this moving the way I wanted",
        // nothing more, and it drives no gate.
        let scoreDays = Array(ascending.suffix(GoalMeasure.scoreTrendWindowDays))
        if let trend = GoalMeasure.smoothedTrend(scoreDays.compactMap { $0.recovery },
                                                 cfg: GoalMeasure.scoreTrend) {
            let lastDay = scoreDays.last(where: { $0.recovery != nil })?.day
            result[.recovery] = GoalMeasurement(value: trend.value, date: lastDay.flatMap(parseDay),
                                                isProvisional: !trend.isReliable)
        }

        // Stress, from the stored "stress" series (the same one the Stress screen reads). Direction is
        // carried by the goal's own baseline → target, so "lower is better" needs no special case here.
        let stressWindow = Array(stress.sorted { $0.day < $1.day }.suffix(GoalMeasure.scoreTrendWindowDays))
        if let trend = GoalMeasure.smoothedTrend(stressWindow.map(\.value), cfg: GoalMeasure.scoreTrend) {
            result[.stress] = GoalMeasurement(value: trend.value,
                                              date: stressWindow.last.flatMap { parseDay($0.day) },
                                              isProvisional: !trend.isReliable)
        }

        // Body weight as a SMOOTHED trend, not the last reading: 1-2 kg of daily water/food swing
        // otherwise flipped progress and the on-track/at-risk verdict with it. Already windowed and
        // ordered by the caller, so both this and the rate fit see the same series.
        let datedWeights = weights.compactMap { row in parseDay(row.day).map { (date: $0, value: row.value) } }
        if let trend = GoalMeasure.smoothedTrend(dated: datedWeights, cfg: GoalMeasure.weightTrend) {
            result[.weight] = GoalMeasurement(value: trend.value,
                                              date: weights.last.flatMap { parseDay($0.day) },
                                              isProvisional: !trend.isReliable)
        }
        return result
    }

    /// Weigh-ins inside the recency window, oldest → newest. Day-string comparison rather than date
    /// parsing: `series` rows are already "yyyy-MM-dd", which sorts and compares lexicographically.
    static func weightsWithin(_ windowDays: Int, weights: [(day: String, value: Double)],
                               now: Date) -> [(day: String, value: Double)] {
        let cutoff = StoreReader.localDayKey(now.addingTimeInterval(-Double(windowDays) * 86_400))
        return weights.filter { $0.day >= cutoff }.sorted { $0.day < $1.day }
    }

    static func parseDay(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.autoupdatingCurrent.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}
