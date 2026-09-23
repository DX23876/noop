import Foundation
import CoachAnalysis

/// Ground truth, computed straight from the dataset with deliberately plain code that shares nothing with
/// `AnalysisExecutor` but day arithmetic. The oracle check (`Oracle`) then requires the executor's rendered
/// answer to agree with it, question by question — two independent readings of one semantics.
enum Reference {

    static func windowKeys(_ data: AnalysisDataset, days: Int) -> [String] {
        let today = DayKey.ordinal(data.today)!
        return (today - days + 1...today).map(DayKey.string)
    }

    static func values(_ data: AnalysisDataset, _ metric: String) -> [String: Double] {
        data.series[metric]?.values ?? [:]
    }

    static func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(xs.count) }

    /// Mean of the metric over the last `days` days (days without a value are skipped).
    static func windowMean(_ data: AnalysisDataset, _ metric: String, days: Int) -> Double {
        let v = values(data, metric)
        return mean(windowKeys(data, days: days).compactMap { v[$0] })
    }

    static func countBelow(_ data: AnalysisDataset, _ metric: String, threshold: Double, days: Int) -> Int {
        let v = values(data, metric)
        return windowKeys(data, days: days).filter { (v[$0] ?? .infinity) < threshold }.count
    }

    /// The single highest or lowest day, or nil when two days tie for it (the question would be ambiguous).
    static func extremeDay(_ data: AnalysisDataset, _ metric: String, days: Int, highest: Bool) -> String? {
        let v = values(data, metric)
        let rows = windowKeys(data, days: days).compactMap { key in v[key].map { (key, $0) } }
        guard let best = (highest ? rows.map(\.1).max() : rows.map(\.1).min()) else { return nil }
        let winners = rows.filter { $0.1 == best }
        return winners.count == 1 ? winners[0].0 : nil
    }

    /// Mean over days ago [0, 29] minus mean over days ago [30, 59].
    static func lastTwoMonthsDifference(_ data: AnalysisDataset, _ metric: String) -> Double {
        let v = values(data, metric)
        let keys = windowKeys(data, days: 60)
        let older = keys.prefix(30).compactMap { v[$0] }
        let recent = keys.suffix(30).compactMap { v[$0] }
        return mean(recent) - mean(older)
    }

    /// Mean of a nightly metric over the nights after anchor days in group A, minus the same for group B.
    static func nightAfterDifference(_ data: AnalysisDataset, _ metric: String, days: Int,
                                     inA: (String) -> Bool, inB: (String) -> Bool) -> Double {
        let v = values(data, metric)
        var a: [Double] = [], b: [Double] = []
        for key in windowKeys(data, days: days) {
            let a1 = inA(key), b1 = inB(key)
            guard a1 != b1, let next = DayKey.adding(1, to: key), let value = v[next] else { continue }
            if a1 { a.append(value) } else { b.append(value) }
        }
        return mean(a) - mean(b)
    }

    static func hasWorkout(_ data: AnalysisDataset, on key: String, _ hours: (Double) -> Bool) -> Bool {
        data.events.contains { $0.kind == "workout" && $0.day == key && hours($0.startHour) }
    }

    /// Least-squares slope of the metric against the day number, per 30 days.
    static func trendPer30(_ data: AnalysisDataset, _ metric: String, days: Int) -> Double {
        let v = values(data, metric)
        let points = windowKeys(data, days: days).compactMap { key in v[key].map { (Double(DayKey.ordinal(key)!), $0) } }
        let mx = mean(points.map(\.0)), my = mean(points.map(\.1))
        let sxy = points.reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let sxx = points.reduce(0) { $0 + ($1.0 - mx) * ($1.0 - mx) }
        return sxy / sxx * 30
    }

    /// Spearman's ρ between a daily metric on day D and a nightly metric the night after.
    static func spearmanNightAfter(_ data: AnalysisDataset, day dayMetric: String, night nightMetric: String,
                                   days: Int) -> Double {
        let x = values(data, dayMetric), y = values(data, nightMetric)
        let pairs = windowKeys(data, days: days).compactMap { key -> (Double, Double)? in
            guard let a = x[key], let next = DayKey.adding(1, to: key), let b = y[next] else { return nil }
            return (a, b)
        }
        let rx = averageRanks(pairs.map(\.0)), ry = averageRanks(pairs.map(\.1))
        let mx = mean(rx), my = mean(ry)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for i in rx.indices {
            sxy += (rx[i] - mx) * (ry[i] - my)
            sxx += (rx[i] - mx) * (rx[i] - mx)
            syy += (ry[i] - my) * (ry[i] - my)
        }
        return sxy / (sxx * syy).squareRoot()
    }

    private static func averageRanks(_ xs: [Double]) -> [Double] {
        // Rank of x = (number of values below) + (ties + 1) / 2.
        xs.map { x in
            let below = xs.filter { $0 < x }.count
            let equal = xs.filter { $0 == x }.count
            return Double(below) + Double(equal + 1) / 2
        }
    }
}
