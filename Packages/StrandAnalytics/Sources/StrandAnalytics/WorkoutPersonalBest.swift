import Foundation

/// Comparable measured distance splits, never an imported average or a best inferred from heart rate.
public enum WorkoutPersonalBest {
    public struct Candidate: Equatable, Sendable {
        public let sport: String
        public let meters: Double
        public let seconds: Double

        public init(sport: String, meters: Double, seconds: Double) {
            self.sport = sport; self.meters = meters; self.seconds = seconds
        }

        public var isValid: Bool {
            !sport.isEmpty && (meters == 1000 || meters == 1609.344) && seconds.isFinite && seconds > 0
        }
    }

    public struct Result: Equatable, Sendable {
        public let current: Candidate
        public let previous: Candidate
    }

    public static func candidate(timeline: WorkoutRecordingTimeline, sport: String) -> Candidate? {
        guard timeline.isValid, timeline.hasRouteGap != true, timeline.pauses?.isEmpty != false,
              let meters = timeline.splitLengthM, meters == 1000 || meters == 1609.344,
              timeline.splits.allSatisfy({ !$0.interrupted && !$0.partial }) else { return nil }
        let seconds = timeline.splits.filter { $0.distanceM == meters && $0.duration > 0 }.map(\.duration).min()
        return seconds.map { Candidate(sport: sport, meters: meters, seconds: $0) }.flatMap { $0.isValid ? $0 : nil }
    }

    public static func comparable(_ first: Candidate, _ second: Candidate) -> Bool {
        first.isValid && second.isValid && first.sport == second.sport && first.meters == second.meters
    }

    /// The first qualifying recording is a baseline, not a claimed personal best.
    public static func improvement(current: Candidate, previous: Candidate?) -> Result? {
        guard let previous, comparable(current, previous), current.seconds.rounded() < previous.seconds.rounded() else { return nil }
        return Result(current: current, previous: previous)
    }
}
