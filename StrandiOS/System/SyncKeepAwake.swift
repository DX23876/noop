#if os(iOS)
import Combine
import Foundation

/// Holds the screen awake while a strap history sync runs, when Settings → "Keep screen on while syncing"
/// is on (default OFF). Follows `LiveState.backfilling` for the whole sync, whichever trigger started it
/// (Sync now, the Sync Strap shortcut, a foreground or periodic sync), and releases the hold the moment the
/// sync ends or the toggle is switched off.
///
/// A Combine subscription attached once at launch, not a modifier on `StrandiOSApp.body`: that modifier
/// chain has already exceeded the type-checker's budget (#1767).
@MainActor
final class SyncKeepAwake {
    static let shared = SyncKeepAwake()

    private var cancellable: AnyCancellable?

    private init() {}

    func attach(to live: LiveState) {
        let key = ScreenIdle.strapSyncKeepAwakeKey
        let enabled = NotificationCenter.default
            .publisher(for: UserDefaults.didChangeNotification)
            .map { _ in UserDefaults.standard.bool(forKey: key) }
            .prepend(UserDefaults.standard.bool(forKey: key))
        cancellable = live.$backfilling
            .combineLatest(enabled)
            .map { backfilling, on in backfilling && on }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { hold in
                MainActor.assumeIsolated { ScreenIdle.hold(.strapSync, hold) }
            }
    }
}
#endif
