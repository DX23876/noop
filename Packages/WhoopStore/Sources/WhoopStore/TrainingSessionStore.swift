import Foundation
import GRDB

public struct WorkoutSourceMetadataRow: Equatable, Codable, Sendable {
    public let componentKey: String
    public let source: String
    public let startTs: Int
    public let sport: String
    public let externalId: String?
    public let sourceBundleId: String?
    public let rawActivityType: Int?
    public let activitiesJSON: String?
    public let updatedAtTs: Int

    public init(componentKey: String, source: String, startTs: Int, sport: String,
                externalId: String?, sourceBundleId: String?, rawActivityType: Int?,
                activitiesJSON: String?, updatedAtTs: Int) {
        self.componentKey = componentKey; self.source = source; self.startTs = startTs; self.sport = sport
        self.externalId = externalId; self.sourceBundleId = sourceBundleId
        self.rawActivityType = rawActivityType; self.activitiesJSON = activitiesJSON
        self.updatedAtTs = updatedAtTs
    }
}

public struct WorkoutHeartRateBucketRow: Equatable, Codable, Sendable {
    public let componentKey: String
    public let bucketStart: Int
    public let bpm: Double
    public let sourceBundleId: String?
    public init(componentKey: String, bucketStart: Int, bpm: Double, sourceBundleId: String?) {
        self.componentKey = componentKey; self.bucketStart = bucketStart
        self.bpm = bpm; self.sourceBundleId = sourceBundleId
    }
}

public struct TrainingSessionLinkRow: Equatable, Codable, Sendable {
    public let componentKey: String
    public let sessionId: String
    public let origin: String
    public let updatedAtTs: Int
    public init(componentKey: String, sessionId: String, origin: String, updatedAtTs: Int) {
        self.componentKey = componentKey; self.sessionId = sessionId
        self.origin = origin; self.updatedAtTs = updatedAtTs
    }
}

public struct TrainingSessionPreferenceRow: Equatable, Codable, Sendable {
    public let sessionId: String
    public let activityKind: String?
    public let primaryComponentKey: String?
    public let updatedAtTs: Int
    public init(sessionId: String, activityKind: String?, primaryComponentKey: String?, updatedAtTs: Int) {
        self.sessionId = sessionId; self.activityKind = activityKind
        self.primaryComponentKey = primaryComponentKey; self.updatedAtTs = updatedAtTs
    }
}

public struct TrainingSessionPairDecisionRow: Equatable, Codable, Sendable {
    public let leftKey: String
    public let rightKey: String
    public let decision: String
    public let updatedAtTs: Int
    public init(leftKey: String, rightKey: String, decision: String, updatedAtTs: Int) {
        self.leftKey = min(leftKey, rightKey); self.rightKey = max(leftKey, rightKey)
        self.decision = decision; self.updatedAtTs = updatedAtTs
    }
}

