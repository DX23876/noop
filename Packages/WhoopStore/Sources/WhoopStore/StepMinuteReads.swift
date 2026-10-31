import Foundation
import GRDB

/// One minute of the strap's step stream, aggregated in SQL so two weeks read as ~20,000 rows instead of
/// ~1.2 million seconds. `steps` is the counter's rise inside the minute (the step between two minutes is
/// not counted, about one step a minute at a walk); `walkSeconds` and `runSeconds` count the seconds the
/// strap's own activity class (`@63`, #316) called walking or running, out of `classSeconds` with any class.
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
    public nonisolated func stepMinutes(deviceId: String, from: Int, to: Int) async throws -> [StepMinute] {
        try await asyncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT (ts / 60) * 60 AS minute, MAX(counter) - MIN(counter) AS steps,
                       SUM(activityClass = 1) AS walk, SUM(activityClass = 2) AS run,
                       SUM(activityClass IS NOT NULL) AS classed
                FROM stepSample WHERE deviceId = ? AND ts >= ? AND ts < ?
                GROUP BY ts / 60 ORDER BY minute ASC
                """, arguments: [deviceId, from, to])
                .map { StepMinute(ts: $0["minute"], steps: max(0, $0["steps"] ?? 0), walkSeconds: $0["walk"] ?? 0,
                                  runSeconds: $0["run"] ?? 0, classSeconds: $0["classed"] ?? 0) }
        }
    }
}
