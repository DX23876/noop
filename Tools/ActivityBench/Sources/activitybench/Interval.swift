import Foundation
import StrandAnalytics

/// What one suggestion or one entry contributed, tagged with the week it started in. The bench matches
/// over the whole range first (a suggestion can cross midnight) and only then splits by week, so the
/// interval resamples the same matches the point estimate counts.
struct Outcome: Equatable {
    enum What: Equatable {
        case suggestion(found: ActivityDetectionScore.Kind?)
        case entry(ActivityDetectionScore.Kind)
        case wornDay
    }
    let week: Int
    let what: What
}

/// Per-week tallies, the unit the bootstrap resamples: days inside a week are not independent (one
/// habit, one strap fit), weeks roughly are.
struct WeekTally: Equatable {
    var hits: [ActivityDetectionScore.Kind: Int] = [:]
    var entries: [ActivityDetectionScore.Kind: Int] = [:]
    var unlabelled = 0
    var wornDays = 0

    static func byWeek(_ outcomes: [Outcome]) -> [WeekTally] {
        var weeks: [Int: WeekTally] = [:]
        for o in outcomes {
            switch o.what {
            case .suggestion(let found):
                if let found { weeks[o.week, default: .init()].hits[found, default: 0] += 1 }
                else { weeks[o.week, default: .init()].unlabelled += 1 }
            case .entry(let kind): weeks[o.week, default: .init()].entries[kind, default: 0] += 1
            case .wornDay: weeks[o.week, default: .init()].wornDays += 1
            }
        }
        return weeks.keys.sorted().map { weeks[$0]! }
    }

    static func sum(_ weeks: [WeekTally]) -> WeekTally {
        weeks.reduce(into: WeekTally()) { acc, w in
            acc.unlabelled += w.unlabelled
            acc.wornDays += w.wornDays
            for (k, v) in w.hits { acc.hits[k, default: 0] += v }
            for (k, v) in w.entries { acc.entries[k, default: 0] += v }
        }
    }
}

/// A 95 % percentile interval from resampling whole weeks with replacement. Seeded, so a rerun prints
/// the same interval. Returns nil when there are fewer than two weeks or the statistic is undefined in
/// every resample.
enum WeekBootstrap {
    static func interval(_ weeks: [WeekTally], replicates: Int = 2_000, seed: UInt64 = 1,
                         statistic: (WeekTally) -> Double?) -> (low: Double, high: Double)? {
        guard weeks.count >= 2 else { return nil }
        var rng = SplitMix64(seed: seed)
        var values: [Double] = []
        values.reserveCapacity(replicates)
        for _ in 0..<replicates {
            var drawn: [WeekTally] = []
            drawn.reserveCapacity(weeks.count)
            for _ in weeks.indices { drawn.append(weeks[Int(rng.next() % UInt64(weeks.count))]) }
            if let v = statistic(WeekTally.sum(drawn)) { values.append(v) }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        func at(_ q: Double) -> Double { values[min(values.count - 1, Int(q * Double(values.count)))] }
        return (at(0.025), at(0.975))
    }
}

struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension Array {
    /// The first index whose element satisfies `isAtOrAfter`, for an array sorted so that the predicate is
    /// false then true. Binary search, so a day's slice of two months of minutes is cheap.
    func partitionIndex(_ isAtOrAfter: (Element) -> Bool) -> Int {
        var lo = 0, hi = count
        while lo < hi {
            let mid = (lo + hi) / 2
            if isAtOrAfter(self[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}
