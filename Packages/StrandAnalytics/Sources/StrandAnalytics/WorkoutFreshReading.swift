import Foundation

/// Shared freshness gate for repeated workout readouts and warnings, driven by the caller's clock.
public enum WorkoutFreshReading {
    public static func resolve(_ value: Double?, observedAt: Double?, now: Double, paused: Bool,
                               maxAge: Double = 5) -> Double? {
        guard !paused, let value, value.isFinite, let observedAt, observedAt.isFinite, now.isFinite,
              now >= observedAt, now - observedAt <= maxAge else { return nil }
        return value
    }
}
