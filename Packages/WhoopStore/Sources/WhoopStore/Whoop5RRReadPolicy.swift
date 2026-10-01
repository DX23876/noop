import GRDB
import WhoopProtocol

extension WhoopStore {
    /// The WHOOP 5 channels that carry an explicit unit label on every beat, as a SQL list: labelled v18
    /// history (5) and labelled standard 0x2A37 (7). Type-40 live (6) is a labelling channel that standard
    /// BLE already covers beat for beat, so it does not count as the start of labelled history.
    static let labelledWhoop5Channels = "(5, 7)"

    /// #2371: marks the strap's 500 ms fill beats in one device's ts window. `insert` runs it after a batch
    /// that carries a 500 ms WHOOP 5 beat, once that batch's heart rate is on disk.
    ///
    /// A WHOOP 5/MG emits an exact 500 ms interval (120 bpm) as a filler at rest, on both scored
    /// transports: v18 history (5) and standard BLE (7). On one 5.0's backup (443,896 beats, 28 Sep 2026),
    /// split by the strap's own heart rate in the same second, 500 ms occurred 33-37 times as often as its
    /// neighbours (495-499, 501-505 ms) at 80-94 bpm, 3 times at 95-99, and no more often than them from
    /// 100 bpm up (1.7x on four beats at 100-104, none at 105-109, 1.0x at 110-124). Below 100 bpm a
    /// 500 ms beat would be at least 17% shorter than the mean interval of its second.
    ///
    /// The row is MARKED `tsSuspect = 1`, the flag every scoring read already filters (#1073), never
    /// deleted: it stays on disk, so the fill stays inspectable. A beat whose second has no heart rate is
    /// left alone, since nothing then says it is a fill. One literal, not a composition; upstream's Kotlin
    /// twin is `WHOOP5_RR_FILL_FLAG_SQL`.
    static let whoop5RrFillFlagSQL = "UPDATE rrInterval SET tsSuspect = 1 WHERE deviceId = :deviceId AND ts >= :fromTs AND ts <= :toTs AND rrMs = 500 AND srcChannel IN (5, 7) AND tsSuspect IS NULL AND EXISTS (SELECT 1 FROM hrSample h WHERE h.deviceId = rrInterval.deviceId AND h.ts = rrInterval.ts AND h.bpm < 100)"

    /// Marks every stored fill beat once, in `v74-rr-whoop5-fill` (upstream v47): the condition of
    /// `whoop5RrFillFlagSQL` over the whole table.
    static let whoop5RrFillMigrationSQL = "UPDATE rrInterval SET tsSuspect = 1 WHERE rrMs = 500 AND srcChannel IN (5, 7) AND tsSuspect IS NULL AND EXISTS (SELECT 1 FROM hrSample h WHERE h.deviceId = rrInterval.deviceId AND h.ts = rrInterval.ts AND h.bpm < 100)"

    /// The earliest beat this device has banked on a labelled channel, or nil when it has none.
    ///
    /// A DIAGNOSTIC fact, not a scoring gate: `rrIntervals` scores unlabelled beats too, per beat, wherever
    /// no labelled observation covers them (see `RRTransportReconciler`). Carries the same suspect-timestamp
    /// exclusion as the scoring read (#1073).
    public func firstLabelledWhoop5RRTimestamp(deviceId: String) async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT MIN(ts) FROM rrInterval
                WHERE deviceId = ? AND srcChannel IN \(Self.labelledWhoop5Channels)
                AND (tsSuspect IS NULL OR tsSuspect <> 1)
                """, arguments: [deviceId])
        }
    }

    /// The earliest beat this device has banked AT ALL, labelled or not, or nil when it has none. Same
    /// shape and same suspect exclusion as the labelled read above.
    public func firstRecordedRRTimestamp(deviceId: String) async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT MIN(ts) FROM rrInterval
                WHERE deviceId = ? AND (tsSuspect IS NULL OR tsSuspect <> 1)
                """, arguments: [deviceId])
        }
    }

    /// Shared by RR reads and consumers whose cached/union reads must obey the same owner policy.
    public func isWhoop5RRSource(deviceId: String, unlabelledAliasOfWhoop5: Bool = false) async throws -> Bool {
        try syncRead { try Self.isWhoop5RRSource(db: $0, deviceId: deviceId,
                                              unlabelledAliasOfWhoop5: unlabelledAliasOfWhoop5) }
    }

    static func isWhoop5RRSource(db: Database, deviceId: String,
                               unlabelledAliasOfWhoop5: Bool = false) throws -> Bool {
        let row = try Row.fetchOne(db, sql: "SELECT model, brand FROM pairedDevice WHERE id = ?",
                                   arguments: [deviceId])
        let model: String? = row?["model"]
        let brand: String? = row?["brand"]
        // Only unknown identity needs wire evidence. Avoid scanning tagged rows for a known family.
        let knownFamily = DeviceFamily.confirmedRegistryFamily(model: model, brand: brand)
        let nonWhoop = brand.map { !$0.isEmpty && $0.lowercased() != "whoop" } ?? false
        var tagged = false
        if knownFamily == nil && !nonWhoop {
            tagged = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM rrInterval WHERE deviceId = ? AND srcChannel IN (5, 6, 7))
                """, arguments: [deviceId]) ?? false
            // Re-pairing can leave legacy rows under the canonical alias while callers still hold
            // that old ID. Resolve its active strap here so sleep edits and ordinary reads agree.
            // Physical owners and confirmed WHOOP 4 history never inherit another strap's policy.
            if !tagged && !unlabelledAliasOfWhoop5 && deviceId == "my-whoop",
               let active = try String.fetchOne(db, sql: DeviceRegistryStore.activeDeviceIdSQL),
               active != deviceId {
                tagged = try isWhoop5RRSource(db: db, deviceId: active)
            }
        }
        return Whoop5RR.usesCanonicalSource(model: model, brand: brand, hasTaggedIntervals: tagged || unlabelledAliasOfWhoop5)
    }
}
