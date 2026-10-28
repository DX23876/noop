import Foundation
import WhoopStore

/// The athlete's own rating of one whole session (see `SessionRPEStore.swift` for why it is kept apart from set
/// RPE). Its own file so the Android core reads the same type (parity plan 1.2).
struct SessionRPEEntry: Equatable, Sendable {
    let id: String
    let sessionId: String?
    let startTs: Int
    let rpe: Double
    let sport: String?
    let ratedAtTs: Int?
    let source: String

    init(id: String, sessionId: String?, startTs: Int, rpe: Double, sport: String?,
         ratedAtTs: Int? = nil, source: String = SessionRPEEntry.manualSource) {
        self.id = id
        self.sessionId = sessionId
        self.startTs = startTs
        self.rpe = rpe
        self.sport = sport
        self.ratedAtTs = ratedAtTs
        self.source = source
    }

    /// The source a rating the wearer entered in NOOP carries.
    static let manualSource = TrainingSessionRating.manualSource

    /// Every whole-session rating in the time range, oldest first (Apple: `Repository.sessionRPEEntries`, Android:
    /// the core's Training Load read).
    static func read(store: WhoopStore, from: Int, to: Int) async -> [SessionRPEEntry] {
        let rows = (try? await store.trainingSessionRatings(from: from, to: to)) ?? []
        return rows.map { row in
            SessionRPEEntry(id: row.id, sessionId: row.sessionId,
                            startTs: row.workoutStartTs, rpe: row.rpe, sport: row.sport,
                            ratedAtTs: row.ratedAtTs, source: row.source)
        }
    }
    enum Timing: String, Sendable { case unknown, immediately, about30Minutes, later }

    func timing(durationS: Double?) -> Timing {
        guard let ratedAtTs else { return .unknown }
        let end = startTs + Int(durationS ?? 0)
        let delay = Int((Double(ratedAtTs - end) / 60).rounded())
        if (20...45).contains(delay) { return .about30Minutes }
        return delay < 20 ? .immediately : .later
    }

    static func durationMinutes(_ durationS: Double?) -> Double? {
        durationS.flatMap { $0 > 0 ? $0 / 60 : nil }
    }

    func load(durationS: Double?) -> Double? { Self.durationMinutes(durationS).map { rpe * $0 } }

    static func record(store: WhoopStore, rpe: Double, startTs: Int, sport: String,
                       sessionId: String?, ratedAtTs: Int) async -> Bool {
        guard rpe.isFinite, (1...10).contains(rpe) else { return false }
        let row = TrainingSessionRating(id: "session-rpe-\(startTs)", sessionId: sessionId,
            workoutStartTs: startTs, ratedAtTs: ratedAtTs, rpe: rpe, sport: sport, source: manualSource)
        do { return try await store.replaceTrainingSessionRating(row) }
        catch { return false }
    }

    static func latest(_ rows: [SessionRPEEntry], sessionId: String?, startTs: Int?) -> SessionRPEEntry? {
        let canonical = sessionId.map { id in rows.filter { $0.sessionId == id } } ?? []
        let candidates = canonical.isEmpty ? rows.filter {
            $0.startTs == startTs && (sessionId == nil || $0.sessionId == nil)
        } : canonical
        return candidates.max { ($0.ratedAtTs ?? $0.startTs, $0.id) < ($1.ratedAtTs ?? $1.startTs, $1.id) }
    }

    static func remove(store: WhoopStore, entry: SessionRPEEntry) async -> Bool {
        (try? await store.deleteTrainingSessionRatings(sessionId: entry.sessionId, startTs: entry.startTs,
                                                       source: entry.source)) == true
    }

}