extension WhoopStore {
    public func upsertWorkoutSourceMetadata(_ rows: [WorkoutSourceMetadataRow]) async throws {
        guard !rows.isEmpty else { return }
        try syncWrite { db in
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO workoutSourceMetadata
                      (componentKey, source, startTs, sport, externalId, sourceBundleId,
                       rawActivityType, activitiesJSON, updatedAtTs)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(componentKey) DO UPDATE SET
                      source=excluded.source, startTs=excluded.startTs, sport=excluded.sport,
                      externalId=excluded.externalId, sourceBundleId=excluded.sourceBundleId,
                      rawActivityType=excluded.rawActivityType, activitiesJSON=excluded.activitiesJSON,
                      updatedAtTs=excluded.updatedAtTs
                    """, arguments: [r.componentKey, r.source, r.startTs, r.sport, r.externalId,
                                      r.sourceBundleId, r.rawActivityType, r.activitiesJSON, r.updatedAtTs])
            }
        }
    }

    public func workoutSourceMetadata(from: Int, to: Int) async throws -> [WorkoutSourceMetadataRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM workoutSourceMetadata WHERE startTs >= ? AND startTs <= ? ORDER BY startTs
                """, arguments: [from, to]).map { row in
                WorkoutSourceMetadataRow(componentKey: row["componentKey"], source: row["source"],
                    startTs: row["startTs"], sport: row["sport"], externalId: row["externalId"],
                    sourceBundleId: row["sourceBundleId"], rawActivityType: row["rawActivityType"],
                    activitiesJSON: row["activitiesJSON"], updatedAtTs: row["updatedAtTs"])
            }
        }
    }

    public func replaceWorkoutHeartRateBuckets(componentKey: String,
                                                rows: [WorkoutHeartRateBucketRow]) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM workoutHeartRateBucket WHERE componentKey = ?",
                           arguments: [componentKey])
            for r in rows where r.componentKey == componentKey && r.bpm.isFinite && r.bpm > 0 {
                try db.execute(sql: """
                    INSERT INTO workoutHeartRateBucket (componentKey, bucketStart, bpm, sourceBundleId)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [r.componentKey, r.bucketStart, r.bpm, r.sourceBundleId])
            }
        }
    }

    public func workoutHeartRateBuckets(componentKey: String) async throws -> [WorkoutHeartRateBucketRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM workoutHeartRateBucket WHERE componentKey = ? ORDER BY bucketStart
                """, arguments: [componentKey]).map { row in
                WorkoutHeartRateBucketRow(componentKey: row["componentKey"], bucketStart: row["bucketStart"],
                                          bpm: row["bpm"], sourceBundleId: row["sourceBundleId"])
            }
        }
    }

    public func upsertTrainingSessionLinks(_ rows: [TrainingSessionLinkRow]) async throws {
        guard !rows.isEmpty else { return }
        try syncWrite { db in
            for r in rows {
                try db.execute(sql: """
                    INSERT INTO trainingSessionLink (componentKey, sessionId, origin, updatedAtTs)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(componentKey) DO UPDATE SET sessionId=excluded.sessionId,
                      origin=excluded.origin, updatedAtTs=excluded.updatedAtTs
                    """, arguments: [r.componentKey, r.sessionId, r.origin, r.updatedAtTs])
            }
        }
    }

    public func trainingSessionLinks() async throws -> [TrainingSessionLinkRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM trainingSessionLink").map { row in
                TrainingSessionLinkRow(componentKey: row["componentKey"], sessionId: row["sessionId"],
                                       origin: row["origin"], updatedAtTs: row["updatedAtTs"])
            }
        }
    }

    public func upsertTrainingSessionPairDecision(_ row: TrainingSessionPairDecisionRow) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO trainingSessionPairDecision (leftKey, rightKey, decision, updatedAtTs)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(leftKey, rightKey) DO UPDATE SET decision=excluded.decision,
                  updatedAtTs=excluded.updatedAtTs
                """, arguments: [row.leftKey, row.rightKey, row.decision, row.updatedAtTs])
        }
    }

    public func trainingSessionPairDecisions() async throws -> [TrainingSessionPairDecisionRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM trainingSessionPairDecision").map { row in
                TrainingSessionPairDecisionRow(leftKey: row["leftKey"], rightKey: row["rightKey"],
                    decision: row["decision"], updatedAtTs: row["updatedAtTs"])
            }
        }
    }

    public func upsertTrainingSessionPreference(_ row: TrainingSessionPreferenceRow) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO trainingSessionPreference (sessionId, activityKind, primaryComponentKey, updatedAtTs)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(sessionId) DO UPDATE SET activityKind=excluded.activityKind,
                  primaryComponentKey=excluded.primaryComponentKey, updatedAtTs=excluded.updatedAtTs
                """, arguments: [row.sessionId, row.activityKind, row.primaryComponentKey, row.updatedAtTs])
        }
    }

    public func trainingSessionPreferences() async throws -> [TrainingSessionPreferenceRow] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM trainingSessionPreference").map { row in
                TrainingSessionPreferenceRow(sessionId: row["sessionId"], activityKind: row["activityKind"],
                    primaryComponentKey: row["primaryComponentKey"], updatedAtTs: row["updatedAtTs"])
            }
        }
    }
}
