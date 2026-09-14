import Foundation
import GRDB

/// One deliberate whole-session effort rating. Workout and rating timestamps stay separate so the
/// app can report whether the preferred delayed sRPE protocol was followed without invalidating a
/// useful immediate or late answer.
public struct TrainingSessionRating: Equatable, Codable, Sendable {
    public var id: String
    public var sessionId: String?
    public var workoutStartTs: Int
    public var ratedAtTs: Int?
    public var rpe: Double
    public var sport: String?
    public var source: String

    public init(id: String, sessionId: String?, workoutStartTs: Int, ratedAtTs: Int?,
                rpe: Double, sport: String?, source: String) {
        self.id = id
        self.sessionId = sessionId
        self.workoutStartTs = workoutStartTs
        self.ratedAtTs = ratedAtTs
        self.rpe = rpe
        self.sport = sport
        self.source = source
    }

    fileprivate static func decode(_ row: Row) -> TrainingSessionRating {
        TrainingSessionRating(id: row["id"], sessionId: row["sessionId"],
                              workoutStartTs: row["workoutStartTs"], ratedAtTs: row["ratedAtTs"],
                              rpe: row["rpe"], sport: row["sport"], source: row["source"])
    }
}

extension WhoopStore {
    public func upsertTrainingSessionRating(_ rating: TrainingSessionRating) async throws {
        guard rating.rpe.isFinite, (1...10).contains(rating.rpe) else { return }
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO trainingSessionRating
                  (id, sessionId, workoutStartTs, ratedAtTs, rpe, sport, source)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET sessionId=excluded.sessionId,
                  workoutStartTs=excluded.workoutStartTs, ratedAtTs=excluded.ratedAtTs,
                  rpe=excluded.rpe, sport=excluded.sport, source=excluded.source
                """, arguments: [rating.id, rating.sessionId, rating.workoutStartTs,
                                   rating.ratedAtTs, rating.rpe, rating.sport, rating.source])
        }
    }

    public func trainingSessionRatings(from: Int, to: Int) async throws -> [TrainingSessionRating] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM trainingSessionRating
                WHERE workoutStartTs >= ? AND workoutStartTs <= ?
                ORDER BY workoutStartTs, COALESCE(ratedAtTs, workoutStartTs), id
                """, arguments: [from, to]).map(TrainingSessionRating.decode)
        }
    }

    @discardableResult
    public func deleteTrainingSessionRating(id: String) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM trainingSessionRating WHERE id = ?", arguments: [id])
            return db.changesCount > 0
        }
    }
}
