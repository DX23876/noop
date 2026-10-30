import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// Momentum for the Android app (parity plan 1.2): the feed the iOS Today card and dashboards show, assembled the
/// way `DashboardMomentum` assembles it from what a screen without Today's full state can supply, then built,
/// ranked and worded by the shared `MomentumResolver` and `MomentumBuilder`. Texts arrive in the wearer's language
/// through `CoreLocalization`.
///
/// The host supplies what only it holds, as `DashboardMomentum.LiveInput` does on Apple: the health alert in its own
/// banner's words, the strap's remaining runtime and the cycle phase (only when cycle tracking is on). Today's steps
/// are measured when the strap or Apple Health counted them, else the strap estimate flagged as one. Left nil as on
/// the Apple dashboards: the explicit sick or injured status and the calibration copy.
public enum CoreMomentum {
    public struct Message: Encodable {
        public var kind: String, tone: String, headline: String, detail: String, actionLine: String?
        public var progress: Double?, progressLabel: String?, progressChip: String?, deltaText: String?
        public var actionTitle: String?, destination: String?
    }

    public struct Output: Encodable { public var messages: [Message] }

    /// The ranked feed for today. `snoozedRaw`, `lastKind` and `lastAt` are the dwell bookkeeping Android keeps
    /// under the same keys as the Apple screens (`DashboardMomentum.Keys`).
    @MainActor
    public static func feed(reader: StoreReader, settings: CoreGoals.Settings, hrvEpoch: Double,
                            recoveryEpoch: Double, snoozedRaw: String, lastKind: String, lastAt: Double,
                            healthAlertCopy: String? = nil, strapHoursRemaining: Double? = nil,
                            cyclePhase: String? = nil, cycleDayLow: Int? = nil, cycleDayHigh: Int? = nil,
                            now: Date = Date()) async throws -> Output {
        let todayKey = LogicalDay.key(now)
        let from = StoreReader.localDayKey(now.addingTimeInterval(-60 * 86_400))
        let to = StoreReader.localDayKey(now.addingTimeInterval(86_400))
        let imported = await reader.unionDailyMetrics(from: from, to: to)
        let computed = await reader.unionComputedDailyMetrics(from: from, to: to)
        let days = StoreReader.mergeDaily(imported: imported, computed: computed).filter { $0.day <= todayKey }
        let display = days.last { $0.day == todayKey }
        let nowTs = Int(now.timeIntervalSince1970)
        let anchor = AnalyticsEngine.dayString(nowTs, offsetSec: TimeZone.current.secondsFromGMT(for: now))
        let baselines = ChargeBaselines.resolve(imported: imported, own: computed, anchorDay: anchor,
                                                hrvEpoch: hrvEpoch, recoveryEpoch: recoveryEpoch)
        let appleSteps = ((try? await reader.store.appleDaily(deviceId: MetricResolver.appleHealthSource,
                                                              from: todayKey, to: todayKey)) ?? [])
            .first { $0.day == todayKey }?.steps

        var c = MomentumBuilder.Context()
        c.displayDay = display
        c.allDays = days
        c.hrvBaseline = baselines.hrv
        c.dayKey = todayKey
        c.isToday = true
        let lastScored = CarriedRecovery.lastScored(days: days, selectedDayKey: todayKey, isToday: true,
                                                    todayScored: display?.recovery != nil, isCalibrating: false)
        c.lastScoredDay = lastScored
        c.carriedCaption = lastScored.map { CarriedRecovery.caption(priorDayKey: $0.day, todayKey: todayKey) }
        // `DailyStepsReading.resolve`: the strap's own count, else Apple Health's for the same day, else the strap
        // estimate for the day, which the builder only reads qualitatively.
        if let steps = display?.steps ?? appleSteps {
            c.measuredSteps = steps
        } else if let estimate = await reader.exploreSeries(key: "steps_est", source: MetricResolver.whoopSource,
                                                            from: todayKey, to: todayKey, dailyRows: days,
                                                            suppressedSleepWakeDays: []).last(where: { $0.day == todayKey }) {
            c.estimatedSteps = Int(estimate.value.rounded())
        }
        c.healthAlertCopy = healthAlertCopy
        c.strapHoursRemaining = strapHoursRemaining
        if let phase = cyclePhase.flatMap(CyclePhaseEngine.Phase.init(rawValue:)) {
            c.cyclePhaseTitle = MomentumCopy.cyclePhaseTitle(phase)
            c.cycleDayRange = MomentumCopy.cycleDayRange(low: cycleDayLow, high: cycleDayHigh)
        }
        // A session agreed for today and not yet recorded, through the selector the plan card uses
        // (`DashboardMomentum.context`).
        if let next = PlanTodaySelection.next(from: CoachPlanStore.shared.proposals, today: todayKey, now: now),
           next.day == todayKey, PlanTodaySelection.shouldFlagInMomentum(next, now: now),
           (display?.exerciseCount ?? 0) == 0 {
            c.openPlannedSessionToday = next.sport
        }

        let source = try await CoreGoals.source(reader: reader, settings: settings, now: now)
        return try await CoreGoalState.read(store: reader.store) { context in
            c.stepGoal = context.actions.dailyStepGoal.flatMap { action -> Int? in
                if case .steps(let minimum) = action.requirement { return minimum } else { return nil }
            } ?? 0
            let model = CoreGoals.evaluate(source: source, context: context, now: now)
            let messages = MomentumResolver.feed(context: c, snoozedRaw: snoozedRaw, lastKind: lastKind,
                                                 lastAt: lastAt, retrospective: false,
                                                 periodSnapshots: model.periodSnapshots,
                                                 longTerm: model.snapshots, now: now)
            return Output(messages: messages.map { m in
                Message(kind: m.kind.rawValue, tone: m.tone.rawValue, headline: m.headline, detail: m.detail,
                        actionLine: m.actionLine, progress: m.progress?.fraction, progressLabel: m.progress?.label,
                        progressChip: m.progress?.chipText, deltaText: m.deltaText, actionTitle: m.action?.title,
                        destination: m.action?.destination.rawValue)
            })
        }
    }

    /// The snoozed kinds after hiding one for the rest of the logical day (`MomentumResolver.snoozing`).
    @MainActor
    public static func snooze(kind: String, snoozedRaw: String, now: Date = Date()) -> String {
        guard let kind = MomentumKind(rawValue: kind) else { return snoozedRaw }
        return MomentumResolver.snoozing(kind, into: snoozedRaw, now: now)
    }
}
