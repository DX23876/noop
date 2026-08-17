import Foundation

public enum HRCeilingReminderMode: String, CaseIterable, Sendable {
    case standard
    case everyTwoSeconds
}

/// Pure state machine behind the configurable wrist warning for a heart-rate ceiling breach.
///
/// The caller supplies the already-smoothed live heart rate and resolved ceiling. This type owns no clock,
/// persistence, UI, or haptic transport, so identical timestamped traces always produce identical cues.
public struct HRCeilingAlertEngine {

    public static let recoveryDwellSec = 15
    public static let repeatAfterSec = 60
    public static let frequentRepeatAfterSec = 2
    public static let maxWarningsPerEpisode = 3
    public static let recoveryHysteresisBPM = 3.0
    public static let maxSampleGapSec = 5

    public enum Cue: Equatable, Sendable {
        case warning
        case recovered
    }

    private var recoverySince: Int?
    private var lastWarningAt: Int?
    private var lastSampleAt: Int?
    private(set) public var warningCount = 0

    public init() {}

    /// Whether the current continuous episode has already produced a warning and therefore owns the
    /// high-heart-rate haptic vocabulary over a concurrent Live Session cue.
    public var episodeActive: Bool { warningCount > 0 }

    /// Advance the state with a fresh smoothed reading. `nil` or a disabled gate pauses safely and clears
    /// incomplete recovery timers; disabling also ends any previous episode without a recovery buzz.
    public mutating func update(now: Int, bpm: Int?, ceilingBPM: Double, enabled: Bool,
                                reminderMode: HRCeilingReminderMode = .standard) -> Cue? {
        guard enabled, ceilingBPM >= 40, ceilingBPM <= 220 else {
            reset()
            return nil
        }
        guard let bpm, bpm >= 30, bpm <= 220 else {
            recoverySince = nil
            // Anchor both sample continuity and an active reminder episode at the observed gap.
            // Otherwise a reconnect could immediately mature time that elapsed without data.
            lastSampleAt = now
            if episodeActive { lastWarningAt = now }
            return nil
        }

        if let lastSampleAt, now - lastSampleAt > Self.maxSampleGapSec {
            recoverySince = nil
            // Do not let a long data gap mature a reminder while no heart rate was observed.
            if episodeActive { lastWarningAt = now }
        }
        lastSampleAt = now

        let value = Double(bpm)
        if !episodeActive {
            recoverySince = nil
            guard value >= ceilingBPM else { return nil }
            warningCount = 1
            lastWarningAt = now
            return .warning
        }

        let recoveryCeiling = ceilingBPM - Self.recoveryHysteresisBPM
        if value <= recoveryCeiling {
            if recoverySince == nil { recoverySince = now }
            if let since = recoverySince, now - since >= Self.recoveryDwellSec {
                reset()
                return .recovered
            }
            return nil
        }

        recoverySince = nil
        let mayRepeat = reminderMode == .everyTwoSeconds || warningCount < Self.maxWarningsPerEpisode
        let repeatInterval = reminderMode == .everyTwoSeconds
            ? Self.frequentRepeatAfterSec
            : Self.repeatAfterSec
        guard value >= ceilingBPM,
              mayRepeat,
              let lastWarningAt,
              now - lastWarningAt >= repeatInterval else { return nil }
        warningCount += 1
        self.lastWarningAt = now
        return .warning
    }

    public mutating func reset() {
        recoverySince = nil
        lastWarningAt = nil
        lastSampleAt = nil
        warningCount = 0
    }

    /// Resolve “above Zone N” through the supplied profile zone set. Zone N is the highest allowed zone,
    /// so its alert boundary is the inclusive lower edge of Zone N+1. Returns nil for invalid selections.
    public static func profileZoneCeiling(zoneSet: HRZoneSet, allowedZone: Int) -> Double? {
        guard (1...4).contains(allowedZone), zoneSet.zones.count == 5 else { return nil }
        return zoneSet.zones[allowedZone].lower
    }
}
