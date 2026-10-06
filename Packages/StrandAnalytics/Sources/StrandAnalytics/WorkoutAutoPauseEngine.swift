import Foundation

/// Conservative opt-in GPS-only pause detection. Manual pauses never resume automatically.
/// No trustworthy motion (including a GPS gap) means no decision, not a presumed stop.
public struct WorkoutAutoPauseEngine: Sendable {
    public enum Action: Equatable, Sendable { case pause, resume }
    private var candidate: Action?
    private var since: Double?
    private var lastEvidence: Double?

    public init() {}

    public mutating func reset() { candidate = nil; since = nil; lastEvidence = nil }

    public mutating func update(now: Double, stationary: Bool?, moving: Bool,
                                enabled: Bool, paused: Bool, automaticallyPaused: Bool) -> Action? {
        guard now.isFinite, enabled, !paused || automaticallyPaused else { reset(); return nil }
        if lastEvidence.map({ now <= $0 || now - $0 > 5 }) == true { candidate = nil; since = nil }
        lastEvidence = now
        let next: Action? = paused ? (moving ? .resume : nil) : (stationary == true ? .pause : nil)
        if candidate != next { candidate = next; since = next == nil ? nil : now }
        guard let next, let since, now - since >= (next == .pause ? 5 : 3) else { return nil }
        reset()
        return next
    }
}
