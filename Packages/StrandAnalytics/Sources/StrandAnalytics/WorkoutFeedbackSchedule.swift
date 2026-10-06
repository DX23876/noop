import Foundation

/// Scheduling only: no invented split pace, and no catch-up speech on configuration changes/relaunch.
public struct WorkoutFeedbackSchedule: Sendable {
    public enum Event: Equatable, Sendable { case distance(Double), time }
    private var distanceMark = 0
    private var timeMark = 0
    private var lastCueSeconds = 0.0
    private var distanceInterval = 0.0
    private var timeInterval = 0.0

    public init() {}

    public mutating func prime(distance: Double, seconds: Double, everyMeters: Double, everySeconds: Double) {
        distanceInterval = everyMeters
        timeInterval = everySeconds
        distanceMark = Self.mark(distance, interval: everyMeters)
        timeMark = Self.mark(seconds, interval: everySeconds)
        lastCueSeconds = seconds
    }

    public mutating func update(distance: Double, seconds: Double, distanceFresh: Bool,
                                everyMeters: Double, everySeconds: Double, paused: Bool) -> Event? {
        guard seconds.isFinite, seconds >= 0, distance.isFinite, distance >= 0 else { return nil }
        if everyMeters != distanceInterval || everySeconds != timeInterval {
            prime(distance: distance, seconds: seconds, everyMeters: everyMeters, everySeconds: everySeconds)
            return nil
        }
        guard !paused else { return nil }
        let reached = Self.mark(distance, interval: everyMeters)
        if distanceFresh, everyMeters > 0, reached > distanceMark {
            distanceMark = reached
            timeMark = Self.mark(seconds, interval: everySeconds)
            lastCueSeconds = seconds
            return .distance(Double(reached) * everyMeters)
        }
        // The chosen time interval also serves as a fallback when GPS is not fresh.
        let timed = Self.mark(seconds, interval: everySeconds)
        if (everyMeters == 0 || !distanceFresh), timed > timeMark, seconds - lastCueSeconds >= everySeconds {
            timeMark = timed
            lastCueSeconds = seconds
            return .time
        }
        return nil
    }

    private static func mark(_ value: Double, interval: Double) -> Int {
        guard value.isFinite, value >= 0, interval.isFinite, interval > 0,
              value / interval < Double(Int.max) else { return 0 }
        return Int(value / interval)
    }
}
