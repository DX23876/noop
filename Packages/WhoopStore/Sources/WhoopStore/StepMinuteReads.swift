import Foundation
import GRDB

/// One minute of the strap's step stream, aggregated in SQL so two weeks read as ~20,000 rows instead of
/// ~1.2 million seconds. `steps` is the counter's rise inside the minute (the step between two minutes is
/// not counted, about one step a minute at a walk). The strap resets the counter to zero once a day, which a
/// maximum minus a minimum would report as the whole day in one minute, so such a minute is summed second by
/// second. Doing that for every minute costs three times the read. `walkSeconds` and `runSeconds` count the
/// seconds the strap's own activity class (`@63`, #316) called walking or running, out of `classSeconds` with
/// any class.
/// A WHOOP 4.0 has no step stream, so it reads back no rows at all, never zeros.
public struct StepMinute: Equatable, Sendable {
    public let ts: Int
    public let steps: Int
    public let walkSeconds: Int
    public let runSeconds: Int
    public let classSeconds: Int

    public init(ts: Int, steps: Int, walkSeconds: Int, runSeconds: Int, classSeconds: Int) {
        self.ts = ts
        self.steps = steps
        self.walkSeconds = walkSeconds
        self.runSeconds = runSeconds
        self.classSeconds = classSeconds
    }
}

extension WhoopStore {
    /// More than any wearer can walk in a minute, so only a counter reset reads this high.
    static let impossibleStepsPerMinute = 300

    public nonisolated func stepMinutes(deviceId: String, from: Int, to: Int) async throws -> [StepMinute] {
        try await asyncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT (ts / 60) * 60 AS minute, MAX(counter) - MIN(counter) AS steps,
                       SUM(activityClass = 1) AS walk, SUM(activityClass = 2) AS run,
                       SUM(activityClass IS NOT NULL) AS classed
                FROM stepSample WHERE deviceId = ? AND ts >= ? AND ts < ?
                GROUP BY ts / 60 ORDER BY minute ASC
                """, arguments: [deviceId, from, to])
                .map { row in
                    let minute: Int = row["minute"]
                    var steps = max(0, row["steps"] ?? 0)
                    if steps > Self.impossibleStepsPerMinute {
                        let counters = try Int.fetchAll(db, sql: """
                            SELECT counter FROM stepSample WHERE deviceId = ? AND ts >= ? AND ts < ? ORDER BY ts
                            """, arguments: [deviceId, minute, minute + 60])
                        steps = zip(counters, counters.dropFirst()).reduce(0) { $0 + max(0, $1.1 - $1.0) }
                    }
                    return StepMinute(ts: minute, steps: steps, walkSeconds: row["walk"] ?? 0,
                                      runSeconds: row["run"] ?? 0, classSeconds: row["classed"] ?? 0)
                }
        }
    }
}
