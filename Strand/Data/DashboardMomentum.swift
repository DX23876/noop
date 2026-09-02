import Foundation
import StrandAnalytics
import WhoopStore

/// Assembles and publishes the Momentum feed for the two reference-matched dashboards.
///
/// `MomentumStore`'s own note explains why the feed is built on Today and merely READ elsewhere: two
/// assembly paths would eventually give one device two different answers to "what matters right now".
/// That reasoning holds — but it was written when "Today" meant Classic or Liquid, and "elsewhere" meant
/// the standalone Momentum dashboard. Trends and Overview are Today screens now, and they only read. So
/// for anyone whose Today IS one of them, `MomentumStore.shared.messages` stayed empty forever: turning
/// the Momentum section on produced the "open Momentum" fallback link and never a single message.
///
/// This does not add a second path. The ranking, the dwell, the snooze and the copy all still come from
/// `MomentumResolver` / `MomentumBuilder` — one implementation, now with a third caller. What lives here
/// is only the assembly of the plain values a dashboard can supply, in ONE place rather than copied into
/// each of the two.
///
/// Two `Context` fields are deliberately left nil, and the builder is explicitly built for that ("Anything
/// the caller cannot supply stays nil and simply produces no candidate of that kind"):
///
/// - `statusOverride` needs the resolved readiness state Today computes for its own status card. A wearer
///   who has marked themselves sick therefore does not get that tier-0 message on a dashboard yet. It is
///   the one honest gap here, and it fails quiet rather than wrong.
/// - `calibration` likewise needs Today's calibration copy.
@MainActor
enum DashboardMomentum {

    /// The `@AppStorage` keys the dwell bookkeeping lives under. Deliberately the SAME keys both Today
    /// screens use: it is one wearer and one card, so switching Today styles must not restart the dwell
    /// or resurrect a message they hid an hour ago.
    enum Keys {
        static let lastKind = "momentum.lastKind"
        static let lastAt = "momentum.lastAt"
        static let snoozed = "momentum.snoozed"
        static let stepGoal = "momentum.stepGoal"
    }

    /// Build the context from what a dashboard holds. Every argument is a plain value the caller already
    /// resolved for its own rendering, so nothing here re-reads the store or re-derives a day.
    static func context(displayDay: DailyMetric?,
                        allDays: [DailyMetric],
                        dayKey: String,
                        isToday: Bool,
                        steps: DailyStepsReading?,
                        stepGoal: Int) -> MomentumBuilder.Context {
        var c = MomentumBuilder.Context()
        c.displayDay = displayDay
        c.allDays = allDays
        c.dayKey = dayKey
        c.isToday = isToday

        // The carried "last night · 15 Aug" read, resolved through Today's own pure helpers so a
        // dashboard cannot carry a different day than Today would for the same data.
        let lastScored = TodayView.lastScoredRecoveryDay(days: allDays,
                                                         selectedDayKey: dayKey,
                                                         isToday: isToday,
                                                         todayScored: displayDay?.recovery != nil,
                                                         isCalibrating: false)
        c.lastScoredDay = lastScored
        c.carriedCaption = lastScored.map {
            TodayView.carriedCaption(priorDayKey: $0.day, todayKey: dayKey)
        }

        // Measured and estimated stay apart: only a measured count may carry a "still to go" figure,
        // which is the gate inside the builder.
        switch steps {
        case .measured(let n): c.measuredSteps = n
        case .estimated(let n): c.estimatedSteps = n
        case nil: break
        }
        c.stepGoal = stepGoal

        // A commitment made for TODAY that has not been recorded, resolved through the SAME selector the
        // Plan card uses, so the two cannot disagree about what is still open.
        if isToday,
           let next = PlanTodayCard.next(from: CoachPlanStore.shared.proposals, today: dayKey, now: Date()),
           next.day == dayKey, (displayDay?.exerciseCount ?? 0) == 0 {
            c.openPlannedSessionToday = next.sport
        }
        return c
    }

    /// Resolve and publish. Call from a `.task(id:)`, never from a body: the publish writes to an
    /// `ObservableObject`, and doing that during a view update is what SwiftUI warns about with
    /// "Modifying state during view update".
    static func publish(context: MomentumBuilder.Context,
                        allDays: [DailyMetric],
                        snoozedRaw: String,
                        lastKind: String,
                        lastAt: Double,
                        retrospective: Bool) {
        let messages = MomentumResolver.feed(context: context,
                                             snoozedRaw: snoozedRaw,
                                             lastKind: lastKind,
                                             lastAt: lastAt,
                                             retrospective: retrospective)
        MomentumStore.shared.publish(messages, recentDays: allDays)
    }
}
