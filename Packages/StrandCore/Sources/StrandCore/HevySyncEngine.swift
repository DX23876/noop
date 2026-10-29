import Foundation
import WhoopStore
import StrandImport
import StrandAnalytics

/// How far along a running sync is, for the Data Sources card.
public struct HevyImportProgress: Equatable, Sendable {
    public enum Phase: String, Equatable, Sendable {
        case catalogue          // pulling the exercise templates
        case backfill           // first run: walking the whole workout history
        case incremental        // steady state: only what changed
        case routines
        case writing
    }
    public var phase: Phase
    public var page: Int
    public var totalPages: Int
}

/// What one run did.
public struct HevyImportSummary: Equatable, Codable, Sendable {
    public var fetchedWorkouts = 0
    public var deletedWorkouts = 0
    public var templates = 0
    public var routines = 0
    public var skipped = 0
    /// True when this run walked the whole history rather than the incremental feed.
    public var wasBackfill = false
    public init() {}
}

/// The transport seam for both the Apple host and the Android JNI host.
public protocol HevyReadFetching {
    func get(path: String, query: [String: String]) async throws -> Data
}

public enum HevyImportError: String, Error, Sendable {
    case notConnected, unauthorized, notPro, rateLimited, network, decode, limitExceeded, busy
}

/// Shared import orchestration. Only fully read pages advance the persistent sync frontier.
public actor HevySyncEngine {

    private let fetcher: HevyReadFetching
    private let store: WhoopStore
    /// Injected so tests can drive a deterministic client; the app passes `HevyAPIClient`.
    private let pageSize: Int
    private let templatePageSize: Int
    private var seenWorkoutIds: Set<String> = []
    private let note: (HevyWorkout, [String: HevyExerciseTemplate]) -> String

    public init(fetcher: HevyReadFetching, store: WhoopStore,
         pageSize: Int = 10,
         templatePageSize: Int = 100,
                note: @escaping (HevyWorkout, [String: HevyExerciseTemplate]) -> String = HevyImportNote.note) {
        self.note = note
        self.fetcher = fetcher
        self.store = store
        self.pageSize = min(10, max(1, pageSize))
        self.templatePageSize = min(100, max(1, templatePageSize))
    }

    // MARK: - The run

    /// Backfill until a complete run is banked, then consume events from the last complete frontier.
    public func run(onProgress: @Sendable (HevyImportProgress) -> Void = { _ in }) async throws -> HevyImportSummary {
        let key = ObjectIdentifier(store)
        guard await HevyImportLease.shared.acquire(key) else { throw HevyImportError.busy }
        do {
            seenWorkoutIds = []
            let result = try await perform(onProgress: onProgress)
            await HevyImportLease.shared.release(key)
            return result
        } catch {
            await HevyImportLease.shared.release(key)
            throw error
        }
    }

    private func perform(onProgress: @Sendable (HevyImportProgress) -> Void) async throws -> HevyImportSummary {
        var summary = HevyImportSummary()
        let now = Int(Date().timeIntervalSince1970)
        try Task.checkCancellation()

        // The catalogue first: without it a freshly-synced workout has sets but no muscle group, and
        // the Strength screen would show a session it cannot attribute. Refreshed only when stale — new
        // exercises appear when Hevy ships them or the user creates one, neither of which is hourly.
        if (try await store.cursor("hevy:catalogueSyncedAt") ?? 0) < now - 7 * 86_400 {
            summary.templates = try await syncCatalogue(onProgress: onProgress)
            try await store.setCursor("hevy:catalogueSyncedAt", now)
        }

        let completed = try await store.cursor("hevy:backfillComplete") == 1
        let cursor = completed ? try await store.cursor("hevy:syncFrontier") : nil
        let prior = completed ? nil : try await store.hevyOldestUpdatedAt()
        var backfillFrontier = 1
        if let cursor {
            let counts = try await syncIncremental(since: cursor, onProgress: onProgress)
            summary.fetchedWorkouts = counts.updated
            summary.deletedWorkouts = counts.deleted
            summary.skipped += counts.skipped
        } else {
            summary.wasBackfill = true
            let counts = try await syncBackfill(onProgress: onProgress)
            summary.fetchedWorkouts = counts.written
            backfillFrontier = counts.frontier
            summary.skipped += counts.skipped
            let replayStart = min(prior ?? counts.frontier, counts.frontier)
            let recovery = try await syncIncremental(since: replayStart, onProgress: onProgress)
            summary.deletedWorkouts += recovery.deleted; summary.skipped += recovery.skipped
        }

        // Routines are the coach's raw material for "adjust my push day". Pulled on a backfill and
        // whenever the catalogue was refreshed, not on every incremental run: they change when the user
        // edits a plan, which is rare, and each page is another request the API asks us to be sparing
        // with.
        let routinesStale = (try await store.cursor("hevy:routinesSyncedAt") ?? 0) < now - 7 * 86_400
        if summary.wasBackfill || summary.templates > 0 || routinesStale {
            let counts = try await syncRoutines(onProgress: onProgress)
            summary.routines = counts.written
            summary.skipped += counts.skipped
        }

        // A newly-synced workout can reference an exercise the catalogue does not have — the user
        // created a custom movement since the last refresh. One targeted re-pull rather than leaving
        // its sets permanently unattributed.
        let unknownWorkouts = summary.fetchedWorkouts > 0 ? try await hasUnknownTemplates() : false
        let unknownRoutines = summary.routines > 0 ? try await hasUnknownRoutineTemplates() : false
        if unknownWorkouts || unknownRoutines {
            summary.templates += try await syncCatalogue(onProgress: onProgress)
            try await store.setCursor("hevy:catalogueSyncedAt", now)
        }

        if summary.skipped == 0 {
            try Task.checkCancellation()
            let previous = try await store.cursor("hevy:syncFrontier") ?? 1
            try await store.setCursor("hevy:syncFrontier", max(previous, backfillFrontier))
            try await store.setCursor("hevy:backfillComplete", 1)
        }
        summary.fetchedWorkouts = seenWorkoutIds.count
        return summary
    }

    // MARK: - Strategies

    /// First run: walk the whole workout history, ten at a time.
    private func syncBackfill(onProgress: @Sendable (HevyImportProgress) -> Void) async throws
        -> (written: Int, skipped: Int, frontier: Int) {
        var written = 0, frontier = 1
        var skipped = 0
        var page = 1
        var total = 1
        repeat {
            try Task.checkCancellation()
            onProgress(HevyImportProgress(phase: .backfill, page: page, totalPages: total))
            let body = try await fetchPage(path: "/workouts",
                                             query: ["page": "\(page)", "pageSize": "\(pageSize)"])
            total = max(total, HevyApiParser.pageCount(body))
            let parsed = Self.completeWorkouts(HevyApiParser.objects(body, key: "workouts"))
            skipped += parsed.skipped
            if !parsed.items.isEmpty {
                try await mirrorToWorkoutRows(parsed.items)
                written += parsed.items.count
                if page == 1 { frontier = max(frontier, parsed.items.map(\.updatedAtTs).max() ?? 1) }
            }
            page += 1
        } while page <= total
        return (written, skipped, frontier)
    }

    /// Steady state: only what changed, including deletes.
    private func syncIncremental(since cursor: Int,
                                 onProgress: @Sendable (HevyImportProgress) -> Void) async throws
        -> (updated: Int, deleted: Int, skipped: Int) {
        // `since` is exclusive in practice but inclusive by the API's wording, so the same workout can
        // come back once more. That is harmless — every write here is idempotent — and re-delivering
        // one document is much cheaper than risking a missed edit on a boundary second.
        let sinceISO = iso.string(from: Date(timeIntervalSince1970: TimeInterval(max(0, cursor - 1))))

        var changes: [String: (Int, HevyWorkoutEvent)] = [:]
        var skipped = 0, eventFrontier = cursor, page = 1, total = 1
        repeat {
            try Task.checkCancellation()
            onProgress(HevyImportProgress(phase: .incremental, page: page, totalPages: total))
            let body = try await fetchPage(path: "/workouts/events",
                query: ["since": sinceISO, "page": "\(page)", "pageSize": "\(pageSize)"])
            total = max(total, HevyApiParser.pageCount(body))
            let parsed = Self.completeEvents(HevyApiParser.objects(body, key: "events"))
            skipped += parsed.skipped
            for event in parsed.items {
                let id: String, rank: Int, observed: Int, deletion: Bool
                switch event {
                case .updated(let w): id = w.id; rank = w.updatedAtTs; observed = w.updatedAtTs; deletion = false
                case .deleted(let key, let at): id = key; rank = at > 0 ? at : Int.max; observed = at; deletion = true
                }
                if page == 1 { eventFrontier = max(eventFrontier, observed) }
                if changes[id] == nil || rank > changes[id]!.0 || (rank == changes[id]!.0 && deletion) {
                    changes[id] = (rank, event)
                }
            }
            page += 1
        } while page <= total
        var updates: [HevyWorkout] = [], deletions: [String] = []
        for key in changes.keys.sorted() {
            switch changes[key]!.1 {
            case .updated(let w): updates.append(w)
            case .deleted(let id, _): deletions.append(id)
            }
        }
        onProgress(HevyImportProgress(phase: .writing, page: 1, totalPages: 1))
        let removed = try await mirrorToWorkoutRows(updates, deletedIds: deletions, frontier: skipped == 0 ? eventFrontier : nil)
        return (updates.count, removed, skipped)
    }

    /// The exercise catalogue, in full. 100 per page, so a few requests for the whole thing.
    private func syncCatalogue(onProgress: @Sendable (HevyImportProgress) -> Void) async throws -> Int {
        var written = 0
        var page = 1
        var total = 1
        repeat {
            try Task.checkCancellation()
            onProgress(HevyImportProgress(phase: .catalogue, page: page, totalPages: total))
            let body = try await fetchPage(path: "/exercise_templates",
                                             query: ["page": "\(page)", "pageSize": "\(templatePageSize)"])
            total = max(total, HevyApiParser.pageCount(body))
            let parsed = HevyApiParser.parseExerciseTemplates(
                HevyApiParser.objects(body, key: "exercise_templates"))
            guard parsed.skipped == 0 else { throw HevyImportError.decode }
            if !parsed.items.isEmpty {
                try await store.upsertHevyExerciseTemplates(parsed.items)
                written += parsed.items.count
            }
            page += 1
        } while page <= total
        return written
    }

    /// Pulls the routines alone, for a routine import the wearer asked for: the regular run fetches them
    /// only on a backfill or a catalogue refresh. Returns the ids Hevy holds now, since a routine deleted
    /// in Hevy stays in the store and must not be offered again.
    public func refreshRoutines() async throws -> Set<String> {
        let key = ObjectIdentifier(store)
        guard await HevyImportLease.shared.acquire(key) else { throw HevyImportError.busy }
        do {
            let now = Int(Date().timeIntervalSince1970)
            if (try await store.cursor("hevy:catalogueSyncedAt") ?? 0) < now - 7 * 86_400 {
                _ = try await syncCatalogue(onProgress: { _ in })
                try await store.setCursor("hevy:catalogueSyncedAt", now)
            }
            let result = try await syncRoutines(onProgress: { _ in }).ids
            if try await hasUnknownRoutineTemplates() {
                _ = try await syncCatalogue(onProgress: { _ in })
                try await store.setCursor("hevy:catalogueSyncedAt", now)
            }
            await HevyImportLease.shared.release(key)
            return result
        } catch {
            await HevyImportLease.shared.release(key)
            throw error
        }
    }

    private func syncRoutines(onProgress: @Sendable (HevyImportProgress) -> Void) async throws
        -> (written: Int, skipped: Int, ids: Set<String>) {
        var routines: [HevyRoutine] = [], skipped = 0, page = 1, total = 1
        repeat {
            try Task.checkCancellation()
            onProgress(HevyImportProgress(phase: .routines, page: page, totalPages: total))
            let body = try await fetchPage(path: "/routines", query: ["page": "\(page)", "pageSize": "\(pageSize)"])
            total = max(total, HevyApiParser.pageCount(body))
            let parsed = HevyApiParser.parseRoutines(HevyApiParser.objects(body, key: "routines"))
            routines += parsed.items; skipped += parsed.skipped
            page += 1
        } while page <= total
        guard skipped == 0 else { throw HevyImportError.decode }
        try Task.checkCancellation()
        try await store.replaceHevyRoutines(routines, syncedAt: Int(Date().timeIntervalSince1970))
        return (routines.count, skipped, Set(routines.map(\.id)))
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

    private func hasUnknownRoutineTemplates() async throws -> Bool {
        let catalogue = try await store.hevyExerciseTemplates()
        for routine in try await store.hevyRoutines() {
            guard let root = try? JSONSerialization.jsonObject(with: Data(routine.rawJSON.utf8)) as? [String: Any] else { continue }
            for exercise in root["exercises"] as? [[String: Any]] ?? [] {
                if let id = exercise["exercise_template_id"] as? String, catalogue[id] == nil { return true }
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
    @discardableResult
    private func mirrorToWorkoutRows(_ workouts: [HevyWorkout], deletedIds: [String] = [], frontier: Int? = nil) async throws -> Int {
        let catalogue = try await store.hevyExerciseTemplates()
        let rows = workouts.map { workout -> WorkoutRow in
            let summary = note(workout, catalogue)
            return WorkoutRow(
                startTs: workout.startTs,
                endTs: workout.endTs,
                sport: "Strength Training",
                source: WorkoutSource.hevySource,
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
        let now = Int(Date().timeIntervalSince1970)
        let metadata = workouts.map {
            WorkoutSourceMetadataRow(componentKey: "hevy|\($0.id)", source: WorkoutSource.hevySource,
                                     startTs: $0.startTs, sport: "Strength Training",
                                     externalId: $0.id, sourceBundleId: nil,
                                     rawActivityType: nil, activitiesJSON: nil, updatedAtTs: now)
        }
        try Task.checkCancellation()
        let removed = try await store.applyHevyImport(workouts, deletedIds: deletedIds, rows: rows, metadata: metadata, frontier: frontier)
        seenWorkoutIds.formUnion(workouts.map(\.id))
        return removed
    }

    private func fetchPage(path: String, query: [String: String]) async throws -> Data {
        let body = try await fetcher.get(path: path, query: query)
        try Task.checkCancellation()
        guard body.count <= 8 * 1024 * 1024,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let count = root["page_count"] as? Int, (0...2_000).contains(count) else {
            throw HevyImportError.decode
        }
        let key = path == "/workouts/events" ? "events" : String(path.dropFirst())
        guard let items = root[key] as? [Any], items.allSatisfy({ $0 is [String: Any] }) else {
            throw HevyImportError.decode
        }
        return body
    }

    private static func completeWorkouts(_ docs: [[String: Any]]) -> HevyParseResult<HevyWorkout> {
        var items: [HevyWorkout] = [], skipped = 0
        for doc in docs {
            let parsed = HevyApiParser.parseWorkouts([doc])
            if parsed.skipped == 0 { items += parsed.items } else { skipped += parsed.skipped }
        }
        return HevyParseResult(items: items, skipped: skipped)
    }

    private static func completeEvents(_ docs: [[String: Any]]) -> HevyParseResult<HevyWorkoutEvent> {
        var items: [HevyWorkoutEvent] = [], skipped = 0
        for doc in docs {
            let parsed = HevyApiParser.parseWorkoutEvents([doc])
            if parsed.skipped == 0 { items += parsed.items } else { skipped += parsed.skipped }
        }
        return HevyParseResult(items: items, skipped: skipped)
    }

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}


private actor HevyImportLease {
    static let shared = HevyImportLease()
    private var stores: Set<ObjectIdentifier> = []
    func acquire(_ key: ObjectIdentifier) -> Bool { stores.insert(key).inserted }
    func release(_ key: ObjectIdentifier) { stores.remove(key) }
}

/// English fallback for the Android source note; Apple supplies its existing localized formatter.
public enum HevyImportNote {
    public static func note(_ workout: HevyWorkout, _ templates: [String: HevyExerciseTemplate]) -> String {
        let summary = StrengthSession.summarize(workout, templates: templates)
        var parts: [String] = []
        if summary.volumeLoadKg.isFinite, summary.volumeLoadKg > 0, summary.volumeLoadKg < 1e12 {
            let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.maximumFractionDigits = 0
            parts.append("volume load \(formatter.string(from: NSNumber(value: summary.volumeLoadKg)) ?? "") kg")
        }
        parts.append(summary.workingSetCount == 1 ? "1 working set" : "\(summary.workingSetCount) working sets")
        if summary.exerciseCount > 0 { parts.append(summary.exerciseCount == 1 ? "1 exercise" : "\(summary.exerciseCount) exercises") }
        let note = "Strength · " + parts.joined(separator: " · ")
        return workout.title.isEmpty ? note : "\(workout.title): " + note
    }
}
