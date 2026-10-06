import Foundation

/// One fresh readout and one supplied clock determine each opt-in range warning.
/// Missing evidence, a pause, a changed range or a sampling gap resets the dwell, not the cooldown.
public struct WorkoutRangeAlertEngine: Sendable {
    public enum Side: String, Sendable { case below, above }
    private var side: Side?
    private var since: Double?
    private var lastTick: Double?
    private var lastCue: Double?
    private var previousRange: ClosedRange<Double>?

    public init() {}

    public mutating func update(value: Double?, range: ClosedRange<Double>?, now: Double,
                                paused: Bool) -> Side? {
        guard now.isFinite else { return nil }
        if range != previousRange || lastTick.map({ now < $0 || now - $0 > 5 }) == true {
            side = nil
            since = nil
        }
        previousRange = range
        lastTick = now
        guard !paused, let value, value.isFinite, let range,
              range.lowerBound.isFinite, range.upperBound.isFinite else {
            side = nil
            since = nil
            return nil
        }
        let next: Side? = value < range.lowerBound ? .below : value > range.upperBound ? .above : nil
        if next != side {
            side = next
            since = next == nil ? nil : now
        }
        guard let next, let since, now - since >= 10,
              lastCue.map({ now - $0 >= 60 }) ?? true else { return nil }
        lastCue = now
        return next
    }
}
