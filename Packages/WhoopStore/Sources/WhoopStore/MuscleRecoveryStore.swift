import Foundation
import GRDB

// MARK: - What the wearer said about how a muscle feels
//
// Raw answers, nothing derived. See the `v55-muscle-recovery-feedback` migration for why the model's
// own prediction is deliberately not stored beside them.

/// One answer: this muscle, at this moment, felt like this.
public struct MuscleRecoveryFeedback: Equatable, Sendable {
    public let muscleGroup: HevyMuscleGroup
    public let ts: Int
    /// 0 fresh, 1 slightly tired, 2 clearly tired, 3 still wrecked. Stored as the number rather than a
    /// word so a later relabelling of the scale does not orphan existing answers.
    public let feeling: Int

    public init(muscleGroup: HevyMuscleGroup, ts: Int, feeling: Int) {
        self.muscleGroup = muscleGroup
        self.ts = ts
        self.feeling = feeling
    }
}

extension WhoopStore {

    /// Record one answer. Answering twice in the same second replaces rather than duplicates.
    public func saveMuscleRecoveryFeedback(_ feedback: MuscleRecoveryFeedback) async throws {
        try syncWrite { db in
            try db.execute(
                sql: """
                INSERT INTO muscleRecoveryFeedback (muscleGroup, ts, feeling)
                VALUES (?, ?, ?)
                ON CONFLICT(muscleGroup, ts) DO UPDATE SET feeling = excluded.feeling
                """,
                arguments: [feedback.muscleGroup.rawValue, feedback.ts, feedback.feeling])
        }
    }

    /// Every answer since `from`, oldest first — the order the fit walks them in.
    ///
    /// An unreadable muscle name is skipped rather than dropped into `.other`: a row written by a
    /// build that knew a group this one does not is evidence about a muscle we cannot name, and
    /// filing it under "other" would put it in the wrong muscle's fit.
    public func muscleRecoveryFeedback(since from: Int = 0) async throws -> [MuscleRecoveryFeedback] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT muscleGroup, ts, feeling FROM muscleRecoveryFeedback
                WHERE ts >= ? ORDER BY ts ASC
                """, arguments: [from])
                .compactMap { row in
                    guard let group = HevyMuscleGroup(rawValue: row["muscleGroup"] as String) else {
                        return nil
                    }
                    return MuscleRecoveryFeedback(muscleGroup: group, ts: row["ts"],
                                                  feeling: row["feeling"])
                }
        }
    }
}
