import Foundation

/// Durable progress for the on-device Health integration, independent of app/build versions.
public enum HealthSyncState {
    public struct Change: Equatable, Sendable {
        public let kind: String
        public let fromTs: Int
        public let toTs: Int
        public let revision: Int
    }

    public struct ExportVersion: Equatable, Sendable {
        public let id: String
        public let revision: Int
        public let needsSave: Bool
    }
}
