import Foundation
import GRDB
import StrandTraining

public struct TrainingExerciseAnatomyAlias: Equatable, Codable, Sendable {
    public let key: String
    public let source: TrainingRecordSource
    public let sourceExerciseId: String?
    public let normalizedTitle: String
    public let equipmentKey: String?
    public let anatomy: ExerciseAnatomy
    public let origin: String
    public let updatedAtTs: Int

    public init(key: String, source: TrainingRecordSource, sourceExerciseId: String? = nil,
                normalizedTitle: String, equipmentKey: String? = nil, anatomy: ExerciseAnatomy,
                origin: String, updatedAtTs: Int = Int(Date().timeIntervalSince1970)) {
        self.key = key
        self.source = source
        self.sourceExerciseId = sourceExerciseId
        self.normalizedTitle = normalizedTitle
        self.equipmentKey = equipmentKey
        self.anatomy = anatomy
        self.origin = origin
        self.updatedAtTs = updatedAtTs
    }
}

extension WhoopStore {
    public func upsertTrainingExerciseAnatomyAlias(_ alias: TrainingExerciseAnatomyAlias) async throws {
        let encoder = JSONEncoder()
        func json(_ values: [String]) -> String {
            (try? encoder.encode(values)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO trainingExerciseAnatomyAlias
                  (key, source, sourceExerciseId, normalizedTitle, equipmentKey, canonicalExerciseId,
                   primaryMuscleIdsJSON, secondaryMuscleIdsJSON, stabilizerMuscleIdsJSON,
                   origin, confidence, updatedAtTs)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                  source=excluded.source, sourceExerciseId=excluded.sourceExerciseId,
                  normalizedTitle=excluded.normalizedTitle, equipmentKey=excluded.equipmentKey,
                  canonicalExerciseId=excluded.canonicalExerciseId,
                  primaryMuscleIdsJSON=excluded.primaryMuscleIdsJSON,
                  secondaryMuscleIdsJSON=excluded.secondaryMuscleIdsJSON,
                  stabilizerMuscleIdsJSON=excluded.stabilizerMuscleIdsJSON,
                  origin=excluded.origin, confidence=excluded.confidence, updatedAtTs=excluded.updatedAtTs
                """, arguments: [alias.key, alias.source.rawValue, alias.sourceExerciseId,
                                   alias.normalizedTitle, alias.equipmentKey, alias.anatomy.id,
                                   json(alias.anatomy.primaryMuscleIds), json(alias.anatomy.secondaryMuscleIds),
                                   json(alias.anatomy.stabilizerMuscleIds), alias.origin,
                                   alias.anatomy.confidence.rawValue, alias.updatedAtTs])
        }
    }

    public func trainingExerciseAnatomyAliases() async throws -> [TrainingExerciseAnatomyAlias] {
        try syncRead { db in
            let decoder = JSONDecoder()
            func ids(_ raw: String) -> [String] {
                (try? decoder.decode([String].self, from: Data(raw.utf8))) ?? []
            }
            return try Row.fetchAll(db, sql: """
                SELECT * FROM trainingExerciseAnatomyAlias
                ORDER BY CASE origin WHEN 'user' THEN 0 ELSE 1 END, updatedAtTs DESC
                """).map { row in
                    let primary = ids(row["primaryMuscleIdsJSON"] as String)
                    let secondary = ids(row["secondaryMuscleIdsJSON"] as String)
                    let stabilizers = ids(row["stabilizerMuscleIdsJSON"] as String)
                    let anatomy = ExerciseAnatomy(
                        id: row["canonicalExerciseId"], title: row["normalizedTitle"],
                        mode: .weightReps, movementPattern: .other,
                        primaryMuscleIds: primary, secondaryMuscleIds: secondary,
                        stabilizerMuscleIds: stabilizers,
                        confidence: ExerciseMappingConfidence(rawValue: row["confidence"])
                            ?? .userConfirmed)
                    return TrainingExerciseAnatomyAlias(
                        key: row["key"],
                        source: TrainingRecordSource(rawValue: row["source"]) ?? .imported,
                        sourceExerciseId: row["sourceExerciseId"],
                        normalizedTitle: row["normalizedTitle"], equipmentKey: row["equipmentKey"],
                        anatomy: anatomy, origin: row["origin"], updatedAtTs: row["updatedAtTs"])
                }
        }
    }
}
