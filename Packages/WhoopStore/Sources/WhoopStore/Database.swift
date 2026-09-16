import Foundation
import GRDB

extension WhoopStore {
    /// The schema migrator. v1 creates decoded-stream tables (durable) + the raw outbox.
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "device") { t in
                t.column("id", .text).primaryKey()
                t.column("mac", .text)
                t.column("name", .text)
                t.column("firstSeen", .integer)
                t.column("lastSeen", .integer)
            }
            try db.create(table: "hrSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("bpm", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "rrInterval") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("rrMs", .integer).notNull()
                t.primaryKey(["deviceId", "ts", "rrMs"])
            }
            try db.create(table: "event") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("payloadJSON", .text).notNull()
                t.primaryKey(["deviceId", "ts", "kind"])
            }
            try db.create(table: "battery") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("soc", .double)
                t.column("mv", .integer)
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "rawBatch") { t in
                t.column("batchId", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("capturedAt", .integer).notNull()
                t.column("deviceClockRef", .integer).notNull()
                t.column("wallClockRef", .integer).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("frameCount", .integer).notNull()
                t.column("byteSize", .integer).notNull()
                t.column("framesBlob", .blob).notNull()
                t.column("syncedAt", .integer)
            }
        }
        migrator.registerMigration("v2") { db in
            try db.create(table: "cursors") { t in
                t.column("name", .text).primaryKey()
                t.column("value", .integer)
            }
        }
        migrator.registerMigration("v3") { db in
            // type-47 biometric streams (mirror the existing decoded tables, PK (deviceId, ts)).
            try db.create(table: "spo2Sample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("red", .integer).notNull()
                t.column("ir", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "skinTempSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("raw", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "respSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("raw", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
            try db.create(table: "gravitySample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("x", .double).notNull()
                t.column("y", .double).notNull()
                t.column("z", .double).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }
        migrator.registerMigration("v4") { db in
            // Server-derived metrics cached locally (Task 3.1: History = union(phone, server)).
            // sleepSession: one row per sleep session, natural key (deviceId, startTs).
            try db.create(table: "sleepSession") { t in
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("efficiency", .double)
                t.column("restingHr", .integer)
                t.column("avgHrv", .double)
                t.column("stagesJSON", .text)
                t.primaryKey(["deviceId", "startTs"])
            }
            // dailyMetric: one row per calendar day (YYYY-MM-DD), natural key (deviceId, day).
            try db.create(table: "dailyMetric") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("totalSleepMin", .double)
                t.column("efficiency", .double)
                t.column("deepMin", .double)
                t.column("remMin", .double)
                t.column("lightMin", .double)
                t.column("disturbances", .integer)
                t.column("restingHr", .integer)
                t.column("avgHrv", .double)
                t.column("recovery", .double)
                t.column("strain", .double)
                t.column("exerciseCount", .integer)
                t.primaryKey(["deviceId", "day"])
            }
        }
        migrator.registerMigration("v5") { db in
            // Per-row upload sync flag for the decoded streams (mirrors rawBatch.syncedAt).
            // The OLD upload path used a forward-only highwater per stream, which permanently
            // stranded backfilled (older-ts) rows once the highwater jumped to a recent ts.
            // The fix: `synced` is set to 1 only after a successful upload, so the Uploader can
            // drain WHERE synced=0 regardless of ts order. Existing rows default to 0 → they
            // re-upload once (idempotent server-side), catching up the currently-stranded rows.
            for table in ["hrSample", "rrInterval", "event", "battery",
                          "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
                try db.alter(table: table) { t in
                    t.add(column: "synced", .integer).notNull().defaults(to: 0)
                }
            }
        }
        migrator.registerMigration("v6") { db in
            // Charging flag for the dense BATTERY_LEVEL-event battery series (nullable: the
            // command-response battery path doesn't report it).
            try db.alter(table: "battery") { t in
                t.add(column: "charging", .boolean)
            }
        }
        migrator.registerMigration("v7") { db in
            // In-sleep signal aggregates cached from /v1/daily so the Sleep tab can display
            // SpO2, skin-temperature deviation, and respiration rate without a network round-trip.
            // All three are nullable: they require sufficient raw biometric data on the server.
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "spo2Pct", .double)
                t.add(column: "skinTempDevC", .double)
                t.add(column: "respRateBpm", .double)
            }
        }
        migrator.registerMigration("v8") { db in
            // Journal, workouts, and Apple-Health daily aggregates.
            // journal: one row per (deviceId, day, question), user-answered daily prompts.
            try db.create(table: "journal") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("question", .text).notNull()
                t.column("answeredYes", .integer).notNull()
                t.column("notes", .text)
                t.primaryKey(["deviceId", "day", "question"])
            }
            // workout: one row per (deviceId, startTs, sport). All metric columns nullable.
            try db.create(table: "workout") { t in
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("sport", .text).notNull()
                t.column("source", .text).notNull()
                t.column("durationS", .double)
                t.column("energyKcal", .double)
                t.column("avgHr", .integer)
                t.column("maxHr", .integer)
                t.column("strain", .double)
                t.column("distanceM", .double)
                t.column("zonesJSON", .text)
                t.column("notes", .text)
                t.primaryKey(["deviceId", "startTs", "sport"])
            }
            // appleDaily: Apple-Health-specific daily aggregates, one row per (deviceId, day).
            // All metric columns nullable.
            try db.create(table: "appleDaily") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("steps", .integer)
                t.column("activeKcal", .double)
                t.column("basalKcal", .double)
                t.column("vo2max", .double)
                t.column("avgHr", .integer)
                t.column("maxHr", .integer)
                t.column("walkingHr", .integer)
                t.column("weightKg", .double)
                t.primaryKey(["deviceId", "day"])
            }
        }
        migrator.registerMigration("v9") { db in
            // Generic long-format metric store: the substrate for a metric explorer where every
            // metric is queryable/comparable uniformly. One row per (deviceId, day, key); `value`
            // is always a REAL so any scalar metric (server-derived, Apple-Health, journal-encoded,
            // …) can be projected into a single tall table and read back by key with no per-metric
            // schema. Natural key (deviceId, day, key).
            try db.create(table: "metricSeries") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("key", .text).notNull()
                t.column("value", .double).notNull()
                t.primaryKey(["deviceId", "day", "key"])
            }
            // Per-metric range reads scan (deviceId, key) then walk days in order. The PK is
            // (deviceId, day, key) so it can't serve those reads efficiently; this index makes
            // metricSeries(key:from:to:) and metricDays(key:) index-only.
            try db.create(index: "idx_metricSeries_device_key_day",
                          on: "metricSeries", columns: ["deviceId", "key", "day"])
        }

        // v10 (#78): WHOOP5 step_motion_counter persistence (macOS parity with Android's MIGRATION_2_3).
        // Additive only, the strap trims acked history and won't re-send it, so a destructive rebuild
        // would lose it; this preserves every existing row. No `synced` column (unused; see StreamStore).
        migrator.registerMigration("v10") { db in
            try db.create(table: "stepSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("counter", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v11: on-device daily step total + whole-day calorie estimate on dailyMetric (macOS parity
        // with Android's MIGRATION_2_3). Additive only; both nullable, so existing rows are untouched
        // and an old reader that doesn't SELECT them keeps working.
        migrator.registerMigration("v11") { db in
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "steps", .integer)
                t.add(column: "activeKcalEst", .double)
            }
        }

        // v12 (#156): PPG-derived per-second HR from the WHOOP 5.0 v26 optical buffer. Stored in its OWN
        // table (not hrSample) so the measured `hr` is never conflated with the derived estimate, reads
        // COALESCE hrSample first, ppgHrSample only where hrSample has no row. Additive only; bpm/conf
        // are REAL (bpm is a float estimate, conf is the 0–1 autocorrelation peak).
        migrator.registerMigration("v12") { db in
            try db.create(table: "ppgHrSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("bpm", .double).notNull()
                t.column("conf", .double).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v13 (#318-adjacent): user-corrected sleep times. A `userEdited` flag on sleepSession marks a
        // session whose wake/sleep bounds the user fixed by hand; the post-sync recompute pass preserves
        // those bounds instead of re-upserting the strap-detected session over them (mirrors Android's
        // `userEdited` guard in IntelligenceEngine, PR #367). Additive + nullable-safe: NOT NULL DEFAULT 0
        // so every existing row reads as un-edited and old readers that don't SELECT it keep working.
        migrator.registerMigration("v13") { db in
            try db.alter(table: "sleepSession") { t in
                t.add(column: "userEdited", .boolean).notNull().defaults(to: false)
            }
        }

        // v14 (#318): user-corrected sleep ONSET. `startTs` stays the immutable detected key (so the
        // recompute guard and daily override keep matching on it); the hand-set bedtime lives here.
        // Nullable, null means "onset not edited, use startTs". Additive, so existing rows/readers are
        // unaffected.
        migrator.registerMigration("v14") { db in
            try db.alter(table: "sleepSession") { t in
                t.add(column: "startTsAdjusted", .integer)
            }
        }

        // v15: the device registry. `deviceId` already keys every sample table (deviceId, ts), so it IS
        // the per-device discriminator, this just gives each device a row with brand/model/capabilities,
        // a single-active invariant (enforced in DeviceRegistryStore), and a dayOwnership override table so
        // one source owns a day's scores (never blended). Additive: the existing WHOOP is seeded with its
        // unchanged id "my-whoop" (zero sample-row migration). INSERT OR IGNORE so re-runs/restores are safe.
        migrator.registerMigration("v15-device-registry") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS pairedDevice (
                    id TEXT PRIMARY KEY NOT NULL,
                    brand TEXT NOT NULL, model TEXT NOT NULL, nickname TEXT,
                    sourceKind TEXT NOT NULL, capabilities TEXT NOT NULL,  -- comma-joined Metric rawValues
                    status TEXT NOT NULL, addedAt INTEGER NOT NULL, lastSeenAt INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS dayOwnership (
                    day TEXT PRIMARY KEY NOT NULL,   -- "YYYY-MM-DD" local day
                    deviceId TEXT NOT NULL,          -- which device owns this day's displayed/scored metrics
                    locked INTEGER NOT NULL DEFAULT 0 -- 1 = explicit (import-overlap decision / user); 0 = resolver default
                );
            """)
            // Seed the registry with the existing WHOOP so nothing is orphaned. selectedWhoopModel lives in
            // the app's UserDefaults; the store can't read it, so seed a neutral "WHOOP" row the app reconciles
            // on first launch from the live model.
            let now = Int(Date().timeIntervalSince1970)
            try db.execute(sql: """
                INSERT OR IGNORE INTO pairedDevice (id, brand, model, nickname, sourceKind, capabilities, status, addedAt, lastSeenAt)
                VALUES ('my-whoop', 'WHOOP', 'WHOOP', NULL, 'liveBLE', 'hr,hrv,spo2,skinTemp,sleep,strainLoad', 'active', \(now), \(now));
            """)
        }

        // v16: stable per-strap identity for multi-WHOOP support. `peripheralId` holds the BLE
        // CBPeripheral.identifier.uuidString (iOS/Mac) so NOOP can tell physical straps apart and
        // map a connected peripheral back to its registry row. Additive + nullable: the seeded
        // 'my-whoop' row keeps peripheralId NULL (it still connects to "any WHOOP" today; it adopts
        // its peripheral id later). New straps get id "whoop-<peripheralId>". Old readers that don't
        // SELECT it keep working.
        migrator.registerMigration("v16-paired-device-peripheral") { db in
            try db.execute(sql: "ALTER TABLE pairedDevice ADD COLUMN peripheralId TEXT")
        }

        // v17 (Lab Book): the Health Records "marker" store, one row per dated reading the USER
        // entered themselves (spec 2026-06-19-v5-health-records-design.md §"New"). This is the richer
        // source-of-truth behind the daily `metricSeries` projection: a single day can hold several
        // readings, each carries a precise `takenAt` instant and `unit`, and notes / qualitative
        // (`valueText`) results don't fit a REAL-only `metricSeries` cell. Additive only, a NEW table,
        // no existing row touched, so an old reader is unaffected.
        //
        // NON-CLINICAL: holds ONLY user-entered values + an OPTIONAL user-entered `referenceText`
        // (their own report's range, shown back verbatim). NOOP ships no reference-range tables and
        // never asserts normality.
        //
        // `id` is a client-generated stable identifier (so a single reading can be edited/deleted by id
        // and a backup round-trips). The natural key (deviceId, markerKey, takenAt, source) is enforced
        // by a UNIQUE index so re-importing the same reading is idempotent. `value` is nullable (a
        // qualitative entry stores only `valueText`); `day` is the pre-derived yyyy-MM-dd key for the
        // projection. The (deviceId, markerKey, takenAt) index serves per-marker history reads in order.
        migrator.registerMigration("v17-lab-book") { db in
            try db.create(table: "labMarker") { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("markerKey", .text).notNull()
                t.column("category", .text).notNull()
                t.column("day", .text).notNull()              // yyyy-MM-dd (projection key)
                t.column("takenAt", .integer).notNull()       // epoch seconds (precise instant)
                t.column("value", .double)                    // nullable: qualitative entries use valueText
                t.column("valueText", .text)
                t.column("unit", .text).notNull()
                t.column("source", .text).notNull()
                t.column("note", .text)
                t.column("referenceText", .text)              // user-entered range, verbatim
            }
            // Idempotent re-import: one reading per (deviceId, markerKey, takenAt, source).
            try db.create(index: "idx_labMarker_natural",
                          on: "labMarker",
                          columns: ["deviceId", "markerKey", "takenAt", "source"],
                          unique: true)
            // Per-marker history reads scan (deviceId, markerKey) then walk takenAt in order.
            try db.create(index: "idx_labMarker_device_marker_takenAt",
                          on: "labMarker", columns: ["deviceId", "markerKey", "takenAt"])
            // Per-category grouping for the Lab Book screen.
            try db.create(index: "idx_labMarker_device_category",
                          on: "labMarker", columns: ["deviceId", "category"])
        }

        // v18 (H8 + H2-persist): per-SLEEP-SESSION analytics the stager/interpreter already compute then
        // discard, banked alongside the existing `stagesJSON` on the same row (deviceId, startTs).
        //   • `motionJSON`, a compact JSON array of per-epoch motion magnitudes (the SleepStager's
        //                        per-epoch restlessness signal), one entry per stage epoch, SAME 30 s grid
        //                        as `stagesJSON`. Persisting it lets restlessness/wake-fragmentation read a
        //                        real per-epoch series instead of recomputing the whole stager.
        //   • `sleepStateJSON`, a compact JSON array of the decoded v18 band state per epoch (the
        //                        Interpreter's `(sb>>4)&3`), so the strap's own banked sleep/wake band is
        //                        durable rather than dropped after decode (H2 persist half).
        // Both nullable TEXT: every existing row reads back null (no per-epoch series yet), old readers that
        // don't SELECT them keep working, and a session with no raw/banked epoch data simply stores null,         // an ABSENT signal stays absent, never a fabricated zero series. Additive ALTERs only (no data
        // touched), so already-offloaded raw streams survive (the strap trims acked history and won't
        // re-send it). Twin of Android's MIGRATION_11_12.
        migrator.registerMigration("v18-sleep-motion-state") { db in
            try db.alter(table: "sleepSession") { t in
                t.add(column: "motionJSON", .text)
                t.add(column: "sleepStateJSON", .text)
            }
        }

        // v19 (#316 / @63 activity class): the per-record activity-class enum the decoder ALREADY reads off
        // @63 (0=still, 1=walk, 2=run; 0xFF/invalid stores nothing) but which was DROPPED at the storage
        // boundary, `StepSample` carried `activityClass` yet the v10 stepSample INSERT only listed
        // (deviceId, ts, counter), so it could never be persisted, read, or shown. This ALTER adds a NULLABLE
        // `activityClass INTEGER` to stepSample: additive only, no DEFAULT (a null means "no class for this
        // record", an absent signal stays absent, never a fabricated 0/"still"), so every existing row reads
        // back null and an old reader that doesn't SELECT it keeps working. Already-offloaded raw streams
        // survive (the strap trims acked history and won't re-send it). Twin of Android's MIGRATION_12_13.
        migrator.registerMigration("v19-step-activity-class") { db in
            try db.alter(table: "stepSample") { t in
                t.add(column: "activityClass", .integer)
            }
        }

        // v20 (#322 / task #53 numeric journal): a journal entry can carry a NUMERIC value (e.g.
        // "caffeine mg", "alcohol units") alongside the yes/no answer, not only a toggle. This ALTER adds
        // a NULLABLE `numericValue REAL` to `journal`: additive only, no DEFAULT (a null means "this row is
        // a plain yes/no answer with no numeric reading", which is every existing row + every imported WHOOP
        // row, so history reads back unchanged). A numeric log writes answeredYes=1 AND numericValue=v, so
        // the existing BehaviorInsights with/without split keeps working untouched; the value is carried for
        // dose-response later. Twin of Android's MIGRATION_13_14.
        migrator.registerMigration("v20-journal-numeric") { db in
            try db.alter(table: "journal") { t in
                t.add(column: "numericValue", .double)
            }
        }

        // v21 (#175 band sleep-state stream): the strap's OWN per-record band sleep_state (Interpreter's
        // @81 `(sb>>4)&3`: 0 wake / 1 still / 2 asleep / 3 up) was DECODED but DROPPED at stream extraction —
        // so the whole band-state chain (the H7 morning-stillness re-onset CONFIRM guard + a Deep Timeline
        // display track) had no source, and the v18 `sleepStateJSON` per-session column was never fed. This
        // adds the RAW per-sample table, keyed by (deviceId, ts) exactly like stepSample/ppgHrSample, so a
        // second's band state is idempotently upserted (ON CONFLICT DO NOTHING) from the offload stream. New
        // table only (no existing data touched); already-offloaded history the strap has trimmed can't be
        // re-sent, so this is forward-looking for straps that emit the field (5/MG v18). `state` is the raw
        // 0-3 code carried VERBATIM — never a fabricated value; a strap that never reports it just has no rows.
        // Twin of Android's MIGRATION_14_15.
        migrator.registerMigration("v21-sleep-state-sample") { db in
            try db.create(table: "sleepStateSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("state", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v22 (Live Sessions): one row per silent-guardian coaching session. Natural key (deviceId, startTs).
        // Records the recovery-gated band it guarded (floor/ceiling bpm) + today's Charge at start, the time
        // split (in-band / below / above seconds), the two cue counts, and the HR source used, so the look-back
        // summary + the streak read entirely from here. `endTs` is nullable while a session is in progress
        // (a crash/kill leaves it open; the app closes it on next launch). All totals NOT NULL DEFAULT 0 so a
        // zero-length session reads cleanly. Additive, NEW table only (no existing row touched), so an old
        // reader is unaffected. See docs/superpowers/specs/2026-07-04-live-sessions-design.md. Twin of
        // Android's MIGRATION_15_16.
        migrator.registerMigration("v22-live-session") { db in
            try db.create(table: "liveSession") { t in
                t.column("deviceId", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer)
                t.column("chargeAtStart", .double)
                t.column("floorBpm", .double).notNull()
                t.column("ceilingBpm", .double).notNull()
                t.column("inBandSec", .double).notNull().defaults(to: 0)
                t.column("belowSec", .double).notNull().defaults(to: 0)
                t.column("aboveSec", .double).notNull().defaults(to: 0)
                t.column("pushCount", .integer).notNull().defaults(to: 0)
                t.column("easeCount", .integer).notNull().defaults(to: 0)
                t.column("hrSource", .text).notNull()
                t.primaryKey(["deviceId", "startTs"])
            }
        }
        migrator.registerMigration("v23-daily-spo2-raw") { db in
            // WHOOP 4.0 raw SpO2 PPG ADC means (red/IR) over detected sleep, cached beside the other
            // in-sleep aggregates (#93). ADDITIVE, mirroring v7's SpO2/skin-temp/resp add: two nullable
            // INTEGER columns. Existing rows read NULL (no rebuild, no data loss), so an older database
            // upgraded in place is unaffected — non-4.0 nights + pre-upgrade rows simply stay nil.
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "spo2Red", .integer)
                t.add(column: "spo2Ir", .integer)
            }
        }
        migrator.registerMigration("v24-rr-seq") { db in
            // Widen rrInterval's PK to (deviceId, ts, rrMs, seq). The value-only key + ON CONFLICT DO
            // NOTHING silently dropped the second of two EQUAL successive R-R intervals in one 1-second
            // ts bucket, removing a zero-difference beat and biasing RMSSD/HRV high at rest/sleep (when
            // HRV is scored). `seq` distinguishes equal (ts, rrMs) beats; distinct beats keep seq 0.
            // Android parity: Room v18 (#163). SQLite can't ALTER a PK, so REBUILD — LOSS-LESS: every row
            // copied with seq = 0, exact because the old PK made (deviceId, ts, rrMs) unique per row.
            // Forward-only: already-dropped beats can't be recovered. rrInterval is a leaf table (no FKs
            // in or out), so the drop/rename is safe.
            try db.create(table: "rrInterval_new") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("rrMs", .integer).notNull()
                t.column("seq", .integer).notNull().defaults(to: 0)
                t.column("synced", .integer).notNull().defaults(to: 0)
                t.primaryKey(["deviceId", "ts", "rrMs", "seq"])
            }
            try db.execute(sql: """
                INSERT INTO rrInterval_new (deviceId, ts, rrMs, seq, synced)
                SELECT deviceId, ts, rrMs, 0, synced FROM rrInterval
                """)
            try db.execute(sql: "DROP TABLE rrInterval")
            try db.execute(sql: "ALTER TABLE rrInterval_new RENAME TO rrInterval")
        }

        // v25: Oura live-API raw payload archive (lossless) behind the opt-in cloud import. One row per
        // fetched page, keyed (deviceId, endpoint, documentId); payloadJSON holds the verbatim page body
        // so any field can be re-derived later without re-fetching from the API. Additive only — a NEW
        // table, no existing row touched, old readers unaffected. Numbered v25: upstream's v24-rr-seq
        // landed in the same window and registers first to keep the sequence.
        migrator.registerMigration("v25-oura-raw") { db in
            try db.create(table: "ouraRaw") { t in
                t.column("deviceId", .text).notNull()
                t.column("endpoint", .text).notNull()       // "sleep" | "daily_readiness" | "heartrate" | …
                t.column("documentId", .text).notNull()     // synthesized page key (endpoint + window + index)
                t.column("day", .text)                       // YYYY-MM-DD when day-keyed (nullable)
                t.column("payloadJSON", .text).notNull()     // verbatim page body
                t.column("fetchedAt", .integer).notNull()    // unix seconds
                t.primaryKey(["deviceId", "endpoint", "documentId"])
            }
            // Per-endpoint reads scan (deviceId, endpoint) then walk day in order.
            try db.create(index: "idx_ouraRaw_device_endpoint_day",
                          on: "ouraRaw", columns: ["deviceId", "endpoint", "day"])
        }

        // v26 (Oura efficiency unit heal): the Oura API importer (OuraApiParser.swift) wrote Oura's
        // native 0-100 integer `efficiency` straight into sleepSession.efficiency / dailyMetric.efficiency,
        // but NOOP's own sleep pipeline (StrandAnalytics) stores that shared column as a 0-1 FRACTION
        // everywhere it computes it (asleep ÷ in-bed) — same column, two scales for oura-api rows written
        // before the importer fix. UPDATE-only, NO schema change: divides `efficiency` by 100 for every
        // row where it's > 1.5 — a threshold no genuine fraction can exceed (the column's convention
        // caps at 1.0: `AnalyticsEngine` writes actual-sleep ÷ in-bed) and no genuine percent-scale
        // leftover can fall under (no real night is ≤1.5% efficient), so the predicate can't touch an
        // already-correct row and a second run finds nothing left: idempotent. Deliberately NOT
        // deviceId-scoped: both known percent writers are healed by the same predicate — the Oura API
        // importer ('oura-api' rows) and the WHOOP CSV importer (rows under whatever strap deviceId the
        // user imported into). No Android Room migration twin in this PR: the Kotlin CSV importer gets
        // the same write-boundary fix, but healing Android's historical rows needs a Room migration a
        // maintainer should own (schema-version bump + column-order pinning).
        migrator.registerMigration("v26-efficiency-heal") { db in
            try db.execute(sql: """
                UPDATE sleepSession SET efficiency = efficiency / 100.0
                WHERE efficiency > 1.5
                """)
            try db.execute(sql: """
                UPDATE dailyMetric SET efficiency = efficiency / 100.0
                WHERE efficiency > 1.5
                """)
        }

        // v27 (issue #156 follow-up): durable storage for the WHOOP 5.0 v26 optical PPG waveform. The
        // strap's 24 Hz buffer was fully DECODED (`ppg_waveform`, 24 i16 ADC samples/record) but only
        // ever used to derive a per-second HR estimate (`ppgHrSample`, v12) — the waveform itself was
        // discarded right after, and `rejectedHistoricalRecords` explicitly excludes v26 from the
        // undecodable-record reject archive ("known-and-unstored by design"), so it had no home at all.
        //
        // One row per (deviceId, ts) — the SAME shape as every other per-second decoded stream (hrSample,
        // spo2Sample, ppgHrSample, …) — but the 24 samples are packed into a compact BLOB (2 bytes/sample,
        // little-endian i16, `WhoopStore.packPpgSamples`/`unpackPpgSamples`) instead of 24 scalar rows.
        // That keeps a v26-heavy night to roughly the same order of magnitude as ONE extra per-second
        // stream (≈50 bytes/row), not 24x that. Additive only, a NEW table, no existing row touched.
        //
        // Retention: CAPPED at `WhoopStore.ppgWaveformRetentionRows` newest rows per device (#1911), swept
        // amortised on insert exactly like `v18AuxSample`. This table is the ONE exception to "no durable
        // per-second table is pruned" (hrSample, spo2Sample, … are still never pruned), because it is the
        // only one storing a blob rather than a scalar: ~120 B/row against ~30 B. It is the worst ROW, not
        // the biggest table — v26 runs only in optical windows (~28,800 rows/day) where `rrInterval` banks
        // ~100,000/day, so most of #1911's ~93 MB/day is still unbounded elsewhere. `PrunePolicy`'s
        // ~50 MB cap governs ONLY `rawBatch` (raw, pre-decode frames kept for re-decode / re-sync); it is
        // untouched by and unrelated to this table.
        //
        // The cap is NEWEST-N-ROWS, not an age-based drop, and that distinction is load-bearing for the
        // consumer note below: a sporadic wearer's v26 seconds are spread thin over months, so deleting by
        // wall-clock age would empty the table for exactly the user a future estimator needs most, while
        // newest-N always leaves a full working set. See `ppgWaveformRetentionRows` for the byte maths and
        // for why #1911's "diagnostic-only, drop after the hot window" framing was not followed.
        //
        // CONSUMER STATUS — deliberately none, and stated here so nobody has to re-derive it. The writer is
        // live on both platforms (offload + archive replay + the Android capture importer), but the reader
        // `ppgWaveformSamples` has ZERO production callers on either platform: five test call sites on the
        // Swift side, none at all on Android. No analytic, no UI, no export, no diagnostic reads a waveform
        // row. That is the intended shape — the project's rule is to land unvalidated sensor work as
        // instrumentation (decode + store, never a score; see CLAUDE.md and the withdrawn #194 PPG->HR
        // estimate), and this table exists so a BETTER estimator, HRV-from-PPG, or a waveform viewer can
        // later run over the ORIGINAL samples rather than the derived bpm. Do NOT "clean up" the reader as
        // dead code: the rows are the point, and the reader is how they are reachable.
        //
        // Note the sharp distinction from `ppgHrSample` (v12), which is the DERIVED per-second HR estimate
        // and IS fully consumed in production (COALESCEd with measured HR in the primary series). The
        // derivation happens in memory inside `extractHistoricalStreams` and never reads back from this
        // table, so these rows are not on any scoring path at all.
        migrator.registerMigration("v27-ppg-waveform") { db in
            try db.create(table: "ppgWaveformSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("samples", .blob).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // #423: WHOOP 5/MG raw-IMU offload capture (100 Hz 6-axis). `samples` is a packed i16 LE BLOB of
        // the six wire columns (ax…az,gx…gz). Twin of the Android `rawImuSample` table (MIGRATION_20_21);
        // same column order + PK so a `.noopbak` round-trips byte-for-byte.
        //
        // Historical rolling cache. Its opt-in writer retained at most 3,600 one-second rows, but no analytics,
        // UI or export consumed them. v41 retires those legacy rows after file-backed capture replaces the cache.
        migrator.registerMigration("v28-raw-imu") { db in
            try db.create(table: "rawImuSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("samples", .blob).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v29: provenance for NOOP-computed headline scores. This is deliberately separate from
        // `dayOwnership`: ownership controls which device is allowed to supply a day's raw inputs,
        // while this table records which source actually supplied each persisted computed metric.
        // Metric-level keys keep mixed-source days honest and make missing legacy metadata explicit.
        migrator.registerMigration("v29-score-input-provenance") { db in
            try db.create(table: "scoreInputProvenance") { t in
                t.column("deviceId", .text).notNull()   // computed "-noop" namespace
                t.column("day", .text).notNull()
                t.column("key", .text).notNull()
                t.column("sourceId", .text).notNull()
                t.primaryKey(["deviceId", "day", "key"])
            }
            try db.create(index: "idx_scoreInputProvenance_source",
                          on: "scoreInputProvenance", columns: ["sourceId"])
        }

        // v30 (#823): record each R-R beat's EMISSION order within its second. Reads ordered by
        // `rrMs`, i.e. by VALUE, which makes successive beats similar by construction and biases
        // RMSSD — built entirely from successive differences — DOWNWARD. `seq` cannot serve here:
        // it counts repeats of an identical (ts, rrMs) beat, so every DISTINCT beat in a second
        // carries seq 0 and they all tie.
        //
        // Additive nullable column, no table rebuild, no existing row touched. Deliberately NOT in
        // the primary key, which stays (deviceId, ts, rrMs, seq) from v24 — an insertion counter in
        // the key would collide distinct beats arriving in separate batches, the data-loss
        // regression the v24 note warns about. `ord` only informs read order.
        //
        // Pre-v30 rows stay NULL: the order was never recorded, so it cannot be backfilled and a
        // guess would be worse than an admission. SQLite sorts NULL first in ASC, so an all-NULL
        // second ties on `ord` and falls through to the old (rrMs, seq) order, unchanged.
        //
        // Twin of Room MIGRATION_23_24. Both stores are SQLite, so NULL-ordering matches exactly.
        migrator.registerMigration("v30-rr-ord") { db in
            try db.alter(table: "rrInterval") { t in
                t.add(column: "ord", .integer)
            }
        }

        // v31: stop DISCARDING four per-second channels the 5/MG v18 decoder already produces.
        //
        // `extractHistoricalStreams` is a narrow funnel — a field the Interpreter decodes but the funnel
        // does not name is computed and dropped one line later. That drop is PERMANENT: the strap trims
        // its banked history as soon as NOOP acks the offload, so the seconds are not re-fetchable. The
        // four channels below have been decoded (and pinned by the cross-platform decoder oracle) since
        // the v18 layout was mapped, and stored nowhere.
        //
        //   gravitySample.dynAccel    `dynamic_acceleration@41` (f32 g) — the strap's OWN gravity-removed
        //                             motion magnitude, computed on-device from the full-rate IMU. NOOP's
        //                             motion spine instead derives stillness from `gravityDeltas`, the L2
        //                             distance between consecutive 1 Hz gravity vectors. That proxy sees
        //                             orientation CHANGE at 1 Hz, not acceleration, so the two are not the
        //                             same measurement; this column puts the strap's own number BESIDE the
        //                             incumbent, which is the only way a later comparison on real nights
        //                             becomes possible.
        //   sleepStateSample.rawByte  the WHOLE @81 flag byte. v21 stored only `(byte >> 4) & 3` as
        //                             `state`; b0-1 `onwrist` and b2-3 `wake_quality` are decoded and were
        //                             dropped, and b6-7 have no interpretation at all (0 across every
        //                             capture held here). `state` is untouched, so #175 behavior is
        //                             bit-identical.
        //   skinTempSample.aux1Raw    `temp_aux_1_raw@69` / `temp_aux_2_raw@71` (i16, °C = value/10, a
        //   skinTempSample.aux2Raw    DIFFERENT scale from the primary's /100). Two further thermal
        //                             channels that track the primary closely (corr ~0.92 / ~0.97) with
        //                             the same diurnal curve.
        //
        // Additive nullable ALTERs only: no table rebuild, no row touched, no key changed. Every existing
        // row reads back NULL and an old reader that does not SELECT the columns is unaffected. NULL is
        // load-bearing here and no column carries a DEFAULT — a WHOOP 4.0 never emits any of these, and
        // history banked before this migration cannot be backfilled (the strap already trimmed it), so an
        // absent channel must stay absent rather than become a fabricated 0.
        //
        // INSTRUMENTATION ONLY. Nothing reads these columns: no analytic, no score, no gate, no UI. That
        // is deliberate — see the "validate against the artifact, not one match" rule in CLAUDE.md. The
        // point of this migration is that the data starts accruing NOW so a validated consumer is possible
        // LATER; landing a consumer at the same time would be scoring on evidence that does not exist yet.
        //
        // CONSUMER STATUS — deliberately none, stated here so nobody has to re-derive it, and in the same
        // shape as the `ppgWaveformSample` note above (v27). The writers are live on both platforms, but
        // every `v18AuxSamples` call site on BOTH platforms is a TEST: no analytic, no score, no gate, no
        // UI, no export reads a row. **Do NOT "clean up" the reader as dead code** — the rows are the point,
        // and the reader is how they become reachable once a consumer is validated. The same applies to the
        // four named columns added just below (`gravitySample.dynAccel`, `sleepStateSample.rawByte`,
        // `skinTempSample.aux1Raw/aux2Raw`): they are SELECTed into their structs, and no consumer touches
        // the properties, on purpose.
        //
        // Why the rows still matter even unread: before this migration these fields were not merely unread,
        // they were DESTROYED. The strap trims its history the moment an offload is acked, so every one of
        // them was unrecoverable. This migration converts permanent loss into retained-but-unread, which is
        // the whole fix and is complete. Fifteen of the slots are unpinned bytes whose names deliberately
        // assert nothing; wiring them to anything before a census would be exactly the overclaiming this
        // project has already had to retract. The capture IS the deliverable.
        //
        // The remaining fifteen v18 slots go to their OWN narrow table rather than fifteen more columns
        // (see `V18AuxCodec` for the wire format and the column-vs-blob tradeoff). Three reasons this is
        // a table and not another column on an existing row:
        //   1. No existing per-second table is guaranteed present. `gravitySample` needs `gravity_x` to
        //      decode, `skinTempSample` needs @73 to clear its thermal gate, `hrSample` skips bpm=0. A v18
        //      record can carry aux fields while every one of those gated out, so hanging the blob off any
        //      of them would silently drop records.
        //   2. It keeps fifteen unpinned bytes out of the tables analytics actually read.
        //   3. It can be dropped or re-shaped later without touching a scored table.
        // `fields` is NOT NULL because a row is only written when at least one slot is present — absence is
        // encoded as "no row", and within a row as a clear bitmap bit, never as a fabricated 0.
        //
        // Retention: `v18AuxSample` is CAPPED, `rawImuSample`-style, at `WhoopStore.v18AuxRetentionRows`
        // rows per device (rolling, newest-first). It is the only genuinely new row growth here — the four
        // named columns widen rows that were already being written (~14 B on a gravity/skinTemp/sleepState
        // row that exists either way) and add no rows at all, so they inherit whatever retention their
        // tables have. `PrunePolicy`'s ~50 MB cap governs only `rawBatch`. The table is also added to the
        // storage-stats readout, because visible growth and bounded growth are different guarantees and
        // an instrumentation table nothing reads should have both.
        //
        // Twin of Room MIGRATION_24_25.
        migrator.registerMigration("v31-deep-capture-channels") { db in
            try db.alter(table: "gravitySample") { t in
                t.add(column: "dynAccel", .double)
            }
            try db.alter(table: "sleepStateSample") { t in
                t.add(column: "rawByte", .integer)
            }
            try db.alter(table: "skinTempSample") { t in
                t.add(column: "aux1Raw", .integer)
                t.add(column: "aux2Raw", .integer)
            }
            try db.create(table: "v18AuxSample") { t in
                t.column("deviceId", .text).notNull()
                t.column("ts", .integer).notNull()
                t.column("fields", .blob).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }

        // v32 (#1071): record WHICH sensor channel produced each R-R beat.
        //
        // An Oura ring reports the SAME heartbeats on more than one tag, and every one of them decoded to
        // `OuraEvent.ibi` and landed here untagged. Measured over one 488-min sleep window: 61,524 beats
        // stored where the measured HR curve allows 29,800 (2.06x), and sum(rrMs)/wall-clock = 2.17x. The
        // two are separable after the fact only by the accident that their quantisation grids differ
        // (0x6E is `byte * 8`, always a multiple of 8; 0x80 is an 11-bit value on the 1 ms grid), and the
        // 8 ms stream is ABSENT until SpO2 measurement starts and then tracks its duty cycle exactly —
        // which is what proves these are two channels rather than accumulated re-syncs.
        //
        // The damage is to the VARIABILITY statistics, not the level: a duplicated beat train leaves
        // meanNN (and so resting HR) correct while RMSSD/SDNN are built entirely from successive
        // differences and collapse. The app's own `hrv diag` line has been reporting it as
        // `coverage=2.21 rrIntegrity=crossSecondOverCount` with a non-physiological ~200 ms nocturnal SDNN.
        //
        // NOT a de-duplication: both rows are real measurements of the same beat by different optics, and
        // the second channel is the obvious future cross-check on the first. So nothing is deleted and
        // nothing is rewritten — the column labels the source and `Reads.rrIntervals` filters at READ.
        //
        // Additive nullable column, the v30-rr-ord form: no table rebuild, no existing row touched, and
        // deliberately NOT in the primary key, which stays (deviceId, ts, rrMs, seq) from v24. Putting it
        // in the key would make the SAME beat insertable twice under two labels, the data-loss/duplication
        // regression the v24 note warns about from the other direction.
        //
        // Pre-v32 rows stay NULL and are still READ (a WHOOP row is legitimately NULL forever — one beat
        // source, no channel to name — so a filter that dropped NULL would silently delete every WHOOP
        // night from scoring). Historical Oura rows therefore keep their old inflated coverage; they were
        // never labelled, and a backfill would be a guess. For the record, since this is how the defect
        // was diagnosed: in an existing DB the two channels remain separable by `rrMs % 8`, an 0x6E row
        // always being a multiple of 8 and an 0x80 row landing there only 1 time in 8 by chance.
        //
        // Values are `RRSourceChannel.rawValue` (1 green / 2 spo2 / 3 ibiAmplitude), a DURABLE wire format
        // shared with Kotlin `RrSourceChannel`. INTEGER rather than a text label because `rrInterval` is
        // the highest-volume table in the schema (~60k rows a night) and this column rides every one.
        //
        // Twin of Room MIGRATION_25_26.
        migrator.registerMigration("v32-rr-src-channel") { db in
            try db.alter(table: "rrInterval") { t in
                t.add(column: "srcChannel", .integer)
            }
        }
        // #1058: per-session step count on a workout. Activity-file imports previously stored steps only
        // as a whole-day DailyMetric row keyed on (deviceId, day), so a SECOND file for the same day
        // overwrote the first's steps instead of adding. With steps on the session, the day total is
        // recomputed as SUM over that day's sessions — additive across files, idempotent on re-import.
        // Nullable; only foot-sport activity-file sessions populate it (a strap never writes it).
        migrator.registerMigration("v33-workout-steps") { db in
            try db.alter(table: "workout") { t in
                t.add(column: "steps", .integer)
            }
        }
        // #345 follow-up: per-session flag recording that a night was staged on SPARSE motion coverage
        // (`SleepStager.isGravitySparse`), so the Sleep tab can honestly caption "sleep may be incomplete"
        // when a sparse night likely under-detected (the "slept 8h, shows 1h" reports). Additive, nullable
        // (existing rows / imported nights read null = unknown, never flagged); not part of the primary
        // key. The v13 (`userEdited`) / v14 (`startTsAdjusted`) form. Byte-parity with Room MIGRATION_27_28.
        migrator.registerMigration("v34-sleep-staging-sparse") { db in
            // `.integer` (not `.boolean`) so the affinity is INTEGER on BOTH platforms — Room maps Kotlin
            // Boolean? to INTEGER too — and this column carries no `grdb-boolean-affinity` divergence.
            // The value is a 0/1 flag; GRDB binds/reads the Swift `Bool?` as 0/1 over an INTEGER column.
            try db.alter(table: "sleepSession") { t in
                t.add(column: "stagingSparse", .integer)
            }
        }
        // v35 (#1073): quarantine R-R beats whose timestamp is in the FUTURE. An Oura ring's history
        // timestamp is occasionally corrupt/misaligned and, before the OuraDriver gate was tightened to
        // "now", converted to a date years ahead (measured on a live ring: ~1,600 beats stamped 2026→2034)
        // and was banked — removed from the night it was measured in and queued to poison whichever future
        // day it lands on. The ingest gate now rejects such samples, but rows already stored have to be
        // taken out of scoring.
        //
        // NOT a delete: these are real heartbeats with a wrong timestamp, so — like the v32 srcChannel
        // form — the column MARKS them and `Reads.rrIntervals` filters at READ, keeping them inspectable
        // and recoverable if the ring-time offset is ever characterised (the migration rule warns against
        // window-wide deletes). `strftime('%s','now')` runs once, at migration time; new rows are gated at
        // ingest so never land future, and stay NULL. Additive nullable INTEGER, the v32 form: no table
        // rebuild, no existing key touched, NOT in the primary key.
        //
        // Twin of Room MIGRATION_28_29.
        migrator.registerMigration("v35-rr-future-quarantine") { db in
            try db.alter(table: "rrInterval") { t in
                t.add(column: "tsSuspect", .integer)
            }
            // CAST so the compare is numeric: `strftime` returns TEXT, and `ts` (INTEGER) > TEXT would
            // otherwise lean on SQLite's affinity coercion rather than being explicit.
            try db.execute(sql: "UPDATE rrInterval SET tsSuspect = 1 WHERE ts > CAST(strftime('%s','now') AS INTEGER)")
        }
        // v36 (#548): drop calibrated SpO₂ from WHOOP registry capabilities. Live NOOP never fills
        // spo2Pct from the strap (import-only / experimental @82 candidate); advertising `spo2` made
        // an empty Blood Oxygen tile look broken. Data-only UPDATE — no schema change. Twin of Room
        // MIGRATION_29_30. Decode-time strip in DeviceRegistryStore is the belt; this is the suspenders.
        migrator.registerMigration("v36-whoop-caps-no-spo2") { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, capabilities FROM pairedDevice
                    WHERE brand = 'WHOOP' OR id = 'my-whoop' OR id LIKE 'whoop-%'
                    """
            )
            for row in rows {
                let id: String = row["id"]
                let encoded: String = row["capabilities"]
                let stripped = WhoopLiveCapabilities.stripSpo2Token(fromEncoded: encoded)
                if stripped != encoded && !stripped.isEmpty {
                    try db.execute(
                        sql: "UPDATE pairedDevice SET capabilities = ? WHERE id = ?",
                        arguments: [stripped, id]
                    )
                }
            }
        }

        // v37: persist nightly SDNN — the 5-min SDNN index (broad-variability twin of avgHrv=RMSSD),
        // window-matched to a watch's short SDNN rather than the drift-inflated whole-night SD. Additive,
        // nullable; computed by HRVAnalyzer.sdnnIndex during the nightly analysis.
        //
        // Numbered v37: upstream migrations advanced to v36 (`v36-whoop-caps-no-spo2`) while this branch
        // was open, so this branch-local, never-shipped identifier is renumbered to the next free slot.
        // Renumbering an unshipped identifier is free (GRDB tracks applied migrations by id, not number);
        // renaming a SHIPPED one is not, so only this id moves.
        migrator.registerMigration("v37-daily-avg-sdnn") { db in
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "avgSdnn", .double)
            }
        }
        // The per-day input fingerprint the analyze scan skips on. `analyzeRecent` re-derives every day
        // in its window from the raw streams on every run — on a real library that is ~950 k rows per day
        // over 21 days, and the days are almost always unchanged (a 21-day window on an install with 35
        // scored days re-computes 20 days that nobody touched). This table records WHAT each day was
        // scored against, so an unchanged day can be skipped.
        //
        // Additive: a fresh table, no existing row is read or rewritten. An install upgrading to it has no
        // rows here, so the first pass scores every day exactly as before and fills the table as it goes —
        // the safe direction, because a MISSING fingerprint means "scan it", never "skip it".
        migrator.registerMigration("v38-day-scan-fingerprint") { db in
            try db.create(table: "dayScanFingerprint") { t in
                // The COMPUTED namespace the scored row belongs to ("<id>-noop"), so a second source's
                // scores keep their own fingerprints.
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                // The owner the day was READ from (I2: exactly one device owns a day). Part of the
                // comparison, not just provenance: if the resolved owner changes, the inputs changed even
                // when that owner's own row counts did not.
                t.column("ownerId", .text).notNull()
                // The raw-input fingerprint over the day's READ WINDOW — `hrFingerprint`'s (count, maxTs).
                // COUNT moves on any insert including a backfilled older night whose maxTs would not; maxTs
                // separates a fresh append from a re-count. Together they are what "this day's raw HR is
                // unchanged" means.
                t.column("hrCount", .integer).notNull()
                t.column("hrMaxTs", .integer).notNull()
                // The nightly raw skin-temp mean this day contributed to the skin baseline. Persisted here
                // because the scored `dailyMetric` row carries only the DEVIATION, so a skipped day could
                // not otherwise re-seed the baseline identically — and a baseline that changes depending on
                // which days were skipped would make scores depend on scan history. nil when the night had
                // no usable skin samples.
                t.column("nightlySkinC", .double)
                t.primaryKey(["deviceId", "day"])
            }
        }
        // The LEARNED traits a day was scored against. These are re-derived from the trailing history on
        // every pass and fed into `analyzeDay`, so they change a day's stored Rest score WITHOUT changing
        // one byte of its raw input — invisible to the (count, maxTs) fingerprint above. A day reused
        // across a trait shift would stay frozen on the old values while its neighbours moved, and a
        // forced full rescore would then no longer reproduce it. Quantised (see `traitSignature`) so
        // ordinary daily jitter does not invalidate the whole window every night.
        //
        // Additive, and NULL on every row written by v38: a row with no recorded traits compares as
        // "unknown" and therefore as CHANGED, so the first pass after this migration re-derives those days
        // once and records them. Missing means scan — the same safe direction as v38.
        migrator.registerMigration("v39-day-scan-traits") { db in
            try db.alter(table: "dayScanFingerprint") { t in
                t.add(column: "traitSleepConsistency", .integer)
                t.add(column: "traitNeedHoursTenths", .integer)
                t.add(column: "traitMidsleepMin", .integer)
            }
        }
        // v40: exact, O(1)-per-day invalidation for the analysis cache. The v38/v39 fingerprint only
        // described measured HR. Sleep/recovery also consumes PPG HR, R-R, respiration, motion, steps,
        // temperature, SpO2, wrist events and band sleep-state, so a change in any of those streams could
        // otherwise leave a persisted score permanently reusable. Each real raw mutation stamps the UTC
        // day(s) it touched with the transaction's monotone sensor-write revision. Analysis takes MAX over
        // the UTC buckets intersecting its local 54 h window; false positives at a UTC boundary are safe,
        // while a false negative is not.
        migrator.registerMigration("v40-analysis-input-revision") { db in
            try db.create(table: "analysisInputRevision") { t in
                t.column("deviceId", .text).notNull()
                t.column("utcDay", .integer).notNull()
                t.column("revision", .integer).notNull()
                t.primaryKey(["deviceId", "utcDay"])
            }
            try db.create(table: "analysisDeviceRevision") { t in
                t.column("deviceId", .text).primaryKey()
                t.column("revision", .integer).notNull()
            }
            try db.alter(table: "dayScanFingerprint") { t in
                t.add(column: "inputRevision", .integer)
                t.add(column: "deviceRevision", .integer)
                t.add(column: "scoringVersion", .integer)
                t.add(column: "semanticSignature", .text)
            }
        }
        // v41-apple-step-hour (upstream v38): hourly Apple Health step counts. The daily `collect(.stepCount, …)` path
        // in HealthKitBridge flattens a whole day to one `appleDaily.steps` total, so a dead/absent phone
        // for part of a day (e.g. the phone died mid-hike) is invisible — steps just read low for the
        // WHOLE day instead of showing exactly which hours had no recording. HealthKit retains hourly
        // statistics historically, so this table lets a one-time backfill answer PAST days
        // retroactively, not just from the day this migration ships. `ts` is the hour-BUCKET START
        // (unix seconds), aligned to local-clock hour boundaries by the `HKStatisticsCollectionQuery`
        // anchored at local midnight (see HealthKitBridge); `steps` is the cumulative sum within that
        // hour. PK (deviceId, ts) mirrors every other per-sample table (hrSample, stepSample, …) and
        // makes the hourly upsert idempotent. Additive only — a NEW table, no existing row touched, old
        // readers unaffected.
        migrator.registerMigration("v41-apple-step-hour") { db in
            // Renumbered from upstream's "v38-apple-step-hour": this fork's v38-v40 (the persisted
            // analyze-scan skip) already occupy those slots, and `SchemaOracleTests` requires the vN in
            // an identifier to match its registration order. Free to renumber HERE because this fork has
            // never shipped the upstream id, so no install has it recorded — and upstream's own
            // `ifNotExists` below anticipates exactly this case.
            // ifNotExists: forks/sideloads that already carry this table under a different migration
            // identifier converge cleanly instead of failing the migrator.
            try db.create(table: "appleStepHour", options: [.ifNotExists]) { t in
                t.column("deviceId", .text).notNull()   // "apple-health"
                t.column("ts", .integer).notNull()      // hour-start unix seconds (local-hour aligned by HK)
                t.column("steps", .integer).notNull()
                t.primaryKey(["deviceId", "ts"])
            }
        }
        // Fork v42 (upstream v39, #979): keep the v26 per-burst counter beside the waveform it segments.
        // v39-v41 are already shipped fork migrations, so the upstream identifier must not be reused.
        // Existing rows stay
        // nil because the counter was discarded before this migration and cannot be reconstructed.
        migrator.registerMigration("v42-ppg-burst-index") { db in
            try db.alter(table: "ppgWaveformSample") { t in
                t.add(column: "burstIndex", .integer)
            }
        }
        // v43-body-weight: body weight as a real MEASUREMENT SERIES, not a single profile field.
        //
        // Weight already reached the app as a daily `metricSeries` cell under `apple-health`
        // (latest-of-day) plus `ProfileStore.weightKg`, a manually-set profile default. Neither is a
        // history: there was nowhere to put a weigh-in the user types in NOOP, nothing to edit or
        // delete by id, and no record of WHERE a value came from. Trend weight, weekly rate, goal
        // course and (later) maintenance calibration all need individual dated measurements.
        //
        // Modelled on `labMarker` (v17), which solved the identical shape: several readings can share
        // a day, each carries a precise `takenAt` instant and a `source`, `id` is a client-generated
        // stable identifier so one reading can be edited/deleted and a backup round-trips, and `day`
        // is the pre-derived yyyy-MM-dd key for the daily projection this store writes alongside
        // (`metricSeries` key "weight" under the `noop-weight` source id).
        //
        // Apple Health weights are deliberately NOT copied in here. HealthKit samples are mutable and
        // deletable after the fact, so a copy would need permanent reconciliation and would produce
        // exactly the duplicates it was meant to prevent; `Repository.weightSeries()` unions the two
        // per day instead — the same "one source wins a day, never a sum" model `sourceCandidates`
        // already uses for every other metric.
        //
        // Additive only: a NEW table, no existing row touched, old readers unaffected.
        migrator.registerMigration("v43-body-weight") { db in
            // Compatibility for local/internal builds made from the pre-merge feature snapshot. That
            // snapshot briefly shipped this exact schema under `v42-body-weight`; upstream then occupied
            // v42, so the final migration had to move to v43. Such a database has the table but not this
            // marker, and an unconditional CREATE traps every subsequent store open in the same failure.
            // Keep the leniency marker-gated: an unrelated database that happens to contain a table with
            // this name must still fail loudly rather than being mistaken for our schema.
            let hasPrototypeMigration = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM grdb_migrations WHERE identifier = 'v42-body-weight'
                )
                """) ?? false
            try db.create(table: "bodyWeightEntry",
                          options: hasPrototypeMigration ? [.ifNotExists] : []) { t in
                t.column("id", .text).primaryKey()
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()          // yyyy-MM-dd (projection key)
                t.column("takenAt", .integer).notNull()   // epoch seconds (precise instant)
                t.column("weightKg", .double).notNull()
                t.column("source", .text).notNull()       // manual | appleHealth | imported
                t.column("note", .text)
            }
            // Idempotent re-import / re-log: one measurement per (deviceId, takenAt, source), so a
            // caller minting a fresh id for the same instant updates rather than duplicates.
            try db.create(index: "idx_bodyWeightEntry_natural",
                          on: "bodyWeightEntry",
                          columns: ["deviceId", "takenAt", "source"],
                          options: hasPrototypeMigration ? [.unique, .ifNotExists] : [.unique])
            // History reads scan (deviceId) then walk takenAt in order.
            try db.create(index: "idx_bodyWeightEntry_device_takenAt",
                          on: "bodyWeightEntry", columns: ["deviceId", "takenAt"],
                          options: hasPrototypeMigration ? [.ifNotExists] : [])
        }
        // v44-energy-coverage: the on-device day-calorie estimate is a sum over observed HR seconds.
        // Persist that denominator beside the value so consumers can distinguish a fully-covered day
        // from a short, intense window without trying to reverse-engineer wear time from calories/BMR.
        // Nullable keeps every imported and pre-v44 row honestly "unknown" and avoids a costly history
        // scan during launch migration; normal day re-analysis fills recent/current rows organically.
        migrator.registerMigration("v44-energy-coverage") { db in
            // The same pre-merge snapshot called this `v43-energy-coverage`. Only trust an already-present
            // column when that exact prototype marker exists; otherwise a duplicate remains a real schema
            // error. GRDB/SQLite has no portable ADD COLUMN IF NOT EXISTS for this deployment range.
            let hasPrototypeMigration = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(
                    SELECT 1 FROM grdb_migrations WHERE identifier = 'v43-energy-coverage'
                )
                """) ?? false
            let hasColumn = try db.columns(in: "dailyMetric").contains { $0.name == "energyCoverageSeconds" }
            if !hasPrototypeMigration || !hasColumn {
                try db.alter(table: "dailyMetric") { t in
                    t.add(column: "energyCoverageSeconds", .integer)
                }
            }
        }
        // v45-health-energy-buckets: a deliberately separate Apple Health reference stream for
        // personalising WHOOP energy.  These rows are never folded into dailyMetric and therefore
        // cannot silently replace or add to the strap estimate.  Five-minute buckets retain enough
        // overlap shape for calibration without storing HealthKit's raw per-second samples.
        migrator.registerMigration("v45-health-energy-buckets") { db in
            try db.create(table: "healthEnergyBucket") { t in
                t.column("deviceId", .text).notNull()
                t.column("sourceId", .text).notNull()
                t.column("sourceKind", .text).notNull()
                t.column("bucketStart", .integer).notNull()
                t.column("activeKcal", .double)
                t.column("basalKcal", .double)
                t.column("averageHr", .double)
                t.column("steps", .integer)
                t.column("distanceM", .double)
                t.column("strideM", .double)
                t.column("workout", .boolean).notNull().defaults(to: false)
                t.column("coverageSeconds", .integer).notNull().defaults(to: 0)
                t.column("sampleCount", .integer).notNull().defaults(to: 0)
                t.column("quality", .double)
                t.primaryKey(["deviceId", "sourceId", "bucketStart"])
            }
            try db.create(index: "idx_healthEnergyBucket_device_time",
                          on: "healthEnergyBucket", columns: ["deviceId", "bucketStart"])
        }
        // v46-whoop-daily-energy: derived WHOOP output with its evidence mix. Keeping provenance in
        // a separate row avoids widening the imported dailyMetric contract and makes model-version
        // invalidation explicit. Apple reference values never enter this table.
        migrator.registerMigration("v46-whoop-daily-energy") { db in
            try db.create(table: "whoopDailyEnergy") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("rawTotalKcal", .double).notNull()
                t.column("modelVersion", .text).notNull()
                t.column("observedSeconds", .integer).notNull()
                t.column("inferredSeconds", .integer).notNull()
                t.column("modeledSeconds", .integer).notNull()
                t.column("uncertaintyFraction", .double).notNull()
                t.column("weightKg", .double).notNull()
                t.column("weightSource", .text).notNull()
                t.primaryKey(["deviceId", "day"])
            }
            try db.create(index: "idx_whoopDailyEnergy_device_day",
                          on: "whoopDailyEnergy", columns: ["deviceId", "day"])
        }
        // v47-energy-calibration-model: opt-in, per-WHOOP calibration state. Absence means disabled;
        // the explicit enabled flag lets a user pause without discarding a hard-won fit. Binding the
        // reference device prevents a replacement watch from inheriting another sensor's scale.
        migrator.registerMigration("v47-energy-calibration-model") { db in
            try db.create(table: "energyCalibrationModel") { t in
                t.column("deviceId", .text).notNull().primaryKey()
                t.column("referenceDeviceId", .text).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: false)
                t.column("factor", .double).notNull()
                t.column("sampleDays", .integer).notNull()
                t.column("sampleBuckets", .integer).notNull()
                t.column("coefficientOfVariation", .double).notNull()
                t.column("fittedAt", .integer).notNull()
                t.column("modelVersion", .text).notNull()
            }
        }
        // v48-whoop-energy-hourly: the same bucket pass that writes `whoopDailyEnergy`, kept at hourly
        // resolution so a personal time-of-day activity profile can be fitted without re-walking the
        // raw ~1 Hz streams (see `ActivityShapeEngine`). ACTIVE energy only: basal is flat by
        // construction and would flatten the very shape this exists to measure.
        //
        // A separate table rather than a JSON column on `whoopDailyEnergy`, because the fit reads a
        // 42-day window hour by hour and a packed blob would have to be decoded 42 times to answer it.
        // Additive: a new table, no existing row touched.
        migrator.registerMigration("v48-whoop-energy-hourly") { db in
            try db.create(table: "whoopEnergyHourly") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()          // yyyy-MM-dd, LOCAL day
                t.column("hour", .integer).notNull()      // 0...23, local hour
                t.column("activeKcal", .double).notNull()
                t.primaryKey(["deviceId", "day", "hour"])
            }
            try db.create(index: "idx_whoopEnergyHourly_device_day",
                          on: "whoopEnergyHourly", columns: ["deviceId", "day"])
        }
        // v49-whoop-energy-context: v4 distinguishes observed activity from a bounded physiological
        // estimate. Additive defaults preserve every v3 row until the 120-day recompute replaces it.
        migrator.registerMigration("v49-whoop-energy-context") { db in
            try db.alter(table: "whoopDailyEnergy") { t in
                t.add(column: "representedSeconds", .integer).notNull().defaults(to: 0)
                t.add(column: "physiologicalSeconds", .integer).notNull().defaults(to: 0)
                t.add(column: "contextJSON", .text).notNull().defaults(to: "{}")
            }
        }
        // v50-whoop-energy-buckets: auditable five-minute output for the cumulative Today curve.
        // It is derived data and is replaced atomically with the daily/hourly v5 rows.
        migrator.registerMigration("v50-whoop-energy-buckets") { db in
            try db.create(table: "whoopEnergyBucket") { t in
                t.column("deviceId", .text).notNull()
                t.column("day", .text).notNull()
                t.column("bucketStart", .integer).notNull()
                t.column("durationSeconds", .integer).notNull()
                t.column("basalKcal", .double).notNull()
                t.column("activeKcal", .double).notNull()
                t.column("context", .text).notNull()
                t.column("evidence", .text).notNull()
                t.column("uncertaintyFraction", .double).notNull()
                t.primaryKey(["deviceId", "bucketStart"])
            }
            try db.create(index: "idx_whoopEnergyBucket_device_day",
                          on: "whoopEnergyBucket", columns: ["deviceId", "day"])
        }
        // v51 (#1636): keep the nightly ABSOLUTE skin temperature beside the deviation derived from it.
        // The engine computed this mean on every pass and discarded it the moment `skinTempDevC` was
        // taken, so the app could show "+0.5 Δ°C" with no way to learn what it moved from — and a febrile
        // night reads as a small delta where the absolute reads as a fever. Additive and nullable: old
        // rows stay nil, and nothing reads it as a gate. Existing nights refill on the next scoring pass
        // because the value is re-derived from raw `skinTempSample` rows that are still on disk — no
        // separate backfill, and therefore no second implementation that could disagree with the live one.
        migrator.registerMigration("v51-daily-skin-temp-absolute") { db in
            // Same rename-collision guard as v44-energy-coverage above: this migration is carried over
            // from upstream, which registered it under an earlier identifier before the fork's own
            // pre-existing v40 forced a renumber to v51. A device that ran an intermediate build of this
            // branch under the old name already has the column with no `v51-daily-skin-temp-absolute`
            // row recorded, which would otherwise fail this ALTER on every launch forever.
            let hasColumn = try db.columns(in: "dailyMetric").contains { $0.name == "skinTempC" }
            if !hasColumn {
                try db.alter(table: "dailyMetric") { t in
                    t.add(column: "skinTempC", .double)
                }
            }
        }
        // Retire the bounded, write-only legacy cache. Session-owned IMU now lives in the file-backed store.
        migrator.registerMigration("v52-drop-raw-imu-sample") { db in
            try db.drop(table: "rawImuSample")
        }
        // Whether every sleep session that day was staged from heart rate alone (#1801).
        //
        // Renumbered from upstream's `v42-daily-sleep-hr-only` on the way in: this fork's migrator is at
        // v52, so arriving as "v42" would have run a migration numbered BELOW ten of its predecessors and
        // read, forever, as if the sequence had gone backwards. GRDB keys by name and applies in
        // registration order, so nothing breaks either way — but the number is the only thing telling the
        // next reader when this ran, and a wrong one costs more than the rename. Safe to rename here
        // because no install in this fork has ever recorded the upstream identifier.
        //
        // Upstream's note explains the column exists there for its Kotlin twin (`DailyMetric.sleepHrOnly`,
        // Room MIGRATION_35_36). That reason does not apply here — the Android tree is gone and the parity
        // contract retired (see docs/FORK_GUIDE.md) — but the column is kept so a backup written by either
        // tree still restores into the other.
        migrator.registerMigration("v53-daily-sleep-hr-only") { db in
            try db.alter(table: "dailyMetric") { t in
                t.add(column: "sleepHrOnly", .boolean)
            }
        }
        // v54-hevy-strength: the Hevy lane's own tables. Purely additive — nothing existing is touched,
        // so an install that never connects Hevy carries five empty tables and behaves exactly as before.
        //
        // Set-level rows are their own tables rather than a JSON blob on `workout` because the whole
        // point is to query them: sets per muscle group per week, e1RM per exercise over time, RPE at a
        // given load. A blob would make every one of those a full deserialize-and-scan.
        //
        // Hevy's ids are the primary keys throughout. That is what makes a re-sync idempotent (the same
        // workout upserts in place) and what a `deleted` event can name.
        migrator.registerMigration("v54-hevy-strength") { db in
            try db.create(table: "hevyWorkout") { t in
                t.column("id", .text).primaryKey()        // Hevy's own workout UUID
                t.column("title", .text).notNull()
                t.column("routineId", .text)
                t.column("notes", .text)
                t.column("startTs", .integer).notNull()
                t.column("endTs", .integer).notNull()
                t.column("updatedAtTs", .integer).notNull()
                t.column("createdAtTs", .integer).notNull()
            }
            // Every read is "the sessions in this window", newest first.
            try db.create(index: "idx_hevyWorkout_startTs", on: "hevyWorkout", columns: ["startTs"])
            // The incremental cursor is MAX(updatedAtTs); indexed so resuming a sync is a lookup.
            try db.create(index: "idx_hevyWorkout_updatedAtTs", on: "hevyWorkout", columns: ["updatedAtTs"])

            // ON DELETE CASCADE on both child tables: a workout deleted in Hevy must take its exercises
            // and sets with it. Doing that in SQL rather than in Swift means a future delete path cannot
            // forget one of the two and leave orphan sets that still count toward weekly volume.
            try db.create(table: "hevyExercise") { t in
                t.column("workoutId", .text).notNull()
                    .references("hevyWorkout", onDelete: .cascade)
                t.column("idx", .integer).notNull()       // order within the workout
                t.column("title", .text).notNull()
                t.column("templateId", .text)
                t.column("supersetId", .integer)
                t.column("notes", .text)
                t.primaryKey(["workoutId", "idx"])
            }
            try db.create(index: "idx_hevyExercise_template", on: "hevyExercise", columns: ["templateId"])

            try db.create(table: "hevySet") { t in
                t.column("workoutId", .text).notNull()
                    .references("hevyWorkout", onDelete: .cascade)
                t.column("exerciseIdx", .integer).notNull()
                t.column("idx", .integer).notNull()       // order within the exercise
                t.column("type", .text).notNull()         // normal | warmup | dropset | failure | other
                t.column("weightKg", .double)
                t.column("reps", .integer)
                t.column("distanceM", .double)
                t.column("durationS", .double)
                t.column("rpe", .double)
                t.column("customMetric", .double)
                t.primaryKey(["workoutId", "exerciseIdx", "idx"])
            }

            // The catalogue: mirrored in full, so a coach can name a movement the user has never done.
            try db.create(table: "hevyExerciseTemplate") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("type", .text).notNull()         // Hevy's own token, e.g. "weight_reps"
                t.column("primaryMuscleGroup", .text).notNull()
                t.column("secondaryMuscleGroupsJSON", .text).notNull()   // JSON array of raw values
                t.column("equipment", .text).notNull()
                t.column("isCustom", .boolean).notNull()
            }
            // Muscle-group and title lookups back the exercise search the coach uses to pick movements.
            try db.create(index: "idx_hevyExerciseTemplate_muscle",
                          on: "hevyExerciseTemplate", columns: ["primaryMuscleGroup"])

            // `rawJSON` is the server's own routine document, kept verbatim. `PUT /v1/routines/{id}` is
            // a FULL REPLACE: a field this build does not model would be dropped on the first edit
            // unless the original is still around to merge into. See `HevyRoutine`.
            try db.create(table: "hevyRoutine") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("folderId", .integer)
                t.column("notes", .text)
                t.column("updatedAtTs", .integer).notNull()
                t.column("rawJSON", .text).notNull()
            }
        }

        // The wearer's own answers about how a muscle feels. The point of the table is that this is
        // the ONLY ground truth available about recovery: how fast load fades is not in a training
        // log, and every app that shows a "94 % recovered" figure got it from a constant it assumed
        // rather than measured.
        //
        // What is stored is the RAW answer and nothing else. The fatigue the model predicted at that
        // moment is deliberately absent: it depends on the very time constant the answers are used to
        // fit, so recording it would bake today's model into tomorrow's evidence and quietly make the
        // fit agree with itself. The prediction is recomputed from the training log for whichever
        // constant is under test.
        migrator.registerMigration("v55-muscle-recovery-feedback") { db in
            try db.create(table: "muscleRecoveryFeedback") { t in
                t.column("muscleGroup", .text).notNull()   // HevyMuscleGroup raw value
                t.column("ts", .integer).notNull()         // when the answer was given
                t.column("feeling", .integer).notNull()    // 0 fresh … 3 still wrecked
                // One answer per muscle per moment; answering again at the same second replaces it
                // rather than double-counting a double tap.
                t.primaryKey(["muscleGroup", "ts"])
            }
            // Every read is "this muscle's answers, oldest first", which is what the fit walks.
            try db.create(index: "idx_muscleRecoveryFeedback_group",
                          on: "muscleRecoveryFeedback", columns: ["muscleGroup", "ts"])
        }

        // Detailed strength sessions can also originate from offline file imports. Provenance keeps
        // disconnecting Hevy from deleting local history, while the mapping table lets an unknown CSV
        // exercise be assigned once without pretending its muscle group can be inferred from its name.
        migrator.registerMigration("v56-strength-sources") { db in
            try db.alter(table: "hevyWorkout") { t in
                t.add(column: "source", .text).notNull().defaults(to: "hevy_api")
            }
            try db.create(index: "idx_hevyWorkout_source_startTs", on: "hevyWorkout",
                          columns: ["source", "startTs"])
            try db.create(table: "strengthExerciseMapping") { t in
                t.column("normalizedTitle", .text).primaryKey()
                t.column("displayTitle", .text).notNull()
                t.column("primaryMuscleGroup", .text).notNull()
                t.column("secondaryMuscleGroupsJSON", .text).notNull()
                t.column("updatedAtTs", .integer).notNull()
            }
        }
        // #2019: carry the v26 optical window's ABSOLUTE base code beside its deltas.
        //
        // The 25-sample window is one absolute ADC code plus 24 deltas, and only the deltas were read, so
        // the stored `samples` blob is a derivative and the DC level was thrown away. Nullable and
        // additive: an existing row keeps its deltas and gets a null base, which is the true statement
        // about it. A delta series cannot be inverted without the base, so those windows have no
        // recoverable absolute level and no backfill can invent one. Twin of Room's MIGRATION_37_38.
        migrator.registerMigration("v57-ppg-waveform-base-code") { db in
            try db.alter(table: "ppgWaveformSample") { t in
                t.add(column: "baseCode", .integer)
            }
        }
        // v58: identify the transport that delivered each R-R beat. WHOOP exposes the same heartbeat
        // through historical/proprietary packets and standard 0x2A37 notifications; without provenance
        // both copies were scored together when their coarse timestamps differed. Nullable and additive:
        // legacy rows remain readable and can be labelled by an idempotent re-decode, while no raw sample
        // or user correction is deleted.
        migrator.registerMigration("v58-rr-transport") { db in
            try db.alter(table: "rrInterval") { t in
                t.add(column: "transport", .integer)
            }
        }
        // v59 (#1881 follow-up): re-file strap samples a live link wrote under an ARCHIVED registry row.
        //
        // `SourceIdentity.resolve` used to match the connected peripheral against every registry row,
        // archived ones included, and take the first by `addedAt`. A strap that is removed and re-added
        // keeps its peripheral address, so the archived legacy row and the new active row carried the same
        // `peripheralId`, the older archived row won, and every reconnect re-pointed the Collector and
        // Backfiller at it until the next launch. The analyze scan never reads archived devices, so those
        // nights scored as empty.
        //
        // Narrowest provable interval: only rows NEWER than the archived row's `lastSeenAt`, because
        // `DeviceRegistryStore.touch` never advances an archived row — nothing after that instant was
        // recorded under that identity on purpose. Only an ACTIVE WHOOP with the same address receives rows.
        // `UPDATE OR IGNORE` moves and never deletes: a sample whose key already exists under the active id
        // stays where it is. The moved UTC days are marked for both ids so the day-scan fingerprints
        // re-derive exactly those days and nothing else.
        migrator.registerMigration("v59-reattribute-archived-strap-samples") { db in
            let twins = try Row.fetchAll(db, sql: """
                SELECT a.id AS archivedId, b.id AS activeId, a.lastSeenAt AS boundary
                FROM pairedDevice a
                JOIN pairedDevice b
                  ON UPPER(a.peripheralId) = UPPER(b.peripheralId) AND a.id <> b.id
                WHERE a.status = 'archived' AND b.status = 'active'
                  AND TRIM(COALESCE(a.peripheralId, '')) <> ''
                  AND (a.id = 'my-whoop' OR UPPER(a.brand) = 'WHOOP')
                  AND (b.id = 'my-whoop' OR UPPER(b.brand) = 'WHOOP')
                """)
            // Frozen here rather than shared with `deviceScopedTables`: a migration must keep doing what it
            // did the day it shipped. These are the per-sample streams the Collector and Backfiller write, plus
            // `dynamicAccelSample`, which only installs that once ran the CosinorAge prototype's
            // `v28-dynamic-accel` carry. This migrator never creates that one, so a missing table is skipped.
            let sampleTables = ["hrSample", "rrInterval", "gravitySample", "dynamicAccelSample",
                                "stepSample", "skinTempSample", "spo2Sample", "respSample",
                                "sleepStateSample", "ppgHrSample", "ppgWaveformSample", "v18AuxSample",
                                "event", "battery"]
            for twin in twins {
                let archivedId: String = twin["archivedId"]
                let activeId: String = twin["activeId"]
                let boundary: Int = twin["boundary"]
                var movedUtcDays = Set<Int>()
                for table in sampleTables {
                    guard try db.tableExists(table) else { continue }
                    let days = try Int.fetchAll(db, sql: """
                        SELECT DISTINCT ts / 86400 FROM \(table) WHERE deviceId = ? AND ts > ?
                        """, arguments: [archivedId, boundary])
                    guard !days.isEmpty else { continue }
                    try db.execute(sql: """
                        UPDATE OR IGNORE \(table) SET deviceId = ? WHERE deviceId = ? AND ts > ?
                        """, arguments: [activeId, archivedId, boundary])
                    if db.changesCount > 0 { movedUtcDays.formUnion(days) }
                }
                // Captured raw frames are not an analysis input, but they are the same strap's bytes.
                try db.execute(sql: """
                    UPDATE rawBatch SET deviceId = ? WHERE deviceId = ? AND startTs > ?
                    """, arguments: [activeId, archivedId, boundary])
                let dayStarts = movedUtcDays.map { $0 * 86_400 }
                try WhoopStore.markAnalysisInputsChanged(db, deviceId: activeId, timestamps: dayStarts)
                try WhoopStore.markAnalysisInputsChanged(db, deviceId: archivedId, timestamps: dayStarts)
            }
        }
        // v60: provenance and durable fusion for one physical training session arriving through several
        // sources (for example Hevy set detail plus the generic workout Hevy writes to Apple Health).
        // Raw workout and strength rows remain untouched; these additive sidecars identify components,
        // preserve user decisions and retain workout-associated HealthKit HR without polluting strap HR.
        migrator.registerMigration("v60-training-session-fusion") { db in
            try db.create(table: "workoutSourceMetadata") { t in
                t.column("componentKey", .text).primaryKey()
                t.column("source", .text).notNull()
                t.column("startTs", .integer).notNull()
                t.column("sport", .text).notNull()
                t.column("externalId", .text)
                t.column("sourceBundleId", .text)
                t.column("rawActivityType", .integer)
                t.column("activitiesJSON", .text)
                t.column("updatedAtTs", .integer).notNull()
            }
            try db.create(index: "idx_workoutSourceMetadata_window",
                          on: "workoutSourceMetadata", columns: ["startTs", "source"])

            try db.create(table: "workoutHeartRateBucket") { t in
                t.column("componentKey", .text).notNull()
                    .references("workoutSourceMetadata", onDelete: .cascade)
                t.column("bucketStart", .integer).notNull()
                t.column("bpm", .double).notNull()
                t.column("sourceBundleId", .text)
                t.primaryKey(["componentKey", "bucketStart"])
            }

            try db.create(table: "trainingSessionLink") { t in
                t.column("componentKey", .text).primaryKey()
                t.column("sessionId", .text).notNull()
                t.column("origin", .text).notNull()
                t.column("updatedAtTs", .integer).notNull()
            }
            try db.create(index: "idx_trainingSessionLink_session",
                          on: "trainingSessionLink", columns: ["sessionId"])

            try db.create(table: "trainingSessionPairDecision") { t in
                t.column("leftKey", .text).notNull()
                t.column("rightKey", .text).notNull()
                t.column("decision", .text).notNull()
                t.column("updatedAtTs", .integer).notNull()
                t.primaryKey(["leftKey", "rightKey"])
            }

            try db.create(table: "trainingSessionPreference") { t in
                t.column("sessionId", .text).primaryKey()
                t.column("activityKind", .text)
                t.column("primaryComponentKey", .text)
                t.column("updatedAtTs", .integer).notNull()
            }
        }
        // v61: source-neutral native training storage. Detailed workouts are normalized down to sets so
        // long histories remain queryable without repeating exercise metadata or storing one JSON document
        // per session. The single draft is the only JSON blob: it is transient, rewritten atomically and
        // deliberately excluded from analytics until completion.
        migrator.registerMigration("v61-native-training") { db in
            try db.create(table: "trainingExerciseDefinition") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("mode", .text).notNull()
                t.column("primaryMuscleId", .text)
                t.column("secondaryMuscleIdsJSON", .text).notNull()
                t.column("equipmentIdsJSON", .text).notNull()
                t.column("instructionsJSON", .text).notNull()
                t.column("isUnilateral", .boolean).notNull()
                t.column("source", .text).notNull()
                t.column("sourceId", .text)
                t.column("mediaId", .text)
                t.column("updatedAtTs", .integer).notNull()
            }
            try db.create(index: "idx_trainingExerciseDefinition_source",
                          on: "trainingExerciseDefinition", columns: ["source", "sourceId"])

            try db.create(table: "trainingRoutineNative") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("notes", .text)
                t.column("defaultProgressionJSON", .text).notNull()
                t.column("excludeFromProgression", .boolean).notNull()
                t.column("createdAtTs", .integer).notNull()
                t.column("updatedAtTs", .integer).notNull()
            }
            try db.create(index: "idx_trainingRoutineNative_updated",
                          on: "trainingRoutineNative", columns: ["updatedAtTs"])

            try db.create(table: "trainingRoutineExercise") { t in
                t.column("id", .text).primaryKey()
                t.column("routineId", .text).notNull()
                    .references("trainingRoutineNative", onDelete: .cascade)
                t.column("idx", .integer).notNull()
                t.column("exerciseId", .text).notNull()
                t.column("restSeconds", .integer).notNull()
                t.column("supersetId", .text)
                t.column("progressionJSON", .text)
                t.column("barWeightKg", .double)
                t.column("note", .text)
            }
            try db.create(index: "idx_trainingRoutineExercise_routine",
                          on: "trainingRoutineExercise", columns: ["routineId", "idx"])

            try db.create(table: "trainingRoutineSetPlan") { t in
                t.column("id", .text).primaryKey()
                t.column("routineExerciseId", .text).notNull()
                    .references("trainingRoutineExercise", onDelete: .cascade)
                t.column("idx", .integer).notNull()
                t.column("phase", .text).notNull()
                t.column("intensifier", .text).notNull()
                t.column("targetWeightKg", .double)
                t.column("repsMin", .integer)
                t.column("repsMax", .integer)
                t.column("targetDurationS", .integer)
                t.column("targetDistanceM", .double)
            }
            try db.create(index: "idx_trainingRoutineSetPlan_exercise",
                          on: "trainingRoutineSetPlan", columns: ["routineExerciseId", "idx"])

            try db.create(table: "trainingWorkoutNative") { t in
                t.column("id", .text).primaryKey()
                t.column("title", .text).notNull()
                t.column("startedAtTs", .integer).notNull()
                t.column("endedAtTs", .integer).notNull()
                t.column("plannedDay", .text).notNull()
                t.column("routineIdsJSON", .text).notNull()
                t.column("trackerJSON", .text)
                t.column("sessionRPE", .double)
                t.column("note", .text)
                t.column("source", .text).notNull()
            }
            try db.create(index: "idx_trainingWorkoutNative_started",
                          on: "trainingWorkoutNative", columns: ["startedAtTs"])
            try db.create(index: "idx_trainingWorkoutNative_source_started",
                          on: "trainingWorkoutNative", columns: ["source", "startedAtTs"])

            try db.create(table: "trainingWorkoutExercise") { t in
                t.column("id", .text).primaryKey()
                t.column("workoutId", .text).notNull()
                    .references("trainingWorkoutNative", onDelete: .cascade)
                t.column("idx", .integer).notNull()
                t.column("exerciseId", .text).notNull()
                t.column("routineId", .text)
                t.column("restSeconds", .integer).notNull()
                t.column("supersetId", .text)
                t.column("excludeFromProgression", .boolean).notNull()
                t.column("note", .text)
            }
            try db.create(index: "idx_trainingWorkoutExercise_workout",
                          on: "trainingWorkoutExercise", columns: ["workoutId", "idx"])
            try db.create(index: "idx_trainingWorkoutExercise_exercise",
                          on: "trainingWorkoutExercise", columns: ["exerciseId", "workoutId"])

            try db.create(table: "trainingWorkoutSet") { t in
                t.column("id", .text).primaryKey()
                t.column("workoutExerciseId", .text).notNull()
                    .references("trainingWorkoutExercise", onDelete: .cascade)
                t.column("idx", .integer).notNull()
                t.column("phase", .text).notNull()
                t.column("intensifier", .text).notNull()
                t.column("weightKg", .double)
                t.column("reps", .integer)
                t.column("leftReps", .integer)
                t.column("rightReps", .integer)
                t.column("durationS", .integer)
                t.column("distanceM", .double)
                t.column("effortScale", .text)
                t.column("effortValue", .double)
                t.column("isCompleted", .boolean).notNull()
            }
            try db.create(index: "idx_trainingWorkoutSet_exercise",
                          on: "trainingWorkoutSet", columns: ["workoutExerciseId", "idx"])

            try db.create(table: "trainingWorkoutDraft") { t in
                t.column("id", .text).primaryKey()
                t.column("updatedAtTs", .integer).notNull()
                t.column("payload", .blob).notNull()
            }
            try db.create(index: "idx_trainingWorkoutDraft_updated",
                          on: "trainingWorkoutDraft", columns: ["updatedAtTs"])

            try db.create(table: "trainingSchedule") { t in
                t.column("weekday", .integer).notNull()
                t.column("idx", .integer).notNull()
                t.column("routineId", .text).notNull()
                    .references("trainingRoutineNative", onDelete: .cascade)
                t.primaryKey(["weekday", "idx"])
            }
            try db.create(table: "trainingDayOverride") { t in
                t.column("day", .text).notNull()
                t.column("idx", .integer).notNull()
                t.column("routineId", .text)
                t.column("isRest", .boolean).notNull()
                t.primaryKey(["day", "idx"])
            }
            try db.create(index: "idx_trainingDayOverride_day",
                          on: "trainingDayOverride", columns: ["day"])
        }
        // v62: whole-session RPE with separate workout and answer timestamps. Existing ratings lived in
        // the Lab Book sidecar with `takenAt` occupied by the workout start, so their true answer time is
        // unknown and remains NULL rather than being guessed during migration.
        migrator.registerMigration("v62-training-session-rating") { db in
            try db.create(table: "trainingSessionRating") { t in
                t.column("id", .text).primaryKey()
                t.column("sessionId", .text)
                t.column("workoutStartTs", .integer).notNull()
                t.column("ratedAtTs", .integer)
                t.column("rpe", .double).notNull()
                t.column("sport", .text)
                t.column("source", .text).notNull()
            }
            try db.create(index: "idx_trainingSessionRating_start",
                          on: "trainingSessionRating", columns: ["workoutStartTs"])
            try db.execute(sql: """
                INSERT OR IGNORE INTO trainingSessionRating
                  (id, sessionId, workoutStartTs, ratedAtTs, rpe, sport, source)
                SELECT id, valueText, takenAt, NULL, value, note, source
                FROM labMarker
                WHERE deviceId = 'training-load' AND category = 'trainingLoad'
                  AND markerKey = 'session_rpe' AND value BETWEEN 1 AND 10
                """)
        }
        // v63: detailed exercise anatomy overrides and provider identities. The reviewed catalogue
        // remains code-owned; this compact table stores only a user's correction or a provider mapping,
        // so years of sets do not repeat muscle metadata on every workout row.
        migrator.registerMigration("v63-training-exercise-anatomy-alias") { db in
            try db.create(table: "trainingExerciseAnatomyAlias") { t in
                t.column("key", .text).primaryKey()
                t.column("source", .text).notNull()
                t.column("sourceExerciseId", .text)
                t.column("normalizedTitle", .text).notNull()
                t.column("equipmentKey", .text)
                t.column("canonicalExerciseId", .text).notNull()
                t.column("primaryMuscleIdsJSON", .text).notNull()
                t.column("secondaryMuscleIdsJSON", .text).notNull()
                t.column("stabilizerMuscleIdsJSON", .text).notNull()
                t.column("origin", .text).notNull()
                t.column("confidence", .text).notNull()
                t.column("updatedAtTs", .integer).notNull()
            }
            try db.create(index: "idx_trainingExerciseAnatomyAlias_provider",
                          on: "trainingExerciseAnatomyAlias", columns: ["source", "sourceExerciseId"])
            try db.create(index: "idx_trainingExerciseAnatomyAlias_title",
                          on: "trainingExerciseAnatomyAlias", columns: ["normalizedTitle"])
        }
        // v64: additive workout-domain semantics for warm-ups, intensifier segments, timed sets,
        // equipment snapshots, and session-RPE provenance. Historical analysis is unchanged; the
        // added facts let later consumers distinguish rows without rewriting old workout values.
        migrator.registerMigration("v64-complete-strength-workout-domain") { db in
            try db.alter(table: "trainingRoutineExercise") { t in
                t.add(column: "warmupRestSeconds", .integer)
                t.add(column: "loadSemanticsJSON", .text)
            }
            try db.alter(table: "trainingRoutineSetPlan") { t in
                t.add(column: "intensifierConfigJSON", .text)
            }
            try db.alter(table: "trainingWorkoutNative") { t in
                t.add(column: "sessionRPEOrigin", .text)
            }
            try db.alter(table: "trainingWorkoutExercise") { t in
                t.add(column: "warmupRestSeconds", .integer)
                t.add(column: "equipmentSnapshotJSON", .text)
            }
            try db.alter(table: "trainingWorkoutSet") { t in
                t.add(column: "targetDurationS", .integer)
                t.add(column: "clusterId", .text)
                t.add(column: "parentSetId", .text)
                t.add(column: "segmentIndex", .integer)
            }
            try db.execute(sql: """
                UPDATE trainingWorkoutNative
                SET sessionRPEOrigin = 'legacy_unknown'
                WHERE sessionRPE IS NOT NULL AND sessionRPEOrigin IS NULL
                """)
        }
        // v65: links a native set log to its single physiological recording. Heart-rate samples remain
        // in the existing source-aware workout storage; this table only keeps provenance and coverage.
        migrator.registerMigration("v65-strength-physiology-lifecycle") { db in
            try db.alter(table: "trainingWorkoutNative") { t in
                t.add(column: "trainingSessionId", .text)
                t.add(column: "physiologyProvider", .text)
                t.add(column: "physiologyComponentKey", .text)
                t.add(column: "hrCoverage", .double)
                t.add(column: "lifecycleVersion", .integer)
            }
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_trainingWorkoutNative_session
                ON trainingWorkoutNative(trainingSessionId)
                WHERE trainingSessionId IS NOT NULL
                """)
        }
        // v66: completed sessions retain their recorded pause intervals. This is additive lifecycle
        // metadata used only to show active duration beside elapsed duration in a session summary.
        migrator.registerMigration("v66-strength-workout-summary-pauses") { db in
            try db.alter(table: "trainingWorkoutNative") { t in
                t.add(column: "pauseIntervalsJSON", .text)
            }
        }
        // v67: canonical exercise identity. Additive columns only; an exercise without them behaves
        // exactly as before, and no workout, routine or analysis value changes.
        migrator.registerMigration("v67-training-exercise-canonical-identity") { db in
            try db.alter(table: "trainingExerciseDefinition") { t in
                t.add(column: "canonicalId", .text)
                t.add(column: "aliasesJSON", .text)
                t.add(column: "contentVersion", .integer)
                t.add(column: "attribution", .text)
                t.add(column: "loadSemantics", .text)
            }
            try db.create(index: "idx_trainingExerciseDefinition_canonical",
                          on: "trainingExerciseDefinition", columns: ["canonicalId"])
        }
        return migrator
    }
}
