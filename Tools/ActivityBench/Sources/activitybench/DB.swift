import Foundation
import SQLite3
import StrandAnalytics

/// Minimal read-only SQLite reader, as in SleepBench: no migrations, so a copy taken at any schema
/// version opens, and `immutable=1` so it can never write.
final class ReadOnlyDB {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let uri = "file:\(path)?immutable=1"
        let rc = sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK else {
            throw Err("cannot open \(path): \(String(cString: sqlite3_errstr(rc)))")
        }
    }
    deinit { if let handle { sqlite3_close(handle) } }

    struct Err: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    func query(_ sql: String, _ each: (OpaquePointer) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Err("prepare failed: \(String(cString: sqlite3_errmsg(handle))) [\(sql)]")
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { each(stmt!) }
    }

    func tableExists(_ name: String) throws -> Bool {
        var found = false
        try query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(name)'") { _ in found = true }
        return found
    }

    static func int(_ s: OpaquePointer, _ i: Int32) -> Int { Int(sqlite3_column_int64(s, i)) }
    static func isNull(_ s: OpaquePointer, _ i: Int32) -> Bool { sqlite3_column_type(s, i) == SQLITE_NULL }
    static func str(_ s: OpaquePointer, _ i: Int32) -> String? {
        guard let c = sqlite3_column_text(s, i) else { return nil }
        return String(cString: c)
    }
}

/// One stored workout row as the label read sees it.
struct EntryRow: Equatable {
    let startTs: Int
    let endTs: Int
    let sport: String
    let source: String
    /// The app that wrote an Apple Health workout, when the import kept it.
    let bundleId: String?
}

/// The wearer's own entries, the only ground truth (fork decision 2026-10-31). Left out: legacy detected
/// bouts (`-noop`), confirmed suggestions (`detected-confirmed`), and Apple Health workouts NOOP itself
/// wrote there, which would come back as the detector agreeing with itself. NOOP's bundle id is not in
/// this repository, so the tool matches the part every NOOP build carries.
enum EntryFilter {
    static let confirmedSuggestionSource = "detected-confirmed"

    static func isWearerEntry(_ row: EntryRow, ownBundleMarker: String) -> Bool {
        let source = row.source.lowercased()
        if source.hasSuffix("-noop") || source == confirmedSuggestionSource { return false }
        if let bundle = row.bundleId?.lowercased(), !ownBundleMarker.isEmpty,
           bundle.contains(ownBundleMarker.lowercased()) { return false }
        return row.endTs > row.startTs
    }
}

extension ReadOnlyDB {
    /// Workout rows from the strap namespace, Apple Health and Hevy, plus the native strength sessions.
    func entries(device: String, from: Int, to: Int) throws -> [EntryRow] {
        var out: [EntryRow] = []
        let hasMeta = try tableExists("workoutSourceMetadata")
        let bundle = hasMeta
            ? """
              (SELECT m.sourceBundleId FROM workoutSourceMetadata m
               WHERE m.source = 'apple-health' AND m.startTs = w.startTs AND m.sport = w.sport LIMIT 1)
              """
            : "NULL"
        try query("""
            SELECT w.startTs, w.endTs, w.sport, w.source, \(bundle) FROM workout w
            WHERE w.deviceId IN ('\(device)', 'apple-health', 'hevy') AND w.startTs < \(to) AND w.endTs > \(from)
            ORDER BY w.startTs
            """) { s in
            out.append(EntryRow(startTs: ReadOnlyDB.int(s, 0), endTs: ReadOnlyDB.int(s, 1),
                                sport: ReadOnlyDB.str(s, 2) ?? "", source: ReadOnlyDB.str(s, 3) ?? "",
                                bundleId: ReadOnlyDB.str(s, 4)))
        }
        if try tableExists("trainingWorkoutNative") {
            try query("""
                SELECT startedAtTs, endedAtTs, title FROM trainingWorkoutNative
                WHERE startedAtTs < \(to) AND endedAtTs > \(from) ORDER BY startedAtTs
                """) { s in
                // Every native session is a strength session, whatever its title says.
                out.append(EntryRow(startTs: ReadOnlyDB.int(s, 0), endTs: ReadOnlyDB.int(s, 1),
                                    sport: "Strength Training", source: "native-training", bundleId: nil))
            }
        }
        return out
    }

