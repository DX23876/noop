import Foundation
import StrandAnalytics

/// What the Basiskarte (docs/noop-feature-spec.md §2) shows: either the real computed readiness
/// statement, or — for the three ActivityStatus exception states — a fixed override. Basiskarte and
/// coach must never disagree, so the `.active` case passes `ReadinessEngine.Readiness` through verbatim
/// rather than recomputing anything.
struct BaseCardStatement: Equatable {
    let headline: String
    let summary: String
    /// True when this is one of the three fixed exception statements, not the computed readiness text.
    let isOverride: Bool

    static func current(status: ActivityStatus, readiness: ReadinessEngine.Readiness) -> BaseCardStatement {
        switch status.state {
        case .active:
            return BaseCardStatement(headline: readiness.headline, summary: readiness.summary, isOverride: false)
        case .sick:
            return BaseCardStatement(
                headline: String(localized: "Sick", comment: "Basiskarte headline, ActivityStatus.sick"),
                summary: String(localized: "Resting today. Training suggestions are paused until you're active again.",
                                comment: "Basiskarte fixed statement, ActivityStatus.sick"),
                isOverride: true)
        case .injured:
            return BaseCardStatement(
                headline: String(localized: "Injured", comment: "Basiskarte headline, ActivityStatus.injured"),
                summary: String(localized: "Recovering from an injury. Training suggestions are paused until you're active again.",
                                comment: "Basiskarte fixed statement, ActivityStatus.injured"),
                isOverride: true)
        case .onBreak:
            return BaseCardStatement(
                headline: String(localized: "On break", comment: "Basiskarte headline, ActivityStatus.onBreak"),
                summary: String(localized: "Taking a break. Training suggestions are paused until you're active again.",
                                comment: "Basiskarte fixed statement, ActivityStatus.onBreak"),
                isOverride: true)
        }
    }
}
