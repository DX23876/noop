import Foundation

/// Stable relationship between the current heart rate and a selected profile training zone.
public enum HRZoneTrainingState: Equatable, Sendable {
    case belowTarget
    case inTarget
    case aboveTarget
}

/// Pure state machine for haptic target-zone coaching.
///
/// The caller supplies the already-smoothed live heart rate and the profile's canonical zone set.
/// A state must remain unchanged for `stabilityDwellSec` before it is announced. Outside the target,
/// the same direction may be reminded periodically; the target state itself is announced only once.
public struct HRZoneTrainingEngine {

    public static let stabilityDwellSec = 8
    public static let reminderAfterSec = 30
    public static let maxSampleGapSec = 5

    public enum Cue: Equatable, Sendable {
        case increase
        case target
        case easeOff
    }

    private var configuredTargetZone: Int?
    private var configuredZoneSet: HRZoneSet?
    private var candidateState: HRZoneTrainingState?
    private var candidateSince: Int?
    private var lastCueAt: Int?
    private var lastSampleAt: Int?
    private(set) public var stableState: HRZoneTrainingState?

    public init() {}

    public mutating func update(now: Int, bpm: Int?, zoneSet: HRZoneSet,
                                targetZone: Int?, enabled: Bool) -> Cue? {
        guard enabled, let targetZone, (1...5).contains(targetZone), zoneSet.zones.count == 5 else {
            reset()
            return nil
        }

        if configuredTargetZone != targetZone || configuredZoneSet != zoneSet {
            reset()
            configuredTargetZone = targetZone
            configuredZoneSet = zoneSet
        }

        guard let bpm, bpm >= 30, bpm <= 220 else {
            candidateState = nil
            candidateSince = nil
            lastSampleAt = now
            if stableState != .inTarget { lastCueAt = now }
            return nil
        }

        if let lastSampleAt, now - lastSampleAt > Self.maxSampleGapSec {
            candidateState = nil
            candidateSince = nil
            if stableState != .inTarget { lastCueAt = now }
        }
        lastSampleAt = now

        let current = Self.state(forBPM: bpm, zoneSet: zoneSet, targetZone: targetZone)
        if current == stableState {
            candidateState = nil
            candidateSince = nil
            guard current != .inTarget,
                  let lastCueAt,
                  now - lastCueAt >= Self.reminderAfterSec else { return nil }
            self.lastCueAt = now
            return Self.cue(for: current)
        }

        if candidateState != current {
            candidateState = current
            candidateSince = now
            return nil
        }
        guard let candidateSince,
              now - candidateSince >= Self.stabilityDwellSec else { return nil }

        stableState = current
        candidateState = nil
        self.candidateSince = nil
        lastCueAt = now
        return Self.cue(for: current)
    }

    public mutating func reset() {
        configuredTargetZone = nil
        configuredZoneSet = nil
        candidateState = nil
        candidateSince = nil
        lastCueAt = nil
        lastSampleAt = nil
        stableState = nil
    }

    public static func state(forBPM bpm: Int, zoneSet: HRZoneSet,
                             targetZone: Int) -> HRZoneTrainingState {
        let currentZone = zoneSet.zoneNumber(forBPM: Double(bpm))
        if currentZone < targetZone { return .belowTarget }
        if currentZone > targetZone { return .aboveTarget }
        return .inTarget
    }

    private static func cue(for state: HRZoneTrainingState) -> Cue {
        switch state {
        case .belowTarget: return .increase
        case .inTarget: return .target
        case .aboveTarget: return .easeOff
        }
    }
}
