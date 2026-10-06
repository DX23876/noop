import Foundation

/// A goal-time comparison against measured distance and active time, never an estimate from heart rate.
public struct WorkoutPacer: Codable, Equatable, Sendable {
    public let meters: Double
    public let seconds: Double
    public var isValid: Bool { meters.isFinite && (100...200000).contains(meters) && seconds.isFinite && (60...86400).contains(seconds) }

    public init(meters: Double, seconds: Double) { self.meters = meters; self.seconds = seconds }

    /// Positive means ahead. Unknown route movement invalidates the comparison, including after a gap.
    public func aheadSeconds(distanceM: Double, activeSeconds: Double, fresh: Bool, uninterrupted: Bool) -> Double? {
        guard isValid, fresh, uninterrupted, distanceM.isFinite, distanceM >= 0,
              activeSeconds.isFinite, activeSeconds >= 5 else { return nil }
        return min(distanceM, meters) / meters * seconds - activeSeconds
    }
}