    func heartRate(device: String, from: Int, to: Int) throws -> [(ts: Int, bpm: Int)] {
        var out: [(ts: Int, bpm: Int)] = []
        try query("""
            SELECT ts, bpm FROM hrSample WHERE deviceId = '\(device)' AND ts >= \(from) AND ts < \(to) ORDER BY ts
            """) { s in out.append((ReadOnlyDB.int(s, 0), ReadOnlyDB.int(s, 1))) }
        return out
    }

    /// Resting heart rate by day key, from the computed namespace the daily pass writes.
    func restingHR(device: String) throws -> [String: Int] {
        var out: [String: Int] = [:]
        try query("SELECT day, restingHr FROM dailyMetric WHERE deviceId = '\(device)-noop' AND restingHr IS NOT NULL") { s in
            if let day = ReadOnlyDB.str(s, 0) { out[day] = ReadOnlyDB.int(s, 1) }
        }
        return out
    }

    func sleepSpans(device: String, from: Int, to: Int) throws -> [ActivityDetectionScore.Span] {
        var out: [ActivityDetectionScore.Span] = []
        try query("""
            SELECT startTs, endTs FROM sleepSession WHERE deviceId IN ('\(device)', '\(device)-noop')
            AND startTs < \(to) AND endTs > \(from) ORDER BY startTs
            """) { s in out.append(.init(start: ReadOnlyDB.int(s, 0), end: ReadOnlyDB.int(s, 1))) }
        return out
    }
}

extension ReadOnlyDB {
    /// Minutes as the candidate tracks read them: mean heart rate where at least 30 seconds were measured,
    /// the step counter's rise and the strap's class seconds where a step stream exists, and whether the
    /// minute lies in a sleep session.
    func minutes(device: String, from: Int, to: Int,
                 sleep: [ActivityDetectionScore.Span]) throws -> [ActivityCandidates.Minute] {
        var hr: [Int: Double] = [:]
        try query("""
            SELECT (ts / 60) * 60, AVG(bpm), COUNT(*) FROM hrSample
            WHERE deviceId = '\(device)' AND ts >= \(from) AND ts < \(to) GROUP BY ts / 60
            """) { s in
            if ReadOnlyDB.int(s, 2) >= 30 { hr[ReadOnlyDB.int(s, 0)] = sqlite3_column_double(s, 1) }
        }
        var steps: [Int: (steps: Int, walk: Int, run: Int, classed: Int)] = [:]
        try query("""
            SELECT (ts / 60) * 60, MAX(counter) - MIN(counter), SUM(activityClass = 1), SUM(activityClass = 2),
                   SUM(activityClass IS NOT NULL) FROM stepSample
            WHERE deviceId = '\(device)' AND ts >= \(from) AND ts < \(to) GROUP BY ts / 60
            """) { s in
            steps[ReadOnlyDB.int(s, 0)] = (max(0, ReadOnlyDB.int(s, 1)), ReadOnlyDB.int(s, 2), ReadOnlyDB.int(s, 3),
                                           ReadOnlyDB.int(s, 4))
        }
        let sortedSleep = sleep.sorted { $0.start < $1.start }
        return Set(hr.keys).union(steps.keys).sorted().map { ts in
            let st = steps[ts]
            let asleep = sortedSleep.contains { ts >= $0.start && ts < $0.end }
            return ActivityCandidates.Minute(ts: ts, bpm: hr[ts], steps: st?.steps, walkSeconds: st?.walk,
                                             runSeconds: st?.run, classSeconds: st?.classed, asleep: asleep)
        }
    }
}
