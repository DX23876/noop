import Foundation
import GRDB

/// One deliberate whole-session effort rating. Workout and rating timestamps stay separate so the
/// app can report whether the preferred delayed sRPE protocol was followed without invalidating a
/// useful immediate or late answer.
public struct TrainingSessionRating: Equatable, Codable, Sendable {
    public static let manualSource = "manual-session-rpe"

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
        try syncWrite { try Self.upsertTrainingSessionRating(rating, in: $0) }
    }

    /// A deliberate edit replaces this source's other ratings of the same canonical session atomically.
    /// An unrelated canonical session sharing the timestamp is never overwritten by its legacy id.
    public func replaceTrainingSessionRating(_ rating: TrainingSessionRating) async throws -> Bool {
        guard rating.rpe.isFinite, (1...10).contains(rating.rpe) else { return false }
        return try syncWrite { db in
            try Self.replaceTrainingSessionRating(rating, in: db)
        }
    }

    static func replaceTrainingSessionRating(_ rating: TrainingSessionRating, in db: Database) throws -> Bool {
        if let previous = try Row.fetchOne(db, sql: "SELECT source, sessionId FROM trainingSessionRating WHERE id = ?", arguments: [rating.id]) {
            let source: String = previous["source"]
            let session: String? = previous["sessionId"]
            guard source == rating.source, session == nil || session == rating.sessionId else { return false }
        }
        try deleteTrainingSessionRatings(sessionId: rating.sessionId, startTs: rating.workoutStartTs,
                                         source: rating.source, in: db)
        try upsertTrainingSessionRating(rating, in: db)
        return true
    }

    /// Removes only the named source's rating and its canonical aliases; the workout is untouched.
    public func deleteTrainingSessionRatings(sessionId: String?, startTs: Int, source: String) async throws -> Bool {
        try syncWrite { db in
            try Self.deleteTrainingSessionRatings(sessionId: sessionId, startTs: startTs, source: source, in: db)
            return db.changesCount > 0
        }
    }

    private static func deleteTrainingSessionRatings(sessionId: String?, startTs: Int, source: String, in db: Database) throws {
        if let sessionId {
            try db.execute(sql: """
                DELETE FROM trainingSessionRating WHERE source = ? AND
                  (sessionId = ? OR (sessionId IS NULL AND workoutStartTs = ?))
                """, arguments: [source, sessionId, startTs])
        } else {
            try db.execute(sql: "DELETE FROM trainingSessionRating WHERE source = ? AND sessionId IS NULL AND workoutStartTs = ?",
                           arguments: [source, startTs])
        }
    }

    private static func upsertTrainingSessionRating(_ rating: TrainingSessionRating, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO trainingSessionRating
              (id, sessionId, workoutStartTs, ratedAtTs, rpe, sport, source)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET sessionId=excluded.sessionId,
              workoutStartTs=excluded.workoutStartTs, ratedAtTs=excluded.ratedAtTs,
              rpe=excluded.rpe, sport=excluded.sport, source=excluded.source
            """, arguments: [rating.id, rating.sessionId, rating.workoutStartTs, rating.ratedAtTs,
                               rating.rpe, rating.sport, rating.source])
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
