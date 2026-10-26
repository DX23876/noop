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
    static let manualSource = "manual-session-rpe"

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
}
