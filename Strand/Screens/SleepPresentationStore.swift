import SwiftUI
import WhoopStore
import StrandAnalytics

/// A completed value and its in-flight task are shared by all consumers of one revision.
/// Cancelling a consumer must not cancel another visible card's identical request.
@MainActor
final class PresentationTaskCache<Key: Hashable, Value: Sendable> {
    private var values: [Key: Value] = [:]
    private var tasks: [Key: (UUID, Task<Value, Error>)] = [:]
    private let capacity: Int
    init(capacity: Int = 8) { self.capacity = capacity }

    private var generation = 0

    func value(for key: Key, load: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if let value = values[key] { return value }
        let requestGeneration = generation
        let token: UUID
        let task: Task<Value, Error>
        if let existing = tasks[key] {
            (token, task) = existing
        } else {
            token = UUID()
            task = Task { try await load() }
            tasks[key] = (token, task)
        }
        do {
            let value = try await task.value
            guard generation == requestGeneration, !task.isCancelled else { throw CancellationError() }
            if tasks[key]?.0 == token {
                tasks[key] = nil
                if values.count >= capacity { values.removeAll(keepingCapacity: true) }
                values[key] = value
            }
            // Keep a successful shared result even when this particular consumer went away.
            try Task.checkCancellation()
            return value
        } catch {
            if tasks[key]?.0 == token { tasks[key] = nil }
            throw error
        }
    }

    func invalidate() {
        generation &+= 1
        for (_, task) in tasks.values { task.cancel() }
        tasks.removeAll()
        values.removeAll()
    }
}

struct SleepPresentationRevision: Hashable, Sendable {
    let sequence: Int
    let sleepEdits: Int
    let source: String
    let loaded: Bool
    let timeZone: String
    let offset: Int
    let day: String
    let dayCycle: String

    @MainActor init(repo: Repository) {
        sleepEdits = repo.sleepPresentationRevision
        sequence = repo.refreshSeq; source = repo.deviceId; loaded = repo.loaded
        timeZone = TimeZone.current.identifier; offset = TimeZone.current.secondsFromGMT()
        day = Repository.localDayKey(Date())
        dayCycle = UserDefaults.standard.string(forKey: DayCycleMode.storageKey) ?? ""
    }
}

struct SleepPresentation: Sendable {
    var model: SleepModel?
    let sessions: [CachedSleepSession]
    let groups: [[CachedSleepSession]]
    let habitualMidsleepSec: Int?
}

/// Scene-local, read-only presentation cache; no raw data or analysis recipes are changed.
@MainActor
final class SleepPresentationStore: ObservableObject {
    private let loadMotion: @MainActor (Repository, [CachedSleepSession]) async -> [Int: [Double]]
    init(loadMotion: @escaping @MainActor (Repository, [CachedSleepSession]) async -> [Int: [Double]] = {
        await $0.sessionMotions(sessions: $1)
    }) { self.loadMotion = loadMotion }

    private var revision: SleepPresentationRevision?
    private let histories = PresentationTaskCache<SleepPresentationRevision, SleepPresentation>(capacity: 1)
    private let nights = PresentationTaskCache<Int, Night?>()
    private let heartRates = PresentationTaskCache<String, [HRBucket]>()

    private func adopt(_ key: SleepPresentationRevision) {
        guard revision != key else { return }
        revision = key
        histories.invalidate(); nights.invalidate(); heartRates.invalidate()
    }

