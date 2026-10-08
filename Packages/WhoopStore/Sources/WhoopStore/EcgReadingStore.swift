import Foundation
import GRDB

/// One saved WHOOP MG ECG reading: the strap's own result for a completed reading plus where its
/// accepted window came from. Everything here is what the strap reported; NOOP computes no rhythm
/// classification, and the category is OpenStrap's result-plus-heart-rate table (see `EcgCategory`).
public struct EcgReadingRow: Equatable, Sendable, Identifiable {
    public let id: String
    public let deviceId: String
    /// "left" or "right": the wrist the reading was taken on.
    public let wrist: String
    /// Phone clock, unix seconds: when the accepted window opened and when the terminal packet arrived.
    public let startTs: Int
    public let endTs: Int
    /// The terminal packet's strap clock, seconds.
    public let strapTerminalTs: Int?
    public let resultCode: Int
    /// `EcgCategory.rawValue`, from the result code and the final average heart rate.
    public let category: String
    public let averageHr: Int?
    /// The strap's variability field after the verdict. It behaves like RMSSD in ms on one MG (#891), but
    /// no unit is established, so it is kept raw.
    public let variabilityRaw: Int?
    public let quality: Int?
    public let unreadableMask: Int
    public let interruptions: Int
    public let sampleCount: Int
    public let missingSegments: Int
    /// "completed" or "inconclusive".
    public let status: String
    /// 100 Hz filtered input-referred integer microvolts, as the strap sent them.
    public static let sampleRateHz = 100

    public init(id: String, deviceId: String, wrist: String, startTs: Int, endTs: Int, strapTerminalTs: Int?,
                resultCode: Int, category: String, averageHr: Int?, variabilityRaw: Int?, quality: Int?,
                unreadableMask: Int, interruptions: Int, sampleCount: Int, missingSegments: Int,
                status: String) {
        self.id = id
        self.deviceId = deviceId
        self.wrist = wrist
        self.startTs = startTs
        self.endTs = endTs
        self.strapTerminalTs = strapTerminalTs
        self.resultCode = resultCode
        self.category = category
        self.averageHr = averageHr
        self.variabilityRaw = variabilityRaw
        self.quality = quality
        self.unreadableMask = unreadableMask
        self.interruptions = interruptions
        self.sampleCount = sampleCount
        self.missingSegments = missingSegments
        self.status = status
    }

    fileprivate init(row: Row) {
        self.init(id: row["id"], deviceId: row["deviceId"], wrist: row["wrist"], startTs: row["startTs"],
                  endTs: row["endTs"], strapTerminalTs: row["strapTerminalTs"], resultCode: row["resultCode"],
                  category: row["category"], averageHr: row["averageHr"], variabilityRaw: row["variabilityRaw"],
                  quality: row["quality"], unreadableMask: row["unreadableMask"],
                  interruptions: row["interruptions"], sampleCount: row["sampleCount"],
                  missingSegments: row["missingSegments"], status: row["status"])
    }
}

/// One accepted packet of a saved reading, or the empty placeholder that marks a sequence jump.
public struct EcgReadingPacketRow: Equatable, Sendable {
    public let sequence: Int
    public let strapSeconds: Int?
    public let strapSubseconds: Int?
    public let isPlaceholder: Bool
    public let samples: [Int16]

    public init(sequence: Int, strapSeconds: Int?, strapSubseconds: Int?, isPlaceholder: Bool,
                samples: [Int16]) {
        self.sequence = sequence
        self.strapSeconds = strapSeconds
        self.strapSubseconds = strapSubseconds
        self.isPlaceholder = isPlaceholder
        self.samples = samples
    }

    /// Signed 16-bit little-endian, exactly as the strap sent them.
    static func encode(_ samples: [Int16]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let bits = UInt16(bitPattern: sample)
            data.append(UInt8(bits & 0xFF))
            data.append(UInt8(bits >> 8))
        }
        return data
    }

    static func decode(_ data: Data) -> [Int16] {
        let bytes = [UInt8](data)
        return stride(from: 0, to: bytes.count - 1, by: 2).map {
            Int16(bitPattern: UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8)
        }
    }
}

