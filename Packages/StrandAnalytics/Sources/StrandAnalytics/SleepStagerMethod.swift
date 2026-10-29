import Foundation

extension SleepStager {
    /// The complete detection and staging pipeline. V3 keeps V2 phases and establishes onset before
    /// allowing the continuity bridge to absorb leading rest; V1 and V2 retain the original detector.
    public enum Method: String, Codable, CaseIterable, Sendable {
        case v1, v2, v3

        public var usesV2Stages: Bool { self != .v1 }

        /// Product preference migration, separate from the legacy Boolean analytics API. An explicit
        /// classic choice survives; the former default upgrades to V3. A new explicit V2 stays V2.
        public static func resolvedPreference(rawValue: String?, legacyV2: Bool?) -> Method {
            if let rawValue, let method = Method(rawValue: rawValue) { return method }
            return legacyV2 == false ? .v1 : .v3
        }
    }
}
