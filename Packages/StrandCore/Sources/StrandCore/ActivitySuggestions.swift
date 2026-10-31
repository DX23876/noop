import Foundation
import StrandAnalytics
import WhoopStore

/// Activity detection in the daily pass and the ONE resolver every surface reads (fork decision 2026-10-31):
/// the Today prompt, the inbox rows, the logging sheet's suggestions and the notifications all ask
/// `ActivitySuggestions.resolve`, so an answer given in one place is the answer everywhere and a span is
/// never offered twice. Suggestions are shown, never scored.
public enum ActivitySuggestions {

    /// How many days the inbox lists.
    public static let listDays = 14
    /// A suggestion is asked about only once heart rate has had this long to settle after it ended.
    public static let settleSeconds = 10 * 60
    /// Share of a suggestion a logged workout must cover for the suggestion to count as logged.
    public static let loggedCoverage = 0.5

    public enum State: Equatable, Sendable {
        case open
        case answered(ActivitySuggestionAnswer.Answer)
        /// A workout from any source already covers it, so it is never asked about.
        case logged
    }

    public struct Suggestion: Equatable, Sendable, Identifiable {
        public let track: ActivityCandidates.Track
        public let start: Int
        public let end: Int
        public let avgBpm: Int?
        public let load: Double
        public let kinds: [ActivityDetectionScore.Kind]
        public let ruleVersion: String
        public let state: State
        /// Whether it carries enough load to be asked about at the wearer's level (walks always do).
        public let asks: Bool

        public var id: String { "\(track.rawValue):\(start)" }
        public var durationMinutes: Int { (end - start) / 60 }
        public var likelyKind: ActivityDetectionScore.Kind { kinds.first ?? .other }
    }

    public struct Settings: Equatable, Sendable {
        public var level: ActivityCandidates.Level
        public var walks: Bool
        public init(level: ActivityCandidates.Level = .balanced, walks: Bool = true) {
            self.level = level
            self.walks = walks
        }
    }

    /// Every stored suggestion with its state. `legacyDismissed` are the spans the old Today card was told
    /// to forget; they stay forgotten. Walk suggestions are left out when walks are switched off.
    public static func resolve(candidates: [ActivityCandidateRow], answers: [ActivitySuggestionAnswer],
                               workouts: [WorkoutRow], legacyDismissed: [Range<Int>] = [],
                               settings: Settings) -> [Suggestion] {
        let answerByKey = Dictionary(answers.map { ("\($0.track.rawValue):\($0.candidateStartTs)", $0) },
                                     uniquingKeysWith: { a, b in a.answeredAtTs >= b.answeredAtTs ? a : b })
        let logged = workouts.filter { WorkoutSource.classify($0.source) != .detected && $0.endTs > $0.startTs }
        return candidates.compactMap { row in
            guard let track = ActivityCandidates.Track(rawValue: row.track), row.endTs > row.startTs else { return nil }
            if track == .walk, !settings.walks { return nil }
            if legacyDismissed.contains(where: { $0.lowerBound < row.endTs && row.startTs < $0.upperBound }) { return nil }
            let length = Double(row.endTs - row.startTs)
            let covered = logged.contains { w in
                Double(max(0, min(w.endTs, row.endTs) - max(w.startTs, row.startTs))) / length >= loggedCoverage
            }
            let state: State
            if let a = answerByKey["\(row.track):\(row.startTs)"] {
                state = .answered(a.answer)
            } else {
                state = covered ? .logged : .open
            }
            let candidate = ActivityCandidates.Candidate(
                track: track, start: row.startTs, end: row.endTs, avgBpm: row.avgBpm, peakBpm: row.peakBpm,
                load: row.load, cadence: row.cadence, locomotionShare: row.locomotionShare, kinds: [])
            return Suggestion(track: track, start: row.startTs, end: row.endTs, avgBpm: row.avgBpm, load: row.load,
                              kinds: row.kinds.compactMap(ActivityDetectionScore.Kind.init(rawValue:)),
                              ruleVersion: row.ruleVersion, state: state, asks: candidate.asks(at: settings.level))
        }
    }

