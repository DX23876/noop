import Foundation

/// Latest-state contract between the native iPhone set logger and its optional Watch companion.
/// It contains no workout history: the phone remains the single writer for exercises and sets.
public struct StrengthWorkoutCompanionState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case active, paused, finishing, completed }

    public static let contextKey = "strengthWorkoutState"
    public static let commandKey = "strengthWorkoutCommand"
    /// Stored on the watch-authored HealthKit workout so the phone can attach its physiological
    /// component to the set logger's stable canonical session after HealthKit synchronization.
    public static let healthKitSessionMetadataKey = "com.noop.training.session-id"

    public var sessionId: UUID
    public var revision: Int
    public var title: String
    public var exerciseTitle: String?
    public var setNumber: Int?
    public var setCount: Int
    public var startedAtTs: Int
    public var bpm: Int?
    public var heartRateZone: Int?
    public var restEndsAtTs: Int?
    public var phase: Phase

    public init(sessionId: UUID, revision: Int, title: String, exerciseTitle: String?,
                setNumber: Int?, setCount: Int, startedAtTs: Int, bpm: Int?,
                heartRateZone: Int? = nil, restEndsAtTs: Int?, phase: Phase) {
        self.sessionId = sessionId; self.revision = revision; self.title = title
        self.exerciseTitle = exerciseTitle; self.setNumber = setNumber; self.setCount = setCount
        self.startedAtTs = startedAtTs; self.bpm = bpm; self.heartRateZone = heartRateZone
        self.restEndsAtTs = restEndsAtTs
        self.phase = phase
    }
}

public struct StrengthWorkoutCompanionCommand: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case pause, resume, completeSet, finish }

    public var operationId: UUID
    public var sessionId: UUID
    public var expectedRevision: Int
    public var kind: Kind

    public init(operationId: UUID = UUID(), sessionId: UUID, expectedRevision: Int, kind: Kind) {
        self.operationId = operationId; self.sessionId = sessionId
        self.expectedRevision = expectedRevision; self.kind = kind
    }
}

public struct StrengthWorkoutCompanionTelemetry: Codable, Equatable, Sendable {
    public static let messageKey = "strengthWorkoutTelemetry"
    public var sessionId: UUID
    public var bpm: Int?
    public var sampleCount: Int
    public var recordedAtTs: Int

    public init(sessionId: UUID, bpm: Int?, sampleCount: Int, recordedAtTs: Int) {
        self.sessionId = sessionId; self.bpm = bpm; self.sampleCount = max(0, sampleCount)
        self.recordedAtTs = recordedAtTs
    }
}
