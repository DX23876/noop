import Foundation
import Combine
import StrandAnalytics
import StrandCore

// The Apple apps' side of the daily analysis. The engine itself is `DailyAnalysis` in StrandCore (Android plan B3
// step 5); here it keeps its long-standing name, becomes observable for SwiftUI, gets its strings in the wearer's
// language and is wired to `Repository` and `ProfileStore`.

/// The daily analysis as the Apple apps name it.
typealias IntelligenceEngine = DailyAnalysis

extension DailyAnalysis: ObservableObject {
    /// SwiftUI's change signal, fired by the core before each published property changes.
    public nonisolated var objectWillChange: ObservableObjectPublisher {
        observation.token({ ObservableObjectPublisher() }, onChange: { $0.send() })
    }

    /// The engine over the app's repository and profile, reporting to the app host.
    convenience init(repo: Repository, profile: ProfileStore, deviceId: String,
                     host: AnalysisHost = AppAnalysisHost()) {
        self.init(services: repo, profile: profile, deviceId: deviceId, host: host,
                  messages: Self.localizedMessage)
    }

    /// The text of an analysis message in the wearer's language.
    nonisolated static func localizedMessage(_ message: AnalysisMessage) -> String {
        switch message {
        case .noStore: return String(localized: "No on-device store yet.")
        case .noCurrentDayActivity: return String(localized: "No current-day activity data was available.")
        case .reanalysisUnfinished: return String(localized: "The reanalysis did not finish.")
        }
    }

    /// Mark the #547 heal as needing a re-run because a sync just dropped implausible (bad-clock) records.
    /// Called from `BLEManager.exitBackfilling` (no engine handle there); the next `runTimestampHealIfNeeded`
    /// honours it even after the one-shot `done` flag is set. The app host stores it in `UserDefaults`, where
    /// the engine reads it back.
    static func requestTimestampReheal() {
        UserDefaults.standard.set(true, forKey: timestampHealPendingKey)
    }
}

extension DailyAnalysis.DaySource {
    /// The badge shown on the By-Day card. Brand wording matches the rest of the app
    /// (SleepView "On-device"/"Whoop", Today "Apple Health"). NO em-dashes.
    var badge: String {
        switch self {
        case .computed:    return String(localized: "On-device")
        case .whoopImport: return "Whoop"
        case .appleHealth: return "Apple Health"
        }
    }
}

/// Experimental and off by default until the Healthspan card ships (spec S6).
enum HealthspanFeature {
    static let defaultsKey = "noopHealthspanAge"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }
}

extension Repository: AnalysisDataServices {}

extension ProfileStore: AnalysisProfileSource {
    func analyticsProfile() -> UserProfile { Repository.analyticsProfile(self) }
    func enteredVO2max() -> (day: String, value: Double)? { Repository.enteredVO2max() }
}