    /// What the Today prompt and a notification ask about: open suggestions above the level whose heart rate
    /// has settled, newest first. `snoozed` are ids the wearer put off with "Later" in this launch.
    public static func toAsk(_ all: [Suggestion], now: Int, snoozed: Set<String> = []) -> [Suggestion] {
        all.filter { $0.state == .open && $0.asks && $0.end + settleSeconds <= now && !snoozed.contains($0.id) }
            .sorted { $0.start > $1.start }
    }

    /// The inbox rows: the last `listDays` days, open first (newest first), then answered and logged ones.
    public static func inbox(_ all: [Suggestion], now: Int) -> [Suggestion] {
        let recent = all.filter { $0.end > now - listDays * 86_400 && $0.end + settleSeconds <= now }
        let open = recent.filter { $0.state == .open }.sorted { $0.start > $1.start }
        let rest = recent.filter { $0.state != .open }.sorted { $0.start > $1.start }
        return open + rest
    }

    /// The logging sheet's chips for a day: every open suggestion of that day, below the level too, so a
    /// wearer logging by hand can pick the span the detector saw.
    public static func forSheet(_ all: [Suggestion], dayStart: Int, dayEnd: Int) -> [Suggestion] {
        all.filter { $0.state == .open && $0.start < dayEnd && $0.end > dayStart }.sorted { $0.start < $1.start }
    }

    /// The answer row for a suggestion, with what was shown and when.
    public static func answer(_ s: Suggestion, _ answer: ActivitySuggestionAnswer.Answer, sport: String?,
                              origin: ActivitySuggestionAnswer.Origin, shownAt: Int?, now: Int,
                              workout: ActivitySuggestionAnswer.WorkoutKey?) -> ActivitySuggestionAnswer {
        ActivitySuggestionAnswer(
            track: s.track == .walk ? .walk : .heartRate, candidateStartTs: s.start, candidateEndTs: s.end,
            answer: answer, sport: sport, origin: origin, shownKind: s.likelyKind.rawValue, shownScore: s.load,
            modelVersion: s.ruleVersion, startWeightVersion: ActivityCandidates.ruleVersion,
            shownAtTs: shownAt, answeredAtTs: now, workout: workout)
    }

    // MARK: - Daily pass

    /// The stored switch for activity detection (the same key the old Today card used, so a wearer who had
    /// it on keeps it on). Off, the pass computes nothing and every surface stays empty.
    public static let enabledKey = "noopAutoDetectWorkouts"
    public static let walksKey = "noop.activityDetection.walks"
    public static let levelKey = "noop.activityDetection.level"
    public static let notificationsKey = "noop.activityDetection.notifications"

    /// How many recent days every pass recomputes. Older days of the window are recomputed only when the
    /// rule changed, since their data no longer moves.
    public static let refreshDays = 3

