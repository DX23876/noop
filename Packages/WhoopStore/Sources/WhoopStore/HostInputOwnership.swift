import Foundation
import GRDB

/// A legacy journal row retains its original source and exact question, including numeric zero and notes.
public struct LegacyJournalInput: Codable, Equatable {
    public let deviceId: String
    public let day: String
    public let question: String
    public let answeredYes: Bool
    public let notes: String?
    public let numericValue: Double?

    public init(deviceId: String, day: String, question: String, answeredYes: Bool,
                notes: String?, numericValue: Double?) {
        self.deviceId = deviceId; self.day = day; self.question = question
        self.answeredYes = answeredYes; self.notes = notes; self.numericValue = numericValue
    }
}

extension WhoopStore {
    public static let androidJournalHydrationOwnership = "android-journal-hydration-v1"

    public func ownsAndroidJournalHydration() async throws -> Bool {
        try syncRead { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM hostInputOwnership WHERE key = ?)",
                              arguments: [Self.androidJournalHydrationOwnership]) ?? false
        }
    }

    /// Takes a complete legacy snapshot once, atomically with its ownership marker. Existing core values
    /// win conflicts, so an imported backup or newer explicit answer cannot be overwritten by older Room data.
    /// The caller must obtain both complete legacy reads successfully before invoking this operation.
    @discardableResult
    public func adoptAndroidJournalHydration(journal: [LegacyJournalInput], hydration: [MetricPoint]) async throws -> Bool {
        try syncWrite { db in
            let owned = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM hostInputOwnership WHERE key = ?)",
                                          arguments: [Self.androidJournalHydrationOwnership]) ?? false
            guard !owned else { return false }
            for row in journal {
                try db.execute(sql: """
                    INSERT INTO journal (deviceId, day, question, answeredYes, notes, numericValue)
                    VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(deviceId, day, question) DO NOTHING
                    """, arguments: [row.deviceId, row.day, row.question, row.answeredYes, row.notes, row.numericValue])
            }
            for row in hydration {
                guard ["hydration", "hydrationImported"].contains(row.key), row.value.isFinite else {
                    throw HostInputOwnershipError.invalidHydration
                }
                try db.execute(sql: """
                    INSERT INTO metricSeries (deviceId, day, key, value) VALUES ('hydration', ?, ?, ?)
                    ON CONFLICT(deviceId, day, key) DO NOTHING
                    """, arguments: [row.day, row.key, row.value])
            }
            try Self.sealAndroidJournalHydration(in: db)
            return true
        }
    }

    static func sealAndroidJournalHydration(in db: Database) throws {
        try db.execute(sql: "INSERT INTO hostInputOwnership (key) VALUES (?) ON CONFLICT(key) DO NOTHING",
                       arguments: [androidJournalHydrationOwnership])
    }
}

public enum HostInputOwnershipError: Error { case invalidHydration }
