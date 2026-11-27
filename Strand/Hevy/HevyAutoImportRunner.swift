import Foundation
import StrandCore

/// The automatic Hevy import on Apple (Discord 2026-11-27): asked when the app comes to the foreground and, on
/// iOS, from its own background refresh. `HevyAutoImport` in the core decides whether a run is due, the same
/// rule the Android worker asks, and the run itself is the one "Sync now" makes (`HevyConnectModel.runSync`).
@MainActor
enum HevyAutoImportRunner {
    private static var running = false

    /// Runs one import when the wearer chose an interval, a key is stored, Hevy has not refused it, and the last
    /// successful run is old enough. Returns whether a run completed.
    @discardableResult
    static func runIfDue(repo: Repository, now: Date = Date()) async -> Bool {
        guard !running, HevySyncState.isEnabled, HevyCredentials.isConnected, !HevySyncState.autoBlocked,
              HevyAutoImport.isDue(lastRun: lastRun, now: Int(now.timeIntervalSince1970),
                                   interval: HevySyncState.autoInterval),
              let store = await repo.storeHandle() else { return false }
        running = true
        defer { running = false }
        do {
            _ = try await HevyConnectModel.runSync(store: store, repo: repo)
            return true
        } catch {
            let hevy = error as? HevyError
            HevySyncState.recordFailure((hevy?.errorDescription) ?? error.localizedDescription)
            // A key Hevy rejects or an account it does not serve changes only when the wearer acts; asking again
            // every few hours would only repeat the refusal.
            switch hevy {
            case .notConnected, .unauthorized, .notPro: HevySyncState.autoBlocked = true
            default: break
            }
            return false
        }
    }

    /// When the next run is due, for the background request's begin date; nil when nothing should be asked.
    static func nextDue(now: Date = Date()) -> Date? {
        guard HevySyncState.isEnabled, HevyCredentials.isConnected, !HevySyncState.autoBlocked,
              let due = HevyAutoImport.nextDue(lastRun: lastRun, now: Int(now.timeIntervalSince1970),
                                                interval: HevySyncState.autoInterval) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(due))
    }

    private static var lastRun: Int? {
        HevySyncState.load().lastSuccess.map { Int($0.timeIntervalSince1970) }
    }
}
