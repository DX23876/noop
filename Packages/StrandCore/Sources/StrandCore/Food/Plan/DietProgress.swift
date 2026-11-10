import Foundation
import StrandAnalytics

/// How far along the way to the goal weight the wearer is (owner, 2026-11-10), read from the smoothed weight trend,
/// never from one weigh-in, so a heavy morning does not knock a stage off. The way has five stages: the start,
/// a quarter, half, three quarters and the goal. Holding has no way; it says whether the trend sits within a
/// kilogram of the starting weight, and since when.
public enum DietProgress {
    public enum Stage: String, CaseIterable, Sendable, Codable {
        case start, quarter, half, threeQuarter, goal

        /// The share of the way at which the stage is reached.
        public var threshold: Double {
            switch self {
            case .start: 0
            case .quarter: 0.25
            case .half: 0.5
            case .threeQuarter: 0.75
            case .goal: 1
            }
        }
    }

    public struct Way: Equatable, Sendable {
        public var goal: DietPlan.Goal
        public var startKg: Double
        public var trendKg: Double
        public var goalKg: Double
        /// 0 to 1 of the way done.
        public var fraction: Double
        public var stage: Stage
        /// Kilograms moved toward the goal, and still to go (both never negative).
        public var doneKg: Double
        public var leftKg: Double
    }

    public struct Hold: Equatable, Sendable {
        public var startKg: Double
        public var trendKg: Double
        public var inRange: Bool
        /// Whole weeks the trend has stayed within range up to today; zero when out of range.
        public var weeksInRange: Int
    }

    public enum Progress: Equatable, Sendable {
        case way(Way)
        case hold(Hold)
    }

    /// Kilograms either side of the starting weight that still count as holding.
    public static let holdBandKg: Double = 1

    /// Nil without weigh-ins, or for losing or gaining without a goal weight (there is no way to draw then).
    public static func resolve(plan: DietPlan, goalWeightKg: Double?, weighIns: [(day: String, kg: Double)]) -> Progress? {
        let samples = weighIns.compactMap { w in WeightSeries.date(forDay: w.day).map { (date: $0, value: w.kg) } }
            .filter { $0.value.isFinite && $0.value > 0 }.sorted { $0.date < $1.date }
        let smoothed = WeightTrendSummary.smoothedSeries(samples)
        guard let trend = smoothed.last?.value else { return nil }
        let start = plan.startWeightKg
        switch plan.goal {
        case .maintain:
            let inRange = abs(trend - start) <= holdBandKg
            var weeks = 0
            if inRange, let last = smoothed.last?.date {
                let outside = smoothed.last { abs($0.value - start) > holdBandKg }?.date
                let since = outside ?? smoothed.first?.date ?? last
                weeks = Int(last.timeIntervalSince(since) / (7 * 86_400))
            }
            return .hold(Hold(startKg: start, trendKg: trend, inRange: inRange, weeksInRange: weeks))
        case .lose, .gain:
            guard let goal = goalWeightKg, abs(goal - start) > 0.1 else { return nil }
            let direction: Double = plan.goal == .lose ? -1 : 1
            let total = (goal - start) * direction
            guard total > 0 else { return nil }
            let done = ((trend - start) * direction).clamped(0, total)
            let fraction = done / total
            let stage = Stage.allCases.last { fraction + 1e-9 >= $0.threshold } ?? .start
            return .way(Way(goal: plan.goal, startKg: start, trendKg: trend, goalKg: goal, fraction: fraction,
                            stage: stage, doneKg: done, leftKg: max(0, total - done)))
        }
    }
}
