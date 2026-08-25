import Foundation

/// One dated input for the long-horizon energy-balance estimate. Intake and weight are optional so
/// callers can pass their two sparse series without inventing values for missing days.
public struct AdaptiveExpenditureDay: Equatable, Sendable {
    public let date: Date
    public let caloriesIn: Double?
    public let weightKg: Double?

    public init(date: Date, caloriesIn: Double? = nil, weightKg: Double? = nil) {
        self.date = date
        self.caloriesIn = caloriesIn
        self.weightKg = weightKg
    }
}

public enum AdaptiveExpenditureConfidence: String, Equatable, Sendable {
    case building
    case moderate
    case high
}

/// A separate, retrospective estimate of average daily expenditure. This is intentionally not an
/// `EnergyEngine` input: an energy-balance model must never silently rewrite a wearable's daily burn.
public struct AdaptiveExpenditureEstimate: Equatable, Sendable {
    public let estimatedDailyKcal: Double
    public let lowerBoundKcal: Double
    public let upperBoundKcal: Double
    public let averageCaloriesIn: Double
    public let weightChangeKgPerDay: Double
    public let intakeDays: Int
    public let weightReadings: Int
    public let windowDays: Int
    public let intakeCoverage: Double
    public let confidence: AdaptiveExpenditureConfidence

    public init(estimatedDailyKcal: Double, lowerBoundKcal: Double, upperBoundKcal: Double,
                averageCaloriesIn: Double, weightChangeKgPerDay: Double, intakeDays: Int,
                weightReadings: Int, windowDays: Int, intakeCoverage: Double,
                confidence: AdaptiveExpenditureConfidence) {
        self.estimatedDailyKcal = estimatedDailyKcal
        self.lowerBoundKcal = lowerBoundKcal
        self.upperBoundKcal = upperBoundKcal
        self.averageCaloriesIn = averageCaloriesIn
        self.weightChangeKgPerDay = weightChangeKgPerDay
        self.intakeDays = intakeDays
        self.weightReadings = weightReadings
        self.windowDays = windowDays
        self.intakeCoverage = intakeCoverage
        self.confidence = confidence
    }
}

/// Retrospective TDEE from logged intake and weight trend.
///
/// Energy balance is `expenditure = intake - stored-energy change`. The conventional 7,700 kcal/kg
/// conversion is useful over weeks, but hydration and incomplete food logs make it unsuitable for a
/// daily headline. Consequently this engine requires three weeks, rejects sparse histories, uses a
/// robust slope through the app's existing smoothed weight series, and always returns an interval.
public enum AdaptiveExpenditureEngine {
    public static let energyPerKgKcal = 7_700.0
    public static let minimumWindowDays = 21
    public static let maximumWindowDays = 42
    public static let minimumIntakeDays = 14
    public static let minimumWeightReadings = 6
    public static let minimumIntakeCoverage = 0.70

