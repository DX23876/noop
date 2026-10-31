import Foundation
import GRDB

/// The wearer's answer to one activity-detection suggestion, with what the suggestion showed when it was
/// answered. Kept apart from the workout row it may have produced: the row belongs to the workout list, this
/// is the record learning and measurement read later. Rows are wearer input, never ground truth produced
/// by NOOP itself (fork decision 2026-10-31).
public struct ActivitySuggestionAnswer: Equatable, Sendable {
    /// Which detector found the span.
    public enum Track: String, Sendable, CaseIterable {
        case walk, heartRate
    }

    /// What the wearer said it was. `everyday` and `housework` write only this row, never a workout.
    public enum Answer: String, Sendable, CaseIterable {
        case sport, walk, everyday, housework
    }

    /// Where the answer was given; with `shownAtTs` it tells how long a prompt waited.
    public enum Origin: String, Sendable, CaseIterable {
        case today, inbox, sheet, notification
    }

    /// The workout row a confirmation saved, by the workout table's own key.
    public struct WorkoutKey: Equatable, Sendable {
        public var deviceId: String
        public var startTs: Int
        public var sport: String

        public init(deviceId: String, startTs: Int, sport: String) {
            self.deviceId = deviceId
            self.startTs = startTs
            self.sport = sport
        }
    }

    public var track: Track
    public var candidateStartTs: Int
    public var candidateEndTs: Int
    public var answer: Answer
    /// The chosen sport; only an `answer` of `.sport` carries one.
    public var sport: String?
    public var origin: Origin
    /// The kind the suggestion preselected, as the wearer saw it.
    public var shownKind: String?
    /// The detector's score for the span when it was shown.
    public var shownScore: Double?
    public var modelVersion: String
    public var startWeightVersion: String
    public var shownAtTs: Int?
    public var answeredAtTs: Int
    public var workout: WorkoutKey?

    public init(track: Track, candidateStartTs: Int, candidateEndTs: Int, answer: Answer, sport: String?,
                origin: Origin, shownKind: String?, shownScore: Double?, modelVersion: String,
                startWeightVersion: String, shownAtTs: Int?, answeredAtTs: Int, workout: WorkoutKey?) {
        self.track = track
        self.candidateStartTs = candidateStartTs
        self.candidateEndTs = candidateEndTs
        self.answer = answer
        self.sport = sport
        self.origin = origin
        self.shownKind = shownKind
        self.shownScore = shownScore
        self.modelVersion = modelVersion
        self.startWeightVersion = startWeightVersion
        self.shownAtTs = shownAtTs
        self.answeredAtTs = answeredAtTs
        self.workout = workout
    }

    /// Seconds from the prompt to the answer, or from the end of the span when no prompt time was kept.
    public var answerDelaySeconds: Int {
        max(0, answeredAtTs - (shownAtTs ?? candidateEndTs))
    }

    /// A row a newer build wrote with a value this build does not know is skipped, not misread.
    fileprivate static func decode(_ row: Row) -> ActivitySuggestionAnswer? {
        guard let track = Track(rawValue: row["track"]),
              let answer = Answer(rawValue: row["answer"]),
              let origin = Origin(rawValue: row["origin"]) else { return nil }
        let deviceId: String? = row["workoutDeviceId"]
        let startTs: Int? = row["workoutStartTs"]
        let sport: String? = row["workoutSport"]
        let workout = deviceId.flatMap { d in
            startTs.flatMap { s in sport.map { WorkoutKey(deviceId: d, startTs: s, sport: $0) } }
        }
        return ActivitySuggestionAnswer(
            track: track, candidateStartTs: row["candidateStartTs"], candidateEndTs: row["candidateEndTs"],
            answer: answer, sport: row["sport"], origin: origin, shownKind: row["shownKind"],
            shownScore: row["shownScore"], modelVersion: row["modelVersion"],
            startWeightVersion: row["startWeightVersion"], shownAtTs: row["shownAtTs"],
            answeredAtTs: row["answeredAtTs"], workout: workout)
    }
}

extension WhoopStore {
    static func createActivitySuggestionAnswerTable(_ db: Database) throws {
        try db.create(table: "activitySuggestionAnswer") { t in
            t.column("track", .text).notNull()
            t.column("candidateStartTs", .integer).notNull()
            t.column("candidateEndTs", .integer).notNull()
            t.column("answer", .text).notNull()
            t.column("sport", .text)
            t.column("origin", .text).notNull()
            t.column("shownKind", .text)
            t.column("shownScore", .double)
            t.column("modelVersion", .text).notNull()
            t.column("startWeightVersion", .text).notNull()
            t.column("shownAtTs", .integer)
            t.column("answeredAtTs", .integer).notNull()
            t.column("workoutDeviceId", .text)
            t.column("workoutStartTs", .integer)
            t.column("workoutSport", .text)
            t.primaryKey(["track", "candidateStartTs"])
        }
        try db.create(index: "idx_activitySuggestionAnswer_candidateEndTs",
                      on: "activitySuggestionAnswer", columns: ["candidateEndTs"])
    }

    /// Stores the answer, replacing an earlier one for the same suggestion. Returns false for a row that
    /// cannot be a real answer: an empty span, a sport answer without a sport, or a non-finite score.
    @discardableResult
    public func recordActivitySuggestionAnswer(_ answer: ActivitySuggestionAnswer) async throws -> Bool {
        guard answer.candidateEndTs > answer.candidateStartTs,
              answer.shownScore.map(\.isFinite) ?? true else { return false }
        let sport = answer.sport?.trimmingCharacters(in: .whitespacesAndNewlines)
        if answer.answer == .sport, sport?.isEmpty ?? true { return false }
        try syncWrite { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO activitySuggestionAnswer
                  (track, candidateStartTs, candidateEndTs, answer, sport, origin, shownKind, shownScore,
                   modelVersion, startWeightVersion, shownAtTs, answeredAtTs,
                   workoutDeviceId, workoutStartTs, workoutSport)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    answer.track.rawValue, answer.candidateStartTs, answer.candidateEndTs,
                    answer.answer.rawValue, answer.answer == .sport ? sport : nil, answer.origin.rawValue,
                    answer.shownKind, answer.shownScore, answer.modelVersion, answer.startWeightVersion,
                    answer.shownAtTs, answer.answeredAtTs, answer.workout?.deviceId, answer.workout?.startTs,
                    answer.workout?.sport])
        }
        return true
    }

    /// Answers whose span overlaps `[from, to)`, oldest first.
    public func activitySuggestionAnswers(from: Int, to: Int) async throws -> [ActivitySuggestionAnswer] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM activitySuggestionAnswer
                WHERE candidateStartTs < ? AND candidateEndTs > ?
                ORDER BY candidateStartTs, track
                """, arguments: [to, from]).compactMap(ActivitySuggestionAnswer.decode)
        }
    }

    /// Undo: removes the answer so the suggestion is open again. The workout row it may have saved is the
    /// caller's to remove, through the workout delete path.
    @discardableResult
    public func deleteActivitySuggestionAnswer(track: ActivitySuggestionAnswer.Track,
                                               candidateStartTs: Int) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM activitySuggestionAnswer WHERE track = ? AND candidateStartTs = ?",
                           arguments: [track.rawValue, candidateStartTs])
            return db.changesCount > 0
        }
    }
}
