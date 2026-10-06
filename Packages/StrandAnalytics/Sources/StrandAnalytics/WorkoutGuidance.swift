import Foundation

/// A copied session plan and its recorded transitions. It never changes workout scoring or auto-ends capture.
public struct WorkoutGuidance: Codable, Equatable, Sendable {
    public struct Phase: Codable, Equatable, Sendable, Identifiable {
        public enum Kind: String, Codable, Sendable { case warmup, work, recovery, cooldown }
        public let id: UUID
        public var kind: Kind
        public var seconds: Double?
        public var meters: Double?

        public init(kind: Kind, seconds: Double? = nil, meters: Double? = nil) {
            id = UUID(); self.kind = kind; self.seconds = seconds; self.meters = meters
        }

        public var isValid: Bool {
            if let seconds { return meters == nil && seconds.isFinite && (1...86400).contains(seconds) }
            if let meters { return meters.isFinite && (10...100000).contains(meters) }
            return false
        }
    }

    public struct Transition: Codable, Equatable, Sendable {
        public let phaseIndex: Int
        public let activeSeconds: Double
        public let recordedMeters: Double
        public let skipped: Bool
    }

    public struct RecordedPhase: Equatable, Sendable, Identifiable {
        public let phase: Phase
        public let seconds: Double
        public let meters: Double
        public let skipped: Bool
        public let inProgress: Bool
        public var id: UUID { phase.id }
    }

    public private(set) var phases: [Phase]
    public private(set) var index = 0
    public private(set) var phaseStartedSeconds = 0.0
    public private(set) var phaseStartedMeters = 0.0
    public private(set) var transitions: [Transition] = []
    public var isComplete: Bool { index == phases.count }
    public var current: Phase? { phases.indices.contains(index) ? phases[index] : nil }
    public var requiresGPS: Bool { phases.contains { $0.meters != nil } }
    public var isValid: Bool {
        !phases.isEmpty && phases.count <= 64 && phases.allSatisfy(\.isValid)
            && Set(phases.map(\.id)).count == phases.count && (0...phases.count).contains(index)
            && phaseStartedSeconds.isFinite && phaseStartedSeconds >= 0
            && phaseStartedMeters.isFinite && phaseStartedMeters >= 0
            && transitions.count == index
            && transitions.enumerated().allSatisfy { offset, transition in
                transition.phaseIndex == offset
                    && transition.activeSeconds.isFinite && transition.activeSeconds >= 0
                    && transition.recordedMeters.isFinite && transition.recordedMeters >= 0
                    && (offset == 0 || (transition.activeSeconds >= transitions[offset - 1].activeSeconds
                        && transition.recordedMeters >= transitions[offset - 1].recordedMeters))
            }
            && phaseStartedSeconds == (transitions.last?.activeSeconds ?? 0)
            && phaseStartedMeters == (transitions.last?.recordedMeters ?? 0)
    }

    public init(phases: [Phase]) { self.phases = phases }

    /// Active time advances timed phases. Missing GPS stalls distance phases, never converts them to time.
    @discardableResult
    public mutating func update(seconds: Double, meters: Double, distanceFresh: Bool, paused: Bool) -> Bool {
        guard isValid, !paused, seconds.isFinite, seconds >= phaseStartedSeconds,
              meters.isFinite, meters >= phaseStartedMeters else { return false }
        let originalIndex = index
        while let phase = current {
            if let duration = phase.seconds, seconds - phaseStartedSeconds >= duration {
                advance(seconds: phaseStartedSeconds + duration, meters: meters, skipped: false)
            } else if let length = phase.meters, distanceFresh, meters - phaseStartedMeters >= length {
                // Only measured distance is counted; no crossing time is fabricated across a gap.
                advance(seconds: seconds, meters: meters, skipped: false)
            } else { break }
        }
        return index != originalIndex
    }

    @discardableResult
    public mutating func skip(seconds: Double, meters: Double) -> Bool {
        guard isValid, current != nil, seconds.isFinite, seconds >= phaseStartedSeconds,
              meters.isFinite, meters >= phaseStartedMeters else { return false }
        advance(seconds: seconds, meters: meters, skipped: true)
        return true
    }

    public func remaining(seconds: Double, meters: Double) -> Double? {
        guard let current, seconds.isFinite, meters.isFinite else { return nil }
        if let duration = current.seconds { return max(0, duration - (seconds - phaseStartedSeconds)) }
        return current.meters.map { max(0, $0 - (meters - phaseStartedMeters)) }
    }

    /// Actual phase history, not the future template targets. Zero-duration skips remain explicit.
    public func recordedPhases(seconds: Double, meters: Double) -> [RecordedPhase] {
        guard isValid, seconds.isFinite, seconds >= phaseStartedSeconds,
              meters.isFinite, meters >= phaseStartedMeters else { return [] }
        var result: [RecordedPhase] = []
        var previousSeconds = 0.0
        var previousMeters = 0.0
        for transition in transitions {
            result.append(RecordedPhase(phase: phases[transition.phaseIndex],
                seconds: transition.activeSeconds - previousSeconds, meters: transition.recordedMeters - previousMeters,
                skipped: transition.skipped, inProgress: false))
            previousSeconds = transition.activeSeconds
            previousMeters = transition.recordedMeters
        }
        if let current, seconds > phaseStartedSeconds {
            result.append(RecordedPhase(phase: current, seconds: seconds - phaseStartedSeconds,
                meters: meters - phaseStartedMeters, skipped: false, inProgress: true))
        }
        return result
    }

    /// Optimistic guard: a phase transition during editing must not redirect an edit onto the new phase.
    @discardableResult
    public mutating func replaceUpcoming(expectedCurrentID: UUID, phases future: [Phase]) -> Bool {
        guard isValid, current?.id == expectedCurrentID, future.allSatisfy(\.isValid), index + 1 + future.count <= 64 else { return false }
        let replacement = Array(phases.prefix(index + 1)) + future
        guard Set(replacement.map(\.id)).count == replacement.count else { return false }
        phases = replacement
        return true
    }

    private mutating func advance(seconds: Double, meters: Double, skipped: Bool) {
        transitions.append(Transition(phaseIndex: index, activeSeconds: seconds, recordedMeters: meters, skipped: skipped))
        index += 1
        phaseStartedSeconds = seconds
        phaseStartedMeters = meters
    }
}
