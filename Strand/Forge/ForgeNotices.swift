import Foundation
import StrandAnalytics

/// The data's own notices on the new design's Today timeline (2026-11-07): the Momentum signals that are
/// worth an entry, plus the strap that has not yet handed over the night. One feed instead of a banner, a
/// tile and cards around the rings; every notice passes `TimelineFeed.admit`, so a topic speaks at most
/// once a week unless it gets clearly worse.
///
/// Analysis migration required: no. Presentation of values Momentum already computes.
enum ForgeNotices {

    static let logKey = "forge.timeline.noticeLog"
    /// Topics and note kinds the reader asked to hear less often, and topics turned off, as comma lists.
    static let lessOftenKey = "forge.timeline.lessOften"
    static let mutedKey = "forge.timeline.mutedTopics"

    static func list(_ key: String, _ defaults: UserDefaults = .standard) -> Set<String> {
        Set((defaults.string(forKey: key) ?? "").split(separator: ",").map(String.init))
    }

    static func add(_ value: String, to key: String, _ defaults: UserDefaults = .standard) {
        defaults.set((list(key, defaults).union([value])).sorted().joined(separator: ","), forKey: key)
    }

    /// The Momentum kinds that become entries. The rest are said elsewhere: the Charge read and the
    /// training suggestion in the morning report, the cycle on its own card, steps on the rings' day, and
    /// the bedtime only in the evening report when sleep debt grows.
    static func topic(for kind: MomentumKind) -> TimelineFeed.Topic? {
        switch kind {
        case .healthAlert, .hrvTrend: return .bodySignals
        case .strapBattery: return .device
        case .restDayNeeded, .planDeviation: return .load
        case .sleepCatchUp: return .sleep
        case .milestone, .weightMilestone, .streak, .weeklyTrainingGoal: return .goals
        default: return nil
        }
    }

    /// Momentum's tone as the severity the cooldown compares: a step up in tone is "clearly worse".
    static func severity(_ tone: MomentumTone) -> Double {
        switch tone {
        case .positive: return 1
        case .neutral: return 2
        case .caution: return 3
        case .critical: return 4
        }
    }

    /// A reached milestone or a streak is its own news each time; a warning stays a warning while it lasts.
    static func isEvent(_ kind: MomentumKind) -> Bool {
        kind == .milestone || kind == .weightMilestone || kind == .streak
    }

    static func key(_ message: MomentumMessage) -> String {
        topic(for: message.kind) == .goals ? "\(message.kind.rawValue)|\(message.headline)" : message.kind.rawValue
    }

    static func action(_ destination: MomentumDestination?) -> ForgeTimeline.Notice.Action {
        switch destination {
        case .some(.chargeBreakdown): return .charge
        case .some(.goalJourney): return .goals
        case .some(.plan): return .plan
        case .some(.liveSession), .some(.none), nil: return .none
        }
    }

    /// The night is still on the strap: the wake time can move, and with it the Charge.
    static let nightPendingKey = "nightPending"

    /// The admitted notices for `day`, placed at the moment each first appeared, and the log written back.
    static func notices(momentum: [MomentumMessage], nightPending: Bool, day: String, now: Date,
                        defaults: UserDefaults = .standard) -> [ForgeTimeline.Notice] {
        var candidates: [TimelineFeed.Candidate] = []
        var byKey: [String: ForgeTimeline.Notice] = [:]
        for message in momentum {
            guard let topic = topic(for: message.kind) else { continue }
            let k = key(message)
            guard byKey[k] == nil else { continue }
            candidates.append(.init(key: k, topic: topic, severity: severity(message.tone), isEvent: isEvent(message.kind)))
            byKey[k] = ForgeTimeline.Notice(
                key: k, date: now, topic: topic.rawValue,
                tone: ForgeTimeline.Notice.Tone(rawValue: message.tone.rawValue) ?? .neutral,
                headline: message.headline,
                detail: [message.detail, message.actionLine].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "),
                action: action(message.action?.destination), actionTitle: message.action?.title)
        }
        if nightPending {
            candidates.append(.init(key: nightPendingKey, topic: .device, severity: 3, isEvent: true))
            byKey[nightPendingKey] = ForgeTimeline.Notice(
                key: nightPendingKey, date: now, topic: TimelineFeed.Topic.device.rawValue, tone: .caution,
                headline: String(localized: "The night may not be fully synced yet."),
                detail: String(localized: "Your wake time and Charge can still change. If you woke at the time shown, say so."),
                action: .confirmWake, actionTitle: String(localized: "Wake time is right"))
        }
        let muted = list(mutedKey, defaults), lessOften = list(lessOftenKey, defaults)
        candidates.removeAll { muted.contains($0.topic.rawValue) && $0.key != nightPendingKey }
        let log = (defaults.data(forKey: logKey)).flatMap { try? JSONDecoder().decode([TimelineFeed.Shown].self, from: $0) } ?? []
        let result = TimelineFeed.admit(candidates, log: log, day: day, now: now) { topic in
            lessOften.contains(topic.rawValue) ? 2 * TimelineFeed.cooldownDays : TimelineFeed.cooldownDays
        }
        if result.log != log, let data = try? JSONEncoder().encode(result.log) {
            defaults.set(data, forKey: logKey)
        }
        return result.admitted.compactMap { admitted in
            guard let base = byKey[admitted.candidate.key] else { return nil }
            return ForgeTimeline.Notice(key: base.key, date: admitted.at, topic: base.topic, tone: base.tone,
                                        headline: base.headline, detail: base.detail, action: base.action,
                                        actionTitle: base.actionTitle)
        }
    }
}
