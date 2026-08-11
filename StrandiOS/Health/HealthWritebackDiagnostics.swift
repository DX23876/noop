#if os(iOS)
import Foundation
import StrandImport

/// One locally-visible outcome from the last NOOP → Health write-back. Counts and reasons only: no
/// physiological values are copied into diagnostics or sent anywhere.
struct HealthWritebackReport: Equatable {
    struct Entry: Identifiable, Equatable {
        let id: String
        let count: Int
        let authorizedTypes: Int
        let totalTypes: Int
        let detail: String

        var summary: String {
            [String(count), detail, "\(authorizedTypes)/\(totalTypes)"].joined(separator: " · ")
        }
    }
    let completedAt: Date
    let entries: [Entry]
}

/// Persisted because the user must leave NOOP to inspect Apple's graph. Cleanup can therefore restore
/// the normal samples even after iOS kills and relaunches the app in between.
struct HealthHeartRateExperiment: Codable, Equatable {
    enum Result: String, Codable {
        case intervalVisible
        case pointVisible
        case bothVisible
        case neitherVisible
    }
    let id: String
    let startedAt: Date
    let intervalWindow: HealthWriteback.HeartRateExperimentWindow
    let pointWindow: HealthWriteback.HeartRateExperimentWindow
    let intervalExternalOverlap: Int
    let pointExternalOverlap: Int
}
#endif
