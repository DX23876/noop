// Compiled ONLY when the OURA_CLOUD_IMPORT compilation condition is set (by the untracked
// OuraSecrets.xcconfig — see OuraConfig.xcconfig). A default build contains none of this code,
// keeping "fully offline" a byte-level property of the shipped binary, not a runtime promise.
#if OURA_CLOUD_IMPORT
import Foundation
import Combine
import AuthenticationServices
import WhoopStore
#if os(iOS)
import UIKit
#endif

/// Drives the Data Sources "Connect Oura" card: connect (OAuth) → one-time backfill → honest summary →
/// disconnect. @MainActor so all @Published mutations are main-thread; the network/backfill hops off-main.
///
/// `repo: Repository` is taken as a PARAMETER on each action rather than stored at construction. `Repository`
/// only reaches `DataSourcesView` via `@EnvironmentObject`, which SwiftUI populates after `init()` runs —
/// storing it in a property initializer (`@StateObject private var oura = OuraConnectModel(repo: repo)`)
/// either fails to compile (a property initializer can't reference another instance member) or, moved into
/// a custom `init()`, crashes at runtime ("No ObservableObject of type Repository found") because the
/// environment isn't resolved yet. This mirrors how the sibling `wearableCard`/`importWearable(url:)` on
/// `DataSourcesView` read `repo` lazily inside their action closures instead of at construction time.
@MainActor
final class OuraConnectModel: ObservableObject {
    @Published var busy = false
    @Published var statusText: String?
    @Published var isConnected = OuraTokenStore.isConnected

    /// True when the BYO-app credentials are present (else the lane is disabled with guidance).
    var isConfigured: Bool { OuraCredentials.fromBundle != nil }

    func connectAndImport(repo: Repository) {
        guard let creds = OuraCredentials.fromBundle else {
            statusText = "Add your Oura app's client_id/secret to OuraSecrets.xcconfig first."; return
        }
        setBusy(true); statusText = "Connecting to Oura…"
        Task {
            do {
                let provider = OuraOAuthProvider(credentials: creds)
                try await provider.authorize(presentationAnchor: ouraPresentationAnchor())
                isConnected = true
                guard let store = await repo.storeHandle() else { fail("No local store."); return }
                let client = OuraAPIClient(auth: provider, environment: .production)
                let coord = OuraSyncCoordinator(fetcher: client, store: store)
                let today = Self.dayFormatter.string(from: Date())
                statusText = "Importing your Oura history…"
                let s = try await coord.runFullImport(today: today) { [weak self] p in
                    Task { @MainActor in
                        if p.endpoint == "saving" { self?.statusText = "Saving to your database…" }
                        else { self?.statusText = "Importing \(p.endpoint)\(p.detail.map { " (\($0))" } ?? "")…" }
                    }
                }
                await repo.refresh()
                var line = "Imported \(s.days) days · \(s.sleeps) sleeps · \(s.workouts) workouts · \(s.hrSamples) HR samples"
                if !s.skippedEndpoints.isEmpty {
                    line += " · skipped: \(s.skippedEndpoints.joined(separator: ", ")) — tap Sync again to retry"
                }
                statusText = line
            } catch { fail((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
            setBusy(false)
        }
    }

    func disconnect(repo: Repository) {
        busy = true
        Task {
            OuraOAuthProvider(credentials: OuraCredentials.fromBundle ?? .init(clientId: "", clientSecret: "", redirectURI: "")).signOut()
            if let store = await repo.storeHandle() {
                do {
                    try await store.deleteAllData(deviceId: "oura-api")
                    try await store.deleteOuraRaw(deviceId: "oura-api")
                    // M-1: `deleteAllData` intentionally leaves the `pairedDevice` registry row intact
                    // (archiving/removing it is a separate op — DeviceRegistryStore.swift) so it doesn't
                    // just purge data, else a data-less "Oura (cloud)" card lingers in DevicesView. Archive
                    // it via the same off-actor raw-write pattern OuraSyncWriter.persist uses to register
                    // the row on connect (`registryWriter` is `nonisolated`; `DeviceRegistryStore` is a
                    // thin synchronous, Sendable wrapper — no separate actor hop needed).
                    try DeviceRegistryStore(dbQueue: store.registryWriter).archive("oura-api")
                    statusText = "Disconnected."
                } catch {
                    statusText = "Disconnected, but couldn't fully clear local Oura data: \(error.localizedDescription)"
                }
                await repo.refresh()
            } else {
                statusText = "Disconnected."
            }
            isConnected = false; busy = false
        }
    }

    private func fail(_ m: String) { statusText = m; setBusy(false) }

    /// Busy also pins the screen awake on iOS: the backfill is a foreground URLSession flow, and an
    /// auto-lock mid-import suspends the app and freezes the run with no error. Always reset on exit.
    private func setBusy(_ b: Bool) {
        busy = b
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = b
        #endif
    }
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"; return f
    }()
}
#endif // OURA_CLOUD_IMPORT
