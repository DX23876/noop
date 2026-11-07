import Foundation

/// The rules behind the new design's Today timeline that do not depend on a screen (2026-11-07): which
/// notices may appear, how walks are bundled and which past days are folded. Pure and platform-neutral, so
/// the Android app on the shared core gets the same answers.
///
/// Analysis migration required: no. Presentation rules over values that are already stored.
public enum TimelineFeed {

    // MARK: Notices and their cooldown

    /// What a notice is about. A topic speaks at most once in `cooldownDays`, unless it got clearly worse.
    public enum Topic: String, Codable, CaseIterable, Sendable {
        case sleep, load, bodySignals, movement, goals, device
    }

    /// A notice the data would raise right now. `key` names it within its day (the same notice on the same
    /// day is the same entry); `severity` grows as it gets worse.
    public struct Candidate: Equatable, Sendable {
        public let key: String
        public let topic: Topic
        public let severity: Double
        /// Events that are each their own news (a milestone reached) skip the topic's cooldown.
        public let isEvent: Bool

        public init(key: String, topic: Topic, severity: Double, isEvent: Bool = false) {
            self.key = key
            self.topic = topic
            self.severity = severity
            self.isEvent = isEvent
        }
    }

    /// One notice as it was shown: kept so it stays at its first moment through the day, and so its topic
    /// can be held back on the following days.
    public struct Shown: Codable, Equatable, Sendable {
        public let key: String
        public let topic: Topic
        public let day: String
        public let at: Date
        public let severity: Double

        public init(key: String, topic: Topic, day: String, at: Date, severity: Double) {
            self.key = key
            self.topic = topic
            self.day = day
            self.at = at
            self.severity = severity
        }
    }

    public struct Admitted: Equatable, Sendable {
        public let candidate: Candidate
        /// When it first appeared today; the entry sits there in the timeline.
        public let at: Date
    }

    public static let cooldownDays = 7
    /// "Clearly worse": the severity this many times the last shown one.
    public static let worsening = 1.5
    /// How long the log keeps a shown notice.
    public static let logDays = 30

    /// The candidates that may appear on `day`, each with its first moment, and the log to store.
    ///
    /// A notice already shown today stays. Otherwise its topic must have been quiet for `cooldownDays`, or
    /// the notice must be at least `worsening` times as severe as the topic's last one; an event skips the
    /// cooldown. Every newly admitted notice is written to the log at `now`.
    /// `cooldown` gives a topic's quiet days; a topic the reader asked to hear less often gets twice the
    /// default.
    public static func admit(_ candidates: [Candidate], log: [Shown], day: String, now: Date,
                             cooldown: (Topic) -> Int = { _ in cooldownDays })
        -> (admitted: [Admitted], log: [Shown]) {
        var log = log.filter { now.timeIntervalSince($0.at) < Double(logDays) * 86_400 }
        var admitted: [Admitted] = []
        for candidate in candidates {
            if let today = log.first(where: { $0.key == candidate.key && $0.day == day }) {
                admitted.append(Admitted(candidate: candidate, at: today.at))
                continue
            }
            if !candidate.isEvent,
               let last = log.filter({ $0.topic == candidate.topic && $0.day != day })
                   .max(by: { $0.at < $1.at }),
               now.timeIntervalSince(last.at) < Double(cooldown(candidate.topic)) * 86_400,
               candidate.severity < last.severity * worsening {
                continue
            }
            log.append(Shown(key: candidate.key, topic: candidate.topic, day: day, at: now, severity: candidate.severity))
            admitted.append(Admitted(candidate: candidate, at: now))
        }
        return (admitted, log)
    }

    // MARK: Walks

    /// A walk as the timeline sees it. Only walks the wearer did not start themselves are bundled.
    public struct Walk: Equatable, Sendable {
        public let id: String
        public let start: Date
        public let end: Date
        /// Detected by the app or imported from another app.
        public let bundles: Bool

        public init(id: String, start: Date, end: Date, bundles: Bool) {
            self.id = id
            self.start = start
            self.end = end
            self.bundles = bundles
        }

        public var minutes: Double { max(0, end.timeIntervalSince(start)) / 60 }
    }

    /// The walks to show as one entry per day: only days with two or more bundling walks. A single walk,
    /// and every walk the wearer started, stays an entry of its own.
    public static func walkBundles(_ walks: [Walk], dayKey: (Date) -> String) -> [String: [Walk]] {
        let grouped = Dictionary(grouping: walks.filter(\.bundles)) { dayKey($0.end) }
        return grouped.filter { $0.value.count >= 2 }
            .mapValues { $0.sorted { $0.end < $1.end } }
    }

    // MARK: Folded days

    /// Whether a day of the timeline shows as one line. Today and yesterday stay open; older days fold
    /// unless the reader opened them.
    public static func isFolded(day: String, today: String, yesterday: String, opened: Set<String>) -> Bool {
        day != today && day != yesterday && !opened.contains(day)
    }
}
