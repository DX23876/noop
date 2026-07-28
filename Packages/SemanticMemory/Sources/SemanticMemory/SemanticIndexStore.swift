import Foundation
import GRDB

public actor SemanticIndexStore {
    public static let schemaVersion = 1

    private let database: DatabaseQueue
    private let databaseURL: URL?

    public init(path: String) throws {
        databaseURL = URL(fileURLWithPath: path)
        database = try DatabaseQueue(path: path)
        try Self.migrate(database)
    }

    public init(inMemory: Bool) throws {
        databaseURL = nil
        database = try DatabaseQueue()
        try Self.migrate(database)
    }

    private static func migrate(_ writer: any DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "semanticDocument") { table in
                table.column("documentId", .text).primaryKey()
                table.column("sourceKind", .text).notNull()
                table.column("sourceId", .text).notNull()
                table.column("chunkIndex", .integer).notNull()
                table.column("contentHash", .text).notNull()
                table.column("updatedAt", .double).notNull()
                table.column("consentScope", .text).notNull()
                table.column("priority", .integer).notNull().defaults(to: 0)
                table.column("modelId", .text)
                table.column("dimensions", .integer)
                table.column("vector", .blob)
                table.column("pending", .boolean).notNull().defaults(to: true)
            }
            try db.create(index: "idx_semanticDocument_pending_priority",
                          on: "semanticDocument",
                          columns: ["pending", "priority", "updatedAt"])
            try db.create(index: "idx_semanticDocument_source",
                          on: "semanticDocument",
                          columns: ["sourceKind", "sourceId"])
            try db.create(index: "idx_semanticDocument_scope",
                          on: "semanticDocument",
                          columns: ["consentScope"])
            try db.create(table: "semanticState") { table in
                table.column("key", .text).primaryKey()
                table.column("value", .text).notNull()
            }
        }
        try migrator.migrate(writer)
    }

    public func enqueue(_ documents: [SemanticDocument]) throws {
        guard !documents.isEmpty else { return }
        try database.write { db in
            for document in documents {
                try db.execute(
                    sql: """
                        INSERT INTO semanticDocument
                            (documentId, sourceKind, sourceId, chunkIndex, contentHash, updatedAt,
                             consentScope, priority, modelId, dimensions, vector, pending)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, 1)
                        ON CONFLICT(documentId) DO UPDATE SET
                            sourceKind = excluded.sourceKind,
                            sourceId = excluded.sourceId,
                            chunkIndex = excluded.chunkIndex,
                            contentHash = excluded.contentHash,
                            updatedAt = excluded.updatedAt,
                            consentScope = excluded.consentScope,
                            priority = excluded.priority,
                            modelId = CASE WHEN semanticDocument.contentHash = excluded.contentHash
                                           THEN semanticDocument.modelId ELSE NULL END,
                            dimensions = CASE WHEN semanticDocument.contentHash = excluded.contentHash
                                              THEN semanticDocument.dimensions ELSE NULL END,
                            vector = CASE WHEN semanticDocument.contentHash = excluded.contentHash
                                          THEN semanticDocument.vector ELSE NULL END,
                            pending = CASE WHEN semanticDocument.contentHash = excluded.contentHash
                                           THEN semanticDocument.pending ELSE 1 END
                        """,
                    arguments: [
                        document.documentID,
                        document.sourceKind.rawValue,
                        document.sourceID,
                        document.chunkIndex,
                        document.contentHash,
                        document.updatedAt.timeIntervalSince1970,
                        document.consentScope.rawValue,
                        document.priority,
                    ]
                )
            }
        }
    }

    public func pending(limit: Int) throws -> [PendingSemanticDocument] {
        try database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT documentId, sourceKind, sourceId, chunkIndex, contentHash, updatedAt,
                           consentScope, priority
                    FROM semanticDocument
                    WHERE pending = 1
                    ORDER BY priority DESC, updatedAt DESC
                    LIMIT ?
                    """,
                arguments: [max(0, limit)]
            ).compactMap(PendingSemanticDocument.init(row:))
        }
    }

    public func storeEmbedding(documentID: String,
                               contentHash: String,
                               modelID: String,
                               vector: [Float]) throws {
        let encoded = SemanticVector.encodeFloat16(vector)
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE semanticDocument
                    SET modelId = ?, dimensions = ?, vector = ?, pending = 0
                    WHERE documentId = ? AND contentHash = ?
                    """,
                arguments: [modelID, vector.count, encoded, documentID, contentHash]
            )
        }
    }

    public func search(vector: [Float],
                       allowedScopes: Set<SemanticConsentScope>,
                       limit: Int) throws -> [SemanticHit] {
        guard !allowedScopes.isEmpty, limit > 0 else { return [] }
        let scopeValues = allowedScopes.map(\.rawValue)
        let placeholders = Array(repeating: "?", count: scopeValues.count).joined(separator: ",")
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT documentId, sourceKind, sourceId, chunkIndex, consentScope, vector
                    FROM semanticDocument
                    WHERE pending = 0 AND vector IS NOT NULL
                      AND consentScope IN (\(placeholders))
                    """,
                arguments: StatementArguments(scopeValues)
            )
            return rows.compactMap { row -> SemanticHit? in
                guard let data: Data = row["vector"],
                      let candidate = SemanticVector.decodeFloat16(data),
                      candidate.count == vector.count,
                      let kind = SemanticSourceKind(rawValue: row["sourceKind"]),
                      let scope = SemanticConsentScope(rawValue: row["consentScope"])
                else { return nil }
                return SemanticHit(documentID: row["documentId"],
                                   sourceKind: kind,
                                   sourceID: row["sourceId"],
                                   chunkIndex: row["chunkIndex"],
                                   score: SemanticVector.cosine(vector, candidate),
                                   consentScope: scope)
            }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
        }
    }

    public func remove(sourceKind: SemanticSourceKind, sourceID: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM semanticDocument WHERE sourceKind = ? AND sourceId = ?",
                           arguments: [sourceKind.rawValue, sourceID])
        }
    }

    public func remove(scopes: Set<SemanticConsentScope>) throws {
        guard !scopes.isEmpty else { return }
        let values = scopes.map(\.rawValue)
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ",")
        try database.write { db in
            try db.execute(sql: "DELETE FROM semanticDocument WHERE consentScope IN (\(placeholders))",
                           arguments: StatementArguments(values))
        }
    }

    public func removeDocuments(notIn liveDocumentIDs: Set<String>,
                                sourceKinds: Set<SemanticSourceKind>) throws {
        guard !sourceKinds.isEmpty else { return }
        try database.write { db in
            let kindValues = sourceKinds.map(\.rawValue)
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT documentId FROM semanticDocument WHERE sourceKind IN (\(Array(repeating: "?", count: kindValues.count).joined(separator: ",")))",
                arguments: StatementArguments(kindValues)
            )
            for row in rows {
                let documentID: String = row["documentId"]
                if !liveDocumentIDs.contains(documentID) {
                    try db.execute(sql: "DELETE FROM semanticDocument WHERE documentId = ?",
                                   arguments: [documentID])
                }
            }
        }
    }

    public func invalidate(modelID: String, dimensions: Int) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE semanticDocument
                    SET pending = 1, modelId = NULL, dimensions = NULL, vector = NULL
                    WHERE modelId IS NULL OR modelId != ? OR dimensions IS NULL OR dimensions != ?
                    """,
                arguments: [modelID, dimensions]
            )
        }
    }

    public func clear() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM semanticDocument")
            try db.execute(sql: "DELETE FROM semanticState")
        }
        // Reclaim vector pages immediately. This is user-triggered from "Delete index", so leaving
        // an empty but still large SQLite file behind would make the action misleading.
        try database.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
            try db.checkpoint(.truncate)
        }
    }

    public func setState(_ value: String?, for key: String) throws {
        try database.write { db in
            if let value {
                try db.execute(
                    sql: """
                        INSERT INTO semanticState (key, value) VALUES (?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                        """,
                    arguments: [key, value]
                )
            } else {
                try db.execute(sql: "DELETE FROM semanticState WHERE key = ?", arguments: [key])
            }
        }
    }

    public func state(for key: String) throws -> String? {
        try database.read { db in
            try String.fetchOne(db,
                                sql: "SELECT value FROM semanticState WHERE key = ?",
                                arguments: [key])
        }
    }

    public func counts() throws -> (indexed: Int, pending: Int) {
        try database.read { db in
            let indexed = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM semanticDocument WHERE pending = 0 AND vector IS NOT NULL"
            ) ?? 0
            let pending = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM semanticDocument WHERE pending = 1"
            ) ?? 0
            return (indexed, pending)
        }
    }

    public func byteSize() -> Int64 {
        guard let databaseURL else { return 0 }
        return [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
            .reduce(into: 0) { total, path in
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            }
    }
}

public struct PendingSemanticDocument: Equatable, Sendable {
    public let documentID: String
    public let sourceKind: SemanticSourceKind
    public let sourceID: String
    public let chunkIndex: Int
    public let contentHash: String
    public let updatedAt: Date
    public let consentScope: SemanticConsentScope
    public let priority: Int

    fileprivate init?(row: Row) {
        guard let kind = SemanticSourceKind(rawValue: row["sourceKind"]),
              let scope = SemanticConsentScope(rawValue: row["consentScope"])
        else { return nil }
        documentID = row["documentId"]
        sourceKind = kind
        sourceID = row["sourceId"]
        chunkIndex = row["chunkIndex"]
        contentHash = row["contentHash"]
        updatedAt = Date(timeIntervalSince1970: row["updatedAt"])
        consentScope = scope
        priority = row["priority"]
    }
}
