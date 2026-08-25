import Foundation

/// One time-aligned WHOOP/Apple Watch comparison window. Apple is a reference label only; fitting
/// produces a bounded multiplier for WHOOP and never creates a replacement daily energy source.
public struct EnergyCalibrationPoint: Equatable, Sendable {
    public let timestamp: Int
    public let whoopKcal: Double
    public let appleWatchKcal: Double
    public let overlapQuality: Double

    public init(timestamp: Int, whoopKcal: Double, appleWatchKcal: Double,
                overlapQuality: Double) {
        self.timestamp = timestamp
        self.whoopKcal = whoopKcal
        self.appleWatchKcal = appleWatchKcal
        self.overlapQuality = overlapQuality
    }
}

public struct EnergyCalibrationFit: Equatable, Sendable {
    public static let modelVersion = "watch-reference-v1"
    public let factor: Double
    public let sampleDays: Int
    public let sampleBuckets: Int
    public let coefficientOfVariation: Double
}

/// Conservative robust calibration. It intentionally refuses a fit more often than it accepts one:
/// an occasional watch should improve WHOOP only after broad, stable overlap, never teach the model
/// from one unusual workout or from partial Apple Health coverage.
public enum EnergyCalibrationEngine {
    public static let minimumDays = 7
    public static let minimumBuckets = 84
    public static let minimumOverlapQuality = 0.70
    public static let factorRange = 0.80...1.20
    public static let maximumCV = 0.20

    public static func fit(points: [EnergyCalibrationPoint], calendar: Calendar = .current)
        -> EnergyCalibrationFit? {
        let usable = points.filter {
            $0.whoopKcal.isFinite && $0.appleWatchKcal.isFinite
                && $0.overlapQuality.isFinite && $0.overlapQuality >= minimumOverlapQuality
                && $0.whoopKcal >= 0.2 && $0.appleWatchKcal >= 0.2
                && $0.whoopKcal <= 100 && $0.appleWatchKcal <= 100
        }
        guard usable.count >= minimumBuckets else { return nil }
        let days = Set(usable.map {
            calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.timestamp)))
        })
        guard days.count >= minimumDays else { return nil }

        let rawRatios = usable.map { $0.appleWatchKcal / $0.whoopKcal }.sorted()
        let centre = median(rawRatios)
        let deviations = rawRatios.map { abs($0 - centre) }.sorted()
        let mad = median(deviations)
        // A 3-MAD trim removes sensor glitches and workout spikes while keeping a zero-MAD stable fit.
        let trimmed = mad > 0
            ? rawRatios.filter { abs($0 - centre) <= 3 * mad }
            : rawRatios.filter { abs($0 - centre) <= 0.001 }
        guard trimmed.count >= minimumBuckets else { return nil }
        let factor = min(factorRange.upperBound, max(factorRange.lowerBound, median(trimmed)))
        let mean = trimmed.reduce(0, +) / Double(trimmed.count)
        let variance = trimmed.reduce(0) { $0 + pow($1 - mean, 2) } / Double(trimmed.count)
        let cv = mean > 0 ? sqrt(variance) / mean : .infinity
        guard cv.isFinite, cv <= maximumCV else { return nil }
        return .init(factor: factor, sampleDays: days.count, sampleBuckets: trimmed.count,
                     coefficientOfVariation: cv)
    }

    public static func apply(_ rawWhoopKcal: Double, fit: EnergyCalibrationFit?) -> Double {
        guard rawWhoopKcal.isFinite, rawWhoopKcal >= 0 else { return 0 }
        guard let fit, factorRange.contains(fit.factor) else { return rawWhoopKcal }
        return rawWhoopKcal * fit.factor
    }

    private static func median(_ sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return .nan }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
