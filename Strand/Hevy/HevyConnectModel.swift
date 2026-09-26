import Foundation
import Combine
import WhoopStore

/// Drives the Data Sources "Hevy" card: paste a key → verify it → sync → an honest summary → disconnect.
///
/// `@MainActor` so every `@Published` mutation is on the main thread; the network and store work hops
/// off it inside the task.
///
/// `repo: Repository` is taken as a PARAMETER on each action rather than stored at construction, for
/// the same reason `OuraConnectModel` does it: `Repository` reaches `DataSourcesView` through
/// `@EnvironmentObject`, which SwiftUI populates only AFTER `init()` runs, so capturing it in a
/// property initialiser crashes at runtime with "No ObservableObject of type Repository found".
@MainActor
final class HevyConnectModel: ObservableObject {

    /// What the card is doing right now.
    enum Phase: Equatable {
        case idle
        case verifying
        case syncing(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isConnected = HevyCredentials.isConnected
    @Published private(set) var status: HevySyncStatus = HevySyncState.load()
    /// The last thing that happened, in one line, success or failure.
    @Published var message: String?
    /// True when `message` describes a failure, so the card can tint it.
    @Published var failed = false

    var isBusy: Bool { phase != .idle }

    /// The stored key, redacted enough to recognise but not to reuse.
    var redactedKey: String? { HevyCredentials.load().map(HevyCredentials.redacted) }

    // MARK: - Connect

    /// Verify a pasted key against the account, and only store it if the API accepts it.
    ///
    /// Verifying FIRST matters: a mistyped key stored silently means the first sync fails minutes later
    /// in the background, where the user is not looking. `/user/info` is the cheapest authenticated
    /// call and touches no training data, so a failed attempt reads nothing it need not.
    func connect(key: String, repo: Repository) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            report(String(localized: "Paste your Hevy API key first."), failed: true)
            return
        }
        phase = .verifying
        message = String(localized: "Checking the key with Hevy…")
        failed = false
        Task {
            let client = HevyAPIClient(keyProvider: { trimmed })
            do {
                try await client.verifyKey()
            } catch {
                phase = .idle
                report(describe(error), failed: true)
                return
            }
            guard HevyCredentials.save(trimmed) else {
                phase = .idle
                report(String(localized: "Couldn't store the key in the Keychain."), failed: true)
                return
            }
            isConnected = true
            HevySyncState.isEnabled = true
            phase = .idle
            await sync(repo: repo)
        }
    }

    // MARK: - Sync

    func sync(repo: Repository) async {
        guard isConnected else {
            report(HevyError.notConnected.errorDescription ?? "", failed: true)
            return
        }
        phase = .syncing(String(localized: "Starting…"))
        failed = false
        defer { phase = .idle }

        guard let store = await repo.storeHandle() else {
            report(String(localized: "Couldn't open the local store."), failed: true)
            return
        }

        let coordinator = HevySyncCoordinator(fetcher: HevyAPIClient(), store: store)
        do {
            let summary = try await coordinator.run { [weak self] progress in
                Task { @MainActor in self?.phase = .syncing(Self.describe(progress)) }
            }
            // Refresh the read spine so the new sessions appear in Workouts and on Today. NOT an
            // analysis pass: a logged set changes no score, so nothing needs re-deriving — see
            // `HevySyncCoordinator`'s note on why this lane invalidates no day.
            await repo.refresh()
            // A logged session is also the workout context the strap energy model prices its heart
            // rate under, so a sync that changed sessions re-prices the window the model keeps.
            if summary.fetchedWorkouts + summary.deletedWorkouts > 0 {
                repo.scheduleEnergyRefresh(coveringStart: 0)
            }

            let stored = (try? await store.hevyWorkoutCount()) ?? 0
            HevySyncState.recordSuccess(storedWorkouts: stored, skipped: summary.skipped)
            status = HevySyncState.load()
            report(Self.describe(summary, stored: stored), failed: false)
        } catch {
            let text = describe(error)
            HevySyncState.recordFailure(text)
            status = HevySyncState.load()
            report(text, failed: true)
        }
    }

    // MARK: - Disconnect

    /// Forget the key but KEEP the synced history. The sessions are the user's own training record;
    /// revoking an integration should not delete months of it by surprise.
    func disconnect() {
        HevyCredentials.clear()
        HevySyncState.isEnabled = false
        isConnected = false
        report(String(localized: "Disconnected. Your synced sessions are still here."), failed: false)
    }

    /// Forget the key AND everything synced from it. The destructive twin, for someone who wants no
    /// trace left; the caller confirms before calling it.
    func disconnectAndForget(repo: Repository) {
        Task {
            if let store = await repo.storeHandle() {
                // The mirrored rows live in the shared workout table, so they are removed here rather
                // than in `deleteAllHevyData`, which only owns the Hevy tables.
                _ = try? await store.deleteWorkouts(deviceId: HevySource.id, sport: HevySource.sport,
                                                    from: 0, to: Int(Date().timeIntervalSince1970) + 86_400)
                try? await store.deleteAllHevyData()
            }
            HevyCredentials.clear()
            HevySyncState.reset()
            isConnected = false
            status = HevySyncState.load()
            await repo.refresh()
            repo.scheduleEnergyRefresh(coveringStart: 0)
            report(String(localized: "Disconnected and removed every synced session."), failed: false)
        }
    }

    // MARK: - Wording

    private func report(_ text: String, failed: Bool) {
        message = text
        self.failed = failed
    }

    /// Errors reach the card as their own sentence. `HevyError` already says what to DO — a rejected
    /// key and a valid key on a non-Pro account are both fixable, and both invisible without being told
    /// which one happened.
    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func describe(_ progress: HevySyncProgress) -> String {
        let step = progress.totalPages > 1
            ? " (\(progress.page)/\(progress.totalPages))"
            : ""
        switch progress.phase {
        case .catalogue:   return String(localized: "Loading the exercise list…") + step
        case .backfill:    return String(localized: "Importing your training history…") + step
        case .incremental: return String(localized: "Checking for new sessions…") + step
        case .routines:    return String(localized: "Loading your routines…") + step
        case .writing:     return String(localized: "Saving…")
        }
    }

    /// One line for what a run did. Whole-phrase variants per count so a translator never sees a
    /// stitched plural, matching the lifting importer's existing summaries.
    private static func describe(_ summary: HevySyncSummary, stored: Int) -> String {
        var parts: [String] = []
        if summary.wasBackfill {
            parts.append(stored == 1
                         ? String(localized: "Imported 1 session")
                         : String(localized: "Imported \(stored) sessions"))
        } else if summary.fetchedWorkouts == 0 && summary.deletedWorkouts == 0 {
            parts.append(String(localized: "Already up to date"))
        } else {
            if summary.fetchedWorkouts > 0 {
                parts.append(summary.fetchedWorkouts == 1
                             ? String(localized: "1 session updated")
                             : String(localized: "\(summary.fetchedWorkouts) sessions updated"))
            }
            if summary.deletedWorkouts > 0 {
                parts.append(summary.deletedWorkouts == 1
                             ? String(localized: "1 session removed")
                             : String(localized: "\(summary.deletedWorkouts) sessions removed"))
            }
        }
        if summary.templates > 0 {
            parts.append(String(localized: "\(summary.templates) exercises"))
        }
        // Reported rather than swallowed: a tolerant parser that never says what it dropped is
        // indistinguishable from a broken one.
        if summary.skipped > 0 {
            parts.append(String(localized: "\(summary.skipped) skipped"))
        }
        return parts.joined(separator: " · ")
    }
}