    /// Recomputes the suggestions of the recent days from the stored minutes and writes them. Each day reads
    /// only the two weeks before it for the everyday level and the resting heart rate measured that morning
    /// (else the day before), so a day's suggestions never depend on a later day.
    @discardableResult
    public static func refresh(store: WhoopStore, deviceId: String, computedId: String, hrMax: Int, now: Int,
                               calendar: Calendar = .current) async throws -> [ActivityCandidates.Candidate] {
        let today = Int(calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(now))).timeIntervalSince1970)
        let windowStart = today - (listDays - 1) * 86_400
        let stored = try await store.activityCandidates(deviceId: deviceId, from: windowStart, to: now + 1)
        let stale = stored.isEmpty || stored.contains { $0.ruleVersion != ActivityCandidates.ruleVersion }
        let firstDay = stale ? windowStart : today - (refreshDays - 1) * 86_400

        let readFrom = firstDay - 14 * 86_400
        let minutes = try await activityMinutes(store: store, deviceId: deviceId, computedId: computedId,
                                                from: readFrom, to: now + 1)
        let resting = try await store.dailyMetrics(deviceId: computedId, from: dayKey(readFrom, calendar),
                                                   to: dayKey(now, calendar))
        let restingByDay = Dictionary(resting.compactMap { d in d.restingHr.map { (d.day, $0) } },
                                      uniquingKeysWith: { a, _ in a })

        var found: [ActivityCandidates.Candidate] = []
        var day = firstDay
        while day <= today {
            let next = Int(calendar.date(byAdding: .day, value: 1, to: Date(timeIntervalSince1970: TimeInterval(day)))!
                .timeIntervalSince1970)
            let key = dayKey(day, calendar), previous = dayKey(day - 43_200, calendar)
            if let rest = restingByDay[key] ?? restingByDay[previous] {
                let dayMinutes = slice(minutes, day, next)
                let everyday = ActivityCandidates.everydayHRR(history: slice(minutes, day - 14 * 86_400, day),
                                                              restingHR: rest, hrMax: hrMax)
                found += ActivityCandidates.candidates(dayMinutes, restingHR: rest, hrMax: hrMax, everydayHRR: everyday)
            }
            day = next
        }
        try await store.replaceActivityCandidates(deviceId: deviceId, from: firstDay, to: now + 1, rows: found.map {
            ActivityCandidateRow(deviceId: deviceId, track: $0.track.rawValue, startTs: $0.start, endTs: $0.end,
                                 ruleVersion: ActivityCandidates.ruleVersion, avgBpm: $0.avgBpm, peakBpm: $0.peakBpm,
                                 load: $0.load, cadence: $0.cadence, locomotionShare: $0.locomotionShare,
                                 kinds: $0.kinds.map(\.rawValue))
        })
        return found
    }

    /// The minutes the tracks read: heart rate where at least 30 seconds were measured, the strap's step
    /// minutes where a step stream exists, and sleep from the stored sessions.
    static func activityMinutes(store: WhoopStore, deviceId: String, computedId: String,
                                from: Int, to: Int) async throws -> [ActivityCandidates.Minute] {
        let hr = try await store.hrBuckets(deviceId: deviceId, from: from, to: to, bucketSeconds: 60)
        let steps = try await store.stepMinutes(deviceId: deviceId, from: from, to: to)
        var sleep: [(start: Int, end: Int)] = []
        for id in Set([deviceId, computedId]) {
            sleep += try await store.sleepSessions(deviceId: id, from: from - 86_400, to: to, limit: 10_000)
                .map { ($0.startTs, $0.endTs) }
        }
        sleep.sort { $0.start < $1.start }
        let bpmByMinute = Dictionary(hr.filter { $0.sampleSeconds >= 30 }.map { ($0.ts, $0.bpm) },
                                     uniquingKeysWith: { a, _ in a })
        let stepByMinute = Dictionary(steps.map { ($0.ts, $0) }, uniquingKeysWith: { a, _ in a })
        var sleepIndex = 0
        return Set(bpmByMinute.keys).union(stepByMinute.keys).sorted().map { ts in
            while sleepIndex < sleep.count, sleep[sleepIndex].end <= ts { sleepIndex += 1 }
            let asleep = sleep[sleepIndex...].prefix { $0.start <= ts }.contains { ts < $0.end }
            let st = stepByMinute[ts]
            return ActivityCandidates.Minute(ts: ts, bpm: bpmByMinute[ts], steps: st?.steps,
                                             walkSeconds: st?.walkSeconds, runSeconds: st?.runSeconds,
                                             classSeconds: st?.classSeconds, asleep: asleep)
        }
    }

    static func slice(_ minutes: [ActivityCandidates.Minute], _ from: Int, _ to: Int) -> [ActivityCandidates.Minute] {
        func first(_ bound: Int) -> Int {
            var lo = 0, hi = minutes.count
            while lo < hi { let mid = (lo + hi) / 2; if minutes[mid].ts >= bound { hi = mid } else { lo = mid + 1 } }
            return lo
        }
        return Array(minutes[first(from) ..< first(to)])
    }

    static func dayKey(_ ts: Int, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(ts)))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
