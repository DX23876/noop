import Foundation
import WhoopStore
import StrandImport
import StrandAnalytics

/// How far along a running sync is, for the Data Sources card.
struct HevySyncProgress: Equatable {
    enum Phase: Equatable {
        case catalogue          // pulling the exercise templates
        case backfill           // first run: walking the whole workout history
        case incremental        // steady state: only what changed
        case routines
        case writing
    }
    var phase: Phase
    var page: Int
    var totalPages: Int
}

/// What one run did.
struct HevySyncSummary: Equatable {
    var fetchedWorkouts = 0
    var deletedWorkouts = 0
    var templates = 0
    var routines = 0
    var skipped = 0
    /// True when this run walked the whole history rather than the incremental feed.
    var wasBackfill = false
}

/// Pulls Hevy into the local store: a full backfill the first time, then only what changed.
///
/// ## Why the incremental path is the whole design
///
/// Hevy caps list pages at TEN items. A user with 600 logged sessions is 60 requests for a full
/// backfill — fine once, absurd on every app launch. `GET /v1/workouts/events?since=` exists precisely
/// for this: it returns updates *and* deletes since an instant, so steady state is one request that
/// usually comes back empty.
///
/// The cursor is `WhoopStore.hevyNewestUpdatedAt()` — derived from the rows actually stored, never kept
/// beside them. A separately-persisted cursor can end up ahead of the data when a run dies mid-page,
/// and every later run then skips that gap forever with nothing to indicate it.
///
/// ## Why this does NOT invalidate any analysis day
///
/// It would be easy, and wrong, to call `markAnalysisInputsChanged` here. A Hevy workout changes no
/// NOOP score: Charge, Effort, Rest and Readiness are derived from heart rate, HRV and sleep, and a
/// logged set adds none of those. The engine's own duplicate suppression reads only the strap source
/// and `apple-health` (`IntelligenceEngine`'s `realWorkouts`), so a Hevy row does not change what it
/// persists either — the transient detected twin is hidden read-side by
/// `WorkoutSource.dropDetectedShadows`, which has handled that case since #975.
///
/// So a sync writes rows and refreshes the read spine. Nothing is re-derived, because nothing derived
/// has changed. Marking days here would buy a marginally tidier workout table at the cost of a 21-day
/// re-score after every gym session — the exact trade this app has spent a lot of effort undoing.
actor HevySyncCoordinator {

    private let fetcher: HevyFetching
    private let store: WhoopStore
    /// Injected so tests can drive a deterministic client; the app passes `HevyAPIClient`.
    private let pageSize: Int
    private let templatePageSize: Int

    init(fetcher: HevyFetching, store: WhoopStore,
         pageSize: Int = HevyAPIClient.listPageSize,
         templatePageSize: Int = HevyAPIClient.templatePageSize) {
        self.fetcher = fetcher
        self.store = store
        self.pageSize = pageSize
        self.templatePageSize = templatePageSize
    }

    // MARK: - The run

    /// One sync. Picks its own strategy: backfill when nothing is stored, incremental otherwise.
    func run(onProgress: @Sendable (HevySyncProgress) -> Void = { _ in }) async throws -> HevySyncSummary {
        var summary = HevySyncSummary()

        // The catalogue first: without it a freshly-synced workout has sets but no muscle group, and
        // the Strength screen would show a session it cannot attribute. Refreshed only when stale — new
        // exercises appear when Hevy ships them or the user creates one, neither of which is hourly.
        if HevySyncState.catalogueIsStale {
            summary.templates = try await syncCatalogue(onProgress: onProgress)
            HevySyncState.recordCatalogueSync()
        }

        let cursor = try await store.hevyNewestUpdatedAt()
        if let cursor {
            let counts = try await syncIncremental(since: cursor, onProgress: onProgress)
            summary.fetchedWorkouts = counts.updated
            summary.deletedWorkouts = counts.deleted
            summary.skipped += counts.skipped
        } else {
            summary.wasBackfill = true
            let counts = try await syncBackfill(onProgress: onProgress)
            summary.fetchedWorkouts = counts.written
            summary.skipped += counts.skipped
        }

        // Routines are the coach's raw material for "adjust my push day". Pulled on a backfill and
        // whenever the catalogue was refreshed, not on every incremental run: they change when the user
        // edits a plan, which is rare, and each page is another request the API asks us to be sparing
        // with.
        if summary.wasBackfill || summary.templates > 0 {
            let counts = try await syncRoutines(onProgress: onProgress)
            summary.routines = counts.written
            summary.skipped += counts.skipped
        }

        // A newly-synced workout can reference an exercise the catalogue does not have — the user
        // created a custom movement since the last refresh. One targeted re-pull rather than leaving
        // its sets permanently unattributed.
        if summary.fetchedWorkouts > 0, try await hasUnknownTemplates() {
            summary.templates += try await syncCatalogue(onProgress: onProgress)
            HevySyncState.recordCatalogueSync()
        }

        return summary
    }

    // MARK: - Strategies

    /// First run: walk the whole workout history, ten at a time.
    private func syncBackfill(onProgress: @Sendable (HevySyncProgress) -> Void) async throws
        -> (written: Int, skipped: Int) {
        var written = 0
        var skipped = 0
        var page = 1
        var total = 1
        repeat {
            onProgress(HevySyncProgress(phase: .backfill, page: page, totalPages: total))
            let body = try await fetcher.get(path: "/workouts",
                                             query: ["page": "\(page)", "pageSize": "\(pageSize)"])
            if page == 1 { total = HevyApiParser.pageCount(body) }
            let parsed = HevyApiParser.parseWorkouts(HevyApiParser.objects(body, key: "workouts"))
            skipped += parsed.skipped
            if !parsed.items.isEmpty {
                try await store.upsertHevyWorkouts(parsed.items)
                try await mirrorToWorkoutRows(parsed.items)
                written += parsed.items.count
            }
            page += 1
        } while page <= total
        return (written, skipped)
    }

    /// Steady state: only what changed, including deletes.
    private func syncIncremental(since cursor: Int,
                                 onProgress: @Sendable (HevySyncProgress) -> Void) async throws
        -> (updated: Int, deleted: Int, skipped: Int) {
        // `since` is exclusive in practice but inclusive by the API's wording, so the same workout can
        // come back once more. That is harmless — every write here is idempotent — and re-delivering
        // one document is much cheaper than risking a missed edit on a boundary second.
        let sinceISO = iso.string(from: Date(timeIntervalSince1970: TimeInterval(cursor)))

        var updates: [HevyWorkout] = []
        var deletions: [String] = []
        var skipped = 0
        var page = 1
        var total = 1
        repeat {
            onProgress(HevySyncProgress(phase: .incremental, page: page, totalPages: total))
            let body = try await fetcher.get(path: "/workouts/events",
                                             query: ["since": sinceISO, "page": "\(page)",
                                                     "pageSize": "\(pageSize)"])
            if page == 1 { total = HevyApiParser.pageCount(body) }
            let parsed = HevyApiParser.parseWorkoutEvents(HevyApiParser.objects(body, key: "events"))
            skipped += parsed.skipped
            for event in parsed.items {
                switch event {
                case .updated(let w): updates.append(w)
                case .deleted(let id, _): deletions.append(id)
                }
            }
            page += 1
        } while page <= total

        // Deletes are applied BEFORE updates. The feed is newest-first, so a workout that was edited
        // and then deleted appears as both; applying the delete last is what makes the final state
        // match Hevy rather than depending on which order the page happened to list them in.
        onProgress(HevySyncProgress(phase: .writing, page: 1, totalPages: 1))
        if !deletions.isEmpty {
            // The store returns the START of every row that actually existed — which is exactly the
            // key the mirrored `WorkoutRow` is stored under, and the only way to find it: a WorkoutRow
            // carries no Hevy id. Resolving them BEFORE the Hevy rows go is why the delete returns them.
            let starts = try await store.deleteHevyWorkouts(ids: deletions)
            try await removeMirroredWorkoutRows(startTimestamps: starts)
            updates.removeAll { deletions.contains($0.id) }
        }
        if !updates.isEmpty {
            try await store.upsertHevyWorkouts(updates)
            try await mirrorToWorkoutRows(updates)
        }
        return (updates.count, deletions.count, skipped)
    }

    /// The exercise catalogue, in full. 100 per page, so a few requests for the whole thing.
    private func syncCatalogue(onProgress: @Sendable (HevySyncProgress) -> Void) async throws -> Int {
        var written = 0
        var page = 1
        var total = 1
        repeat {
            onProgress(HevySyncProgress(phase: .catalogue, page: page, totalPages: total))
            let body = try await fetcher.get(path: "/exercise_templates",
                                             query: ["page": "\(page)", "pageSize": "\(templatePageSize)"])
            if page == 1 { total = HevyApiParser.pageCount(body) }
            let parsed = HevyApiParser.parseExerciseTemplates(
                HevyApiParser.objects(body, key: "exercise_templates"))
            if !parsed.items.isEmpty {
                try await store.upsertHevyExerciseTemplates(parsed.items)
                written += parsed.items.count
            }
            page += 1
        } while page <= total
        return written
    }

    private func syncRoutines(onProgress: @Sendable (HevySyncProgress) -> Void) async throws
        -> (written: Int, skipped: Int) {
        var written = 0
        var skipped = 0
        var page = 1
        var total = 1
        repeat {
            onProgress(HevySyncProgress(phase: .routines, page: page, totalPages: total))
            let body = try await fetcher.get(path: "/routines",
                                             query: ["page": "\(page)", "pageSize": "\(pageSize)"])
            if page == 1 { total = HevyApiParser.pageCount(body) }
            let parsed = HevyApiParser.parseRoutines(HevyApiParser.objects(body, key: "routines"))
            skipped += parsed.skipped
            if !parsed.items.isEmpty {
                try await store.upsertHevyRoutines(parsed.items)
                written += parsed.items.count
            }
            page += 1
        } while page <= total
        return (written, skipped)
    }

    /// True when any stored workout names an exercise the catalogue does not hold.
    private func hasUnknownTemplates() async throws -> Bool {
        let catalogue = try await store.hevyExerciseTemplates()
        let recent = try await store.hevyWorkouts(from: 0, to: Int(Date().timeIntervalSince1970) + 86_400,
                                                  limit: 50)
        for workout in recent {
            for exercise in workout.exercises {
                if let id = exercise.templateId, catalogue[id] == nil { return true }
            }
        }
        return false
    }

    // MARK: - Mirroring into the shared workout table

    /// Write each Hevy session as a `WorkoutRow` under the `"hevy"` source, so it appears in the
    /// Workouts list, on Today and in the coach's existing workout tools without any of them learning
    /// about a second workout model.
    ///
    /// `strain: nil` is the load-bearing part, and it is why lifting can never double-count as cardio:
    /// Effort is computed from the day's heart rate, and a row that carries no strain contributes none.
    /// The HR the session DID produce is attached later and read-side by
    /// `Repository.reconcileWorkoutHrWithTrace`, which fills Avg/Max HR from the strap trace for any row
    /// lacking it. That is the whole "Hevy says what, WHOOP says how the body answered" join — no
    /// matching logic of our own.
    private func mirrorToWorkoutRows(_ workouts: [HevyWorkout]) async throws {
        let catalogue = try await store.hevyExerciseTemplates()
        let rows = workouts.map { workout -> WorkoutRow in
            let summary = HevySource.note(for: workout, templates: catalogue)
            return WorkoutRow(
                startTs: workout.startTs,
                endTs: workout.endTs,
                sport: HevySource.sport,
                source: HevySource.id,
                durationS: workout.durationS,
                energyKcal: nil,
                avgHr: nil,             // filled read-side from the strap trace
                maxHr: nil,
                strain: nil,            // never a fabricated cardiovascular strain
                distanceM: nil,
                zonesJSON: nil,
                notes: summary,
                steps: nil)
        }
        guard !rows.isEmpty else { return }
        try await store.upsertWorkouts(rows, deviceId: HevySource.id)
    }

    /// Remove the mirrored rows for deleted Hevy workouts.
    ///
    /// Deleted by exact start second rather than by a window: a range delete would take any OTHER Hevy
    /// session that happened to share the span, and a workout the user still has in Hevy must never
    /// disappear from NOOP because a neighbouring one was removed.
    private func removeMirroredWorkoutRows(startTimestamps: [Int]) async throws {
        for start in startTimestamps {
            try await store.deleteWorkouts(deviceId: HevySource.id, sport: HevySource.sport,
                                           from: start, to: start)
        }
    }

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

/// The source identity of the Hevy lane, in one place.
///
/// A source of its OWN (`"hevy"`), not the existing `"lifting"` used by the CSV importer: the two can
/// hold the same session — someone who imported a CSV export before connecting the API — and keeping
/// them apart is what lets `WorkoutSource.dedupCrossSource` collapse that pair instead of the app
/// silently overwriting one lane's history with the other's.
enum HevySource {
    static let id = "hevy"
    /// The same sport label the CSV lane uses, so the two fold to one `sportKey` and the cross-source
    /// dedup recognises them as the same activity.
    static let sport = "Strength Training"

    /// The one-line note carried on the mirrored `WorkoutRow` — what the Workouts list shows before
    /// anyone opens the session. Same shape as the CSV lane's `volumeLoadNote`, so a Hevy row and an
    /// imported one read alike, plus the working-set count that is the figure strength training is
    /// actually prescribed in.
    ///
    /// Every part is omitted when it has nothing to say: a calisthenics session states its sets and no
    /// volume, rather than claiming "0 kg".
    static func note(for workout: HevyWorkout,
                     templates: [String: HevyExerciseTemplate]) -> String {
        let s = StrengthSession.summarize(workout, templates: templates)
        var parts: [String] = []
        if s.volumeLoadKg > 0 {
            parts.append(String(localized: "volume load \(groupedKg(s.volumeLoadKg)) kg"))
        }
        parts.append(s.workingSetCount == 1
                     ? String(localized: "1 working set")
                     : String(localized: "\(s.workingSetCount) working sets"))
        if s.exerciseCount > 0 {
            parts.append(s.exerciseCount == 1
                         ? String(localized: "1 exercise")
                         : String(localized: "\(s.exerciseCount) exercises"))
        }
        var note = String(localized: "Strength") + " · " + parts.joined(separator: " · ")
        if !workout.title.isEmpty { note = "\(workout.title): " + note }
        return note
    }

    /// A kilogram total with thousands separators. Guards against a non-finite accumulation the way the
    /// CSV lane does — `Int(inf.rounded())` traps.
    static func groupedKg(_ kg: Double) -> String {
        guard kg.isFinite, kg >= 0, kg < 1e12 else { return "0" }
        let n = Int(kg.rounded())
        return groupedFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
}
