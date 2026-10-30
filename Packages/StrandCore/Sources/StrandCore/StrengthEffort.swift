import Foundation
import StrandAnalytics
import WhoopStore

/// The load rated strength sessions add to Effort beyond their heart rate (#2438, Lab switch
/// `AnalysisSettings.effortStrengthBonus`, off by default).
///
/// A session counts when its fused activity is strength (`TrainingActivityKind.strength`; yoga and pilates are
/// mobility) and the wearer rated it. The rating is the one Training Load reads: the latest answer per canonical
/// session (`latestPerSession`). Without a rating a session adds nothing; there is no assumed value.
public enum StrengthEffort {

    /// One rated strength session.
    public struct Session: Equatable, Sendable {
        public let sessionId: String
        public let startTs: Int
        public let rpe: Double
        public let minutes: Double

        public init(sessionId: String, startTs: Int, rpe: Double, minutes: Double) {
            self.sessionId = sessionId; self.startTs = startTs; self.rpe = rpe; self.minutes = minutes
        }

        /// The load it adds before the curve.
        public var load: Double { StrainScorer.strengthLoad(rpe: rpe, minutes: minutes) }
    }

    /// One answer per session: where a session was rated several times, the latest answer wins (`ratedAt`,
    /// which falls back to the workout start for legacy answers), and the id breaks a tie so the choice never
    /// depends on read order. Training Load resolves its ratings with this too.
    public static func latestPerSession<Entry>(_ entries: [Entry], key: (Entry) -> String,
                                               ratedAt: (Entry) -> Int, id: (Entry) -> String) -> [Entry] {
        var chosen: [String: Entry] = [:]
        for entry in entries {
            let k = key(entry)
            if let existing = chosen[k], (ratedAt(existing), id(existing)) >= (ratedAt(entry), id(entry)) { continue }
            chosen[k] = entry
        }
        return Array(chosen.values)
    }

    /// The rated strength sessions among `fused`, oldest first.
    public static func sessions(fused: [UnifiedTrainingSession], ratings: [TrainingSessionRating]) -> [Session] {
        var sessionByKey: [String: UnifiedTrainingSession] = [:]
        var keyByStart: [Int: String] = [:]
        for session in fused {
            sessionByKey[session.id] = session
            keyByStart[session.row.startTs] = session.id
            for component in session.components { keyByStart[component.row.startTs] = session.id }
        }
        let key: (TrainingSessionRating) -> String = {
            $0.sessionId ?? keyByStart[$0.workoutStartTs] ?? "start|\($0.workoutStartTs)"
        }
        let chosen = latestPerSession(ratings, key: key, ratedAt: { $0.ratedAtTs ?? $0.workoutStartTs },
                                      id: \.id)
        return chosen.compactMap { rating -> Session? in
            let found = sessionByKey[key(rating)] ?? keyByStart[rating.workoutStartTs].flatMap { sessionByKey[$0] }
            guard let session = found, session.kind == .strength,
                  rating.rpe.isFinite, (1...10).contains(rating.rpe) else { return nil }
            let seconds = session.row.durationS ?? Double(session.row.endTs - session.row.startTs)
            guard seconds > 0 else { return nil }
            return Session(sessionId: session.id, startTs: session.row.startTs, rpe: rating.rpe, minutes: seconds / 60)
        }
        .sorted { ($0.startTs, $0.sessionId) < ($1.startTs, $1.sessionId) }
    }

    /// The strength load of the sessions that start in `window` (`[start, end)`, unix seconds).
    public static func load(_ sessions: [Session], startingIn window: Range<Int>) -> Double {
        sessions.reduce(0) { window.contains($1.startTs) ? $0 + $1.load : $0 }
    }

    /// The rated strength sessions starting in `[from, to)`, read through the platform's session fusion.
    @MainActor
    static func read(services: AnalysisDataServices, store: WhoopStore, from: Int, to: Int) async -> [Session] {
        let ratings = (try? await store.trainingSessionRatings(from: from, to: to)) ?? []
        guard !ratings.isEmpty else { return [] }
        let fused = await services.trainingSessions(from: from - 86_400, to: to + 86_400)
        return sessions(fused: fused.sessions, ratings: ratings).filter { (from..<to).contains($0.startTs) }
    }
}