    public static func estimate(
        days: [AdaptiveExpenditureDay],
        asOf: Date = Date(),
        calendar: Calendar = .current
    ) -> AdaptiveExpenditureEstimate? {
        let cutoff = calendar.startOfDay(for: asOf)
        let oldest = calendar.date(byAdding: .day, value: -maximumWindowDays, to: cutoff) ?? cutoff
        let eligible = days.filter { $0.date >= oldest && $0.date < cutoff }

        // Imports can contain repeated samples for a calendar day. Use the latest timestamp for
        // each metric independently so duplicates cannot inflate coverage or confidence, while
        // still allowing intake and weight to arrive as separate rows.
        var intakeByDay: [Date: (timestamp: Date, value: Double)] = [:]
        var weightByDay: [Date: (timestamp: Date, value: Double)] = [:]
        for point in eligible {
            let day = calendar.startOfDay(for: point.date)
            if let value = point.caloriesIn, value.isFinite, (800...8_000).contains(value),
               intakeByDay[day] == nil || point.date >= intakeByDay[day]!.timestamp {
                intakeByDay[day] = (point.date, value)
            }
            if let value = point.weightKg, value.isFinite,
               GoalMeasure.isPlausible(value, cfg: GoalMeasure.weightTrend),
               weightByDay[day] == nil || point.date >= weightByDay[day]!.timestamp {
                weightByDay[day] = (point.date, value)
            }
        }
        let intake = intakeByDay.map { (date: $0.key, value: $0.value.value) }
        let weights = weightByDay.map { (date: $0.key, value: $0.value.value) }
        guard intake.count >= minimumIntakeDays, weights.count >= minimumWeightReadings,
              let firstIntake = intake.map(\.date).min(), let lastIntake = intake.map(\.date).max(),
              let firstWeight = weights.map(\.date).min(), let lastWeight = weights.map(\.date).max()
        else { return nil }

        let start = max(firstIntake, firstWeight)
        let end = min(lastIntake, lastWeight)
        let span = max(0, calendar.dateComponents([.day], from: start, to: end).day ?? 0)
        let windowDays = span + 1
        guard windowDays >= minimumWindowDays else { return nil }

        let windowIntake = intake.filter { $0.date >= start && $0.date <= end }
        let windowWeights = weights.filter { $0.date >= start && $0.date <= end }
            .sorted { $0.date < $1.date }
        let coverage = Double(Set(windowIntake.map(\.date)).count) / Double(windowDays)
        guard windowIntake.count >= minimumIntakeDays,
              windowWeights.count >= minimumWeightReadings,
              coverage >= minimumIntakeCoverage else { return nil }

        let smoothed = WeightTrendSummary.smoothedSeries(windowWeights)
        // The robust pair-slope should retain the magnitude of a sustained change. Using the EWMA
        // centres directly would damp the first several weeks through cold-start lag. Instead the
        // shared smooth trend acts as an outlier gate, then Theil-Sen fits the accepted raw readings.
        let trendWeights = zip(windowWeights, smoothed).compactMap { raw, centre in
            abs(raw.value - centre.value) <= max(3, centre.value * 0.04) ? raw : nil
        }
        let slopes = pairSlopes(trendWeights, calendar: calendar)
        guard let weightSlope = median(slopes), weightSlope.isFinite else { return nil }

        let intakeValues = windowIntake.map(\.value).sorted()
        let trimmedIntake = trimmedMean(intakeValues)
        let estimate = trimmedIntake - weightSlope * energyPerKgKcal
        guard estimate.isFinite, (1_000...6_000).contains(estimate) else { return nil }

        let intakeSEM = standardDeviation(intakeValues) / sqrt(Double(intakeValues.count))
        let slopeMAD = median(slopes.map { abs($0 - weightSlope) }) ?? 0
        let robustSlopeSE = 1.4826 * slopeMAD / sqrt(Double(max(1, slopes.count)))
        let missingPenalty = (1 - min(1, coverage)) * 300
        let halfWidth = min(1_200, max(150,
            1.96 * hypot(intakeSEM, robustSlopeSE * energyPerKgKcal) + missingPenalty))
        let confidence: AdaptiveExpenditureConfidence
        if windowDays >= 28, coverage >= 0.85, windowWeights.count >= 10, halfWidth <= 350 {
            confidence = .high
        } else if coverage >= 0.78, halfWidth <= 600 {
            confidence = .moderate
        } else {
            confidence = .building
        }

        return AdaptiveExpenditureEstimate(
            estimatedDailyKcal: estimate,
            lowerBoundKcal: max(1_000, estimate - halfWidth),
            upperBoundKcal: min(6_000, estimate + halfWidth),
            averageCaloriesIn: trimmedIntake,
            weightChangeKgPerDay: weightSlope,
            intakeDays: windowIntake.count,
            weightReadings: windowWeights.count,
            windowDays: windowDays,
            intakeCoverage: coverage,
            confidence: confidence)
    }

    /// Theil-Sen slopes across pairs at least seven days apart. Requiring separation prevents normal
    /// day-to-day water changes from becoming enormous kcal/day corrections.
    private static func pairSlopes(
        _ points: [(date: Date, value: Double)], calendar: Calendar
    ) -> [Double] {
        guard points.count >= 2 else { return [] }
        var result: [Double] = []
        for i in 0..<(points.count - 1) {
            for j in (i + 1)..<points.count {
                let elapsed = calendar.dateComponents([.day], from: points[i].date,
                                                      to: points[j].date).day ?? 0
                guard elapsed >= 7 else { continue }
                result.append((points[j].value - points[i].value) / Double(elapsed))
            }
        }
        return result
    }

    private static func trimmedMean(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let trim = sorted.count >= 20 ? sorted.count / 10 : 0
        let kept = sorted.dropFirst(trim).dropLast(trim)
        return kept.reduce(0, +) / Double(kept.count)
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            / Double(values.count - 1)
        return sqrt(max(0, variance))
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
