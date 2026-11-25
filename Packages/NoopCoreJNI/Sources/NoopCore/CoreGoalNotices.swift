import Foundation
import StrandCore

/// The goal notifications for Android (parity plan 2.3): the goals refreshed read-only as Apple's refresh does, then
/// `GoalEventPlan` decides what to say exactly as Apple's `GoalEventNotifier` does. The host keeps `state` between
/// runs and posts the messages; quiet hours, the evening minute, a running workout and an open app are its to know.
public enum CoreGoalNotices {
    public struct Message: Encodable {
        public var id: String, title: String, body: String, tickGoalId: String?, tickDay: String?, evening: Bool
    }

    public struct Output: Encodable {
        public var messages: [Message]
        /// The plan's state to store and send back next time, as JSON.
        public var state: String
        /// The optional weekly-goal notices (`PeriodGoalNoticePlan`) for the rest of this week, each with the
        /// moment it fires. The host replaces whatever it scheduled last time with exactly these.
        public var periodNotices: [PeriodNotice] = []
    }

    public struct PeriodNotice: Encodable {
        public var id: String, title: String, body: String
        /// When to show it, unix seconds.
        public var at: Int
    }

    public struct Host {
        public var kinds: [String], quiet: Bool, eveningMinute: Int, workoutInProgress: Bool, appIsActive: Bool
        public var state: String?
        /// The weekly-goal kinds the wearer switched on (`GoalPrefs.NotificationKind` raw values), the first
        /// weekday (1 = Sunday, 2 = Monday) and the quiet-hours window a notice must not fall into.
        public var periodKinds: [String] = []
        public var firstWeekday = 2
        public var quietEnabled = false, quietStartMinutes = 22 * 60, quietEndMinutes = 7 * 60
        public init(kinds: [String], quiet: Bool, eveningMinute: Int, workoutInProgress: Bool, appIsActive: Bool,
                    state: String?) {
            self.kinds = kinds; self.quiet = quiet; self.eveningMinute = eveningMinute
            self.workoutInProgress = workoutInProgress; self.appIsActive = appIsActive; self.state = state
        }

        /// Whether `date` falls inside the wearer's quiet hours, as `GoalNotifier.isQuiet` reads them on Apple.
        func isQuiet(_ date: Date, _ calendar: Calendar) -> Bool {
            guard quietEnabled else { return false }
            let c = calendar.dateComponents([.hour, .minute], from: date)
            let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            return quietStartMinutes <= quietEndMinutes
                ? (minutes >= quietStartMinutes && minutes < quietEndMinutes)
                : (minutes >= quietStartMinutes || minutes < quietEndMinutes)
        }
    }

    @MainActor
    public static func evaluate(reader: StoreReader, settings: CoreGoals.Settings, host: Host,
                                now: Date = Date(), calendar: Calendar = .autoupdatingCurrent) async throws -> Output {
        let source = try await CoreGoals.source(reader: reader, settings: settings, now: now)
        var state = host.state.flatMap { try? JSONDecoder().decode(GoalEventPlan.State.self, from: Data($0.utf8)) }
            ?? GoalEventPlan.State()
        return try await CoreGoalState.read(store: reader.store) { context in
            let model = CoreGoals.evaluate(source: source, context: context, now: now)
            let plan = GoalEventPlan.Context(kinds: Set(host.kinds.compactMap(GoalEventPlan.Kind.init(rawValue:))),
                                             workoutInProgress: host.workoutInProgress, appIsActive: host.appIsActive,
                                             quiet: host.quiet, eveningMinute: host.eveningMinute,
                                             seenBadgeIds: GoalPrefs.seenBadgeIds)
            var messages: [GoalEventPlan.Message] = []
            let daily = GoalEventPlan.daily(todayActions: model.todayActions, motivation: model.motivation,
                                            state: state, context: plan, now: now, calendar: calendar)
            state = daily.1
            if let m = daily.0 { messages.append(m) }
            let longTerm = GoalEventPlan.longTerm(model.snapshots, state: state, context: plan, now: now,
                                                  calendar: calendar)
            state = longTerm.1
            if let m = longTerm.0 { messages.append(m) }
            let encoded = (try? JSONEncoder().encode(state)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            var calendar = calendar
            calendar.firstWeekday = host.firstWeekday == 1 ? 1 : 2
            let periodKinds = Set(host.periodKinds.compactMap(GoalPrefs.NotificationKind.init(rawValue:)))
            let periodNotices = PeriodGoalNoticePlan.plan(model.periodSnapshots, kinds: periodKinds, now: now,
                                                         calendar: calendar, isQuiet: { host.isQuiet($0, calendar) })
                .map { PeriodNotice(id: $0.id, title: $0.title, body: $0.body, at: Int($0.at.timeIntervalSince1970)) }
            return Output(messages: messages.map {
                Message(id: $0.id, title: $0.title, body: $0.body, tickGoalId: $0.tickGoalId, tickDay: $0.tickDay,
                        evening: $0.evening)
            }, state: encoded, periodNotices: periodNotices)
        }
    }
}
