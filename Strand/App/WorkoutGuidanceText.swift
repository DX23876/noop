import Foundation
import StrandAnalytics

enum WorkoutGuidanceText {
    static func title(_ kind: WorkoutGuidance.Phase.Kind) -> String {
        switch kind {
        case .warmup: String(localized: "Warm-up")
        case .work: String(localized: "Work interval")
        case .recovery: String(localized: "Recovery interval")
        case .cooldown: String(localized: "Cool-down")
        }
    }
}
