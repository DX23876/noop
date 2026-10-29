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
    }

    public struct Host {
        public var kinds: [String], quiet: Bool, eveningMinute: Int, workoutInProgress: Bool, appIsActive: Bool
        public var state: String?
        public init(kinds: [String], quiet: Bool, eveningMinute: Int, workoutInProgress: Bool, appIsActive: Bool,
                    state: String?) {
            self.kinds = kinds; self.quiet = quiet; self.eveningMinute = eveningMinute
            self.workoutInProgress = workoutInProgress; self.appIsActive = appIsActive; self.state = state
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
            return Output(messages: messages.map {
                Message(id: $0.id, title: $0.title, body: $0.body, tickGoalId: $0.tickGoalId, tickDay: $0.tickDay,
                        evening: $0.evening)
            }, state: encoded)
        }
    }
}