    func presentation(repo: Repository, revision key: SleepPresentationRevision) async throws -> SleepPresentation {
        guard key == SleepPresentationRevision(repo: repo) else { throw CancellationError() }
        adopt(key)
        return try await histories.value(for: key) {
            let days = repo.days, sleeps = repo.sleeps, imported = repo.importedSleep
            let sessions = await repo.allSleepSessions()
            try Task.checkCancellation()
            let habitual = await repo.habitualMidsleepSec()
            try Task.checkCancellation()
            let inputs = SleepModelInputs(days: days, sleeps: sleeps, allSessions: sessions,
                importedSleep: imported, habitualMidsleepSec: habitual, motionByStart: [:])
            let result = await runUnescalated {
                var model = SleepModel.build(inputs)
                if let night = model?.night { model?.night = night.preparingForDisplay() }
                return SleepPresentation(model: model, sessions: sessions,
                    groups: SleepModel.navDays(navSessions: sessions.isEmpty ? sleeps : sessions),
                    habitualMidsleepSec: habitual)
            }
            try Task.checkCancellation()
            guard key == SleepPresentationRevision(repo: repo) else { throw CancellationError() }
            return result
        }
    }

    func night(offset: Int, presentation: SleepPresentation, repo: Repository,
               revision key: SleepPresentationRevision) async throws -> Night? {
        guard revision == key, key == SleepPresentationRevision(repo: repo) else { throw CancellationError() }
        return try await nights.value(for: offset) {
            let groups = presentation.groups
            guard groups.indices.contains(offset) else { return nil }
            let habitual = presentation.habitualMidsleepSec
            let blocks = await runUnescalated {
                SleepView.mainNightGroup(groups[offset], habitualMidsleepSec: habitual)
            }
            try Task.checkCancellation()
            let motion = await self.loadMotion(repo, blocks)
            try Task.checkCancellation()
            let result: Night? = await runUnescalated {
                if let night = SleepModel.decodedNight(at: offset, navDays: groups,
                    habitualMidsleepSec: habitual, motionByStart: motion) {
                    return night.preparingForDisplay()
                }
                guard let stub = SleepView.stubDaySession(groups[offset], habitualMidsleepSec: habitual) else { return nil }
                return Night(session: stub, stages: Stages(awake: 0, light: 0, deep: 0, rem: 0),
                    sourceBlocks: groups[offset], habitualMidsleepSec: habitual).preparingForDisplay()
            }
            try Task.checkCancellation()
            guard key == SleepPresentationRevision(repo: repo) else { throw CancellationError() }
            return result
        }
    }

    func model(repo: Repository, revision key: SleepPresentationRevision) async throws -> SleepModel? {
        let base = try await presentation(repo: repo, revision: key)
        var model = base.model
        if let night = try await night(offset: 0, presentation: base, repo: repo, revision: key) {
            model?.night = night
        }
        return model
    }

    func hr(for night: Night, repo: Repository, revision key: SleepPresentationRevision) async throws -> [HRBucket] {
        guard revision == key, key == SleepPresentationRevision(repo: repo) else { throw CancellationError() }
        let from = night.session.startTs, to = night.session.endTs
        return try await heartRates.value(for: "\(from):\(to)") {
            let result = await repo.hrBuckets(from: from, to: to, bucketSeconds: 60)
            try Task.checkCancellation()
            guard key == SleepPresentationRevision(repo: repo) else { throw CancellationError() }
            return result
        }
    }
}

private struct SleepPresentationEnvironmentKey: EnvironmentKey {
    static let defaultValue: SleepPresentationStore? = nil
}
private struct DashboardAppModelKey: EnvironmentKey {
    static let defaultValue: AppModel? = nil
}
extension EnvironmentValues {
    var sleepPresentationStore: SleepPresentationStore? {
        get { self[SleepPresentationEnvironmentKey.self] }
        set { self[SleepPresentationEnvironmentKey.self] = newValue }
    }
    /// Read only during load; dynamic AppModel observations belong in small leaf views.
    var dashboardAppModel: AppModel? {
        get { self[DashboardAppModelKey.self] }
        set { self[DashboardAppModelKey.self] = newValue }
    }
}

private struct DashboardPresentationScope: ViewModifier {
    let model: AppModel
    @StateObject private var sleep = SleepPresentationStore()
    func body(content: Content) -> some View {
        content.environment(\.sleepPresentationStore, sleep).environment(\.dashboardAppModel, model)
    }
}
extension View {
    func dashboardPresentationScope(model: AppModel) -> some View {
        modifier(DashboardPresentationScope(model: model))
    }
}