extension WhoopStore {
    static func createEcgReadingTables(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE ecgReading (
                id TEXT NOT NULL PRIMARY KEY,
                deviceId TEXT NOT NULL,
                wrist TEXT NOT NULL,
                startTs INTEGER NOT NULL,
                endTs INTEGER NOT NULL,
                strapTerminalTs INTEGER,
                resultCode INTEGER NOT NULL,
                category TEXT NOT NULL,
                averageHr INTEGER,
                variabilityRaw INTEGER,
                quality INTEGER,
                unreadableMask INTEGER NOT NULL,
                interruptions INTEGER NOT NULL,
                sampleCount INTEGER NOT NULL,
                missingSegments INTEGER NOT NULL,
                status TEXT NOT NULL
            )
            """)
        try db.execute(sql: "CREATE INDEX ecgReading_startTs ON ecgReading(startTs)")
        try db.execute(sql: """
            CREATE TABLE ecgReadingPacket (
                readingId TEXT NOT NULL REFERENCES ecgReading(id) ON DELETE CASCADE,
                position INTEGER NOT NULL,
                sequence INTEGER NOT NULL,
                strapSeconds INTEGER,
                strapSubseconds INTEGER,
                isPlaceholder INTEGER NOT NULL,
                samples BLOB NOT NULL,
                PRIMARY KEY (readingId, position)
            )
            """)
    }

    /// Save a reading and its window in one transaction, so a reading is never listed without its trace.
    public func saveEcgReading(_ reading: EcgReadingRow, packets: [EcgReadingPacketRow]) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO ecgReading (id, deviceId, wrist, startTs, endTs, strapTerminalTs,
                    resultCode, category, averageHr, variabilityRaw, quality, unreadableMask, interruptions,
                    sampleCount, missingSegments, status)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [reading.id, reading.deviceId, reading.wrist, reading.startTs, reading.endTs,
                                 reading.strapTerminalTs, reading.resultCode, reading.category,
                                 reading.averageHr, reading.variabilityRaw, reading.quality,
                                 reading.unreadableMask, reading.interruptions, reading.sampleCount,
                                 reading.missingSegments, reading.status])
            try db.execute(sql: "DELETE FROM ecgReadingPacket WHERE readingId = ?", arguments: [reading.id])
            for (position, packet) in packets.enumerated() {
                try db.execute(sql: """
                    INSERT INTO ecgReadingPacket (readingId, position, sequence, strapSeconds,
                        strapSubseconds, isPlaceholder, samples)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [reading.id, position, packet.sequence, packet.strapSeconds,
                                     packet.strapSubseconds, packet.isPlaceholder ? 1 : 0,
                                     EcgReadingPacketRow.encode(packet.samples)])
            }
        }
    }

    /// The strap reports its variability a few seconds after the verdict; it lands on the saved row here.
    public func updateEcgReadingVariability(id: String, variabilityRaw: Int) async throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE ecgReading SET variabilityRaw = ? WHERE id = ?",
                           arguments: [variabilityRaw, id])
        }
    }

    /// Every saved reading, newest first.
    public func ecgReadings() async throws -> [EcgReadingRow] {
        try await asyncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM ecgReading ORDER BY startTs DESC").map(EcgReadingRow.init(row:))
        }
    }

    /// One reading's window, in order.
    public func ecgReadingPackets(id: String) async throws -> [EcgReadingPacketRow] {
        try await asyncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM ecgReadingPacket WHERE readingId = ? ORDER BY position
                """, arguments: [id]).map { row in
                EcgReadingPacketRow(sequence: row["sequence"], strapSeconds: row["strapSeconds"],
                                    strapSubseconds: row["strapSubseconds"],
                                    isPlaceholder: (row["isPlaceholder"] as Int? ?? 0) != 0,
                                    samples: EcgReadingPacketRow.decode(row["samples"] ?? Data()))
            }
        }
    }

    public func deleteEcgReading(id: String) async throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM ecgReading WHERE id = ?", arguments: [id])
        }
    }
}
