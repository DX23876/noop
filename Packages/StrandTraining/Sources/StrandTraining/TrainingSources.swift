import Foundation

public struct TrainingSourceCapabilities: OptionSet, Codable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let workoutEnvelope = Self(rawValue: 1 << 0)
    public static let heartRate = Self(rawValue: 1 << 1)
    public static let route = Self(rawValue: 1 << 2)
    public static let distance = Self(rawValue: 1 << 3)
    public static let power = Self(rawValue: 1 << 4)
    public static let steps = Self(rawValue: 1 << 5)
    public static let energy = Self(rawValue: 1 << 6)
    public static let exercises = Self(rawValue: 1 << 7)
    public static let sets = Self(rawValue: 1 << 8)
    public static let setEffort = Self(rawValue: 1 << 9)
    public static let sessionEffort = Self(rawValue: 1 << 10)
}

public enum TrackerAttributionConfidence: String, Codable, CaseIterable, Sendable {
    case direct
    case deviceMetadata = "device_metadata"
    case sourceApplication = "source_application"
    case userSelected = "user_selected"
    case unknown
}

public struct SessionTrackerAttribution: Codable, Equatable, Sendable {
    public var trackerId: String?
    public var manufacturer: String?
    public var model: String?
    public var sourceApplication: String?
    public var sourceBundleId: String?
    public var confidence: TrackerAttributionConfidence
    public var capabilities: TrainingSourceCapabilities

    public init(trackerId: String? = nil, manufacturer: String? = nil,
                model: String? = nil, sourceApplication: String? = nil,
                sourceBundleId: String? = nil,
                confidence: TrackerAttributionConfidence,
                capabilities: TrainingSourceCapabilities) {
        self.trackerId = trackerId
        self.manufacturer = manufacturer
        self.model = model
        self.sourceApplication = sourceApplication
        self.sourceBundleId = sourceBundleId
        self.confidence = confidence
        self.capabilities = capabilities
    }
}
