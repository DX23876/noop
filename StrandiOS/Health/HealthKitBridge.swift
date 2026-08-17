#if os(iOS)
import Foundation
import HealthKit
import UIKit
import WhoopStore
import StrandAnalytics
import StrandImport

/// Two-way Apple Health bridge for the iOS app.
///
/// iOS has HealthKit (macOS does not), so the iOS target can do far more than parse a static export:
/// it reads the user's own Health data live and maps it onto the **same** `WhoopStore` rows the
/// macOS importer produces (under the `apple-health` source id), and it writes NOOP-computed metrics
/// back into Apple Health. Everything stays on-device and strictly opt-in.
@MainActor
final class HealthKitBridge: ObservableObject {

    enum AuthState: Equatable {
        case unknown, unavailable, denied, authorized
        /// The build can't talk to HealthKit at all: it was re-signed (free Apple ID / AltStore /
        /// Sideloadly) WITHOUT the `com.apple.developer.healthkit` entitlement, so the framework is
        /// present but the app can never read/write Health and can never appear under
        /// Settings › Health › Data Access & Devices. Distinct from `.denied` (entitled build, user
        /// said no) and `.unavailable` (no HealthKit hardware) so the UI can route to the honest
        /// file/Shortcuts import path instead of giving impossible Settings instructions (#348).
        case entitlementMissing
    }

    @Published private(set) var auth: AuthState = .unknown
    @Published private(set) var lastSync: Date?
    @Published private(set) var syncing = false
    /// The most recent failure surfaced by `sync` / `writeBack`. Cleared on a successful run. UI binds
    /// here so an Apple Health auth revoke, quota hit, or invalid sample is visible instead of silent.
    @Published private(set) var lastError: String?
    /// The newest realistic body-weight (kg) seen in the last successful sync, or nil when Health carried
    /// none. Published so the app can one-time seed an unset profile weight (see
    /// `ProfileStore.seedWeightFromHealthIfUnset`); the profile field itself stays the source of truth.
    @Published private(set) var latestImportedWeightKg: Double?
    /// A user-requested historical import, deliberately separate from normal foreground/background
    /// synchronisation. The app stores daily aggregates, never raw HealthKit samples.
    @Published private(set) var fullHistoryImporting = false
    @Published private(set) var fullHistoryProgress: Double?
    @Published private(set) var lastFullHistoryImport: Date?
    @Published private(set) var lastWritebackReport: HealthWritebackReport?
    @Published private(set) var heartRateExperiment: HealthHeartRateExperiment?
    private var fullHistoryTask: Task<Void, Never>?
    /// The RMSSD→SDNN repair walk. Explicit like `fullHistoryImporting` and for the same reason: it
    /// rewrites years of Apple Health samples, which must never happen as a launch side effect.
    @Published private(set) var hrvRepairRunning = false
    @Published private(set) var hrvRepairProgress: Double?
    private var hrvRepairTask: Task<Void, Never>?

    private let store = HKHealthStore()
    private let repo: Repository
    /// Source id imported HealthKit data lands under (matches `AppModel.appleDeviceId`).
    private let appleDeviceId: String
    /// NOOP's own strap-derived source id, read back when writing into Health.
    private let noopDeviceId: String
    /// NOOP's on-device COMPUTED daily scores (recovery/HRV/RHR/SpO₂/resp) live under the sibling
    /// `deviceId + "-noop"` id — mirrors `Repository.computedDeviceId` / `IntelligenceEngine.computedId`.
    /// `writeBack` must read this, not the raw import id: a Bluetooth-only WHOOP user has no imported
    /// `noopDeviceId` daily row, so those metrics exist ONLY here.
    private var computedDeviceId: String { noopDeviceId + "-noop" }

    private static let heartRateEncodingKey = "noop.health.hrSampleEncoding.v1"
    private static let heartRateExperimentKey = "noop.health.hrGraphExperiment.v1"
    private static let heartRateMigrationEndKey = "noop.health.hrEncodingMigrationEnd.v1"
    private static let heartRateMigrationFloorKey = "noop.health.hrEncodingMigrationFloor.v1"
    /// Stable across bundle ids, re-signing and reinstalls. `HKSource.default()` only identifies the
    /// currently-running build, so source-only filtering can re-import samples an older NOOP build
    /// wrote. Every new write carries this marker; the legacy `noop:` external UUID remains the
    /// fallback for samples produced before the marker existed.
    nonisolated private static let originMetadataKey = "com.noop.health.origin"
    nonisolated private static let originMetadataValue = "noop"
    /// The v1 destructive migration's marker. Still READ (it tells the UI whether this install already
    /// had its HRV history truncated), never written again.
    private static let hrvSdnnMigrationKey = "noop.health.hrvSdnnMigration.v1"
    /// The chunked repair's cursor, floor and completion marker — same shape as the HR-encoding
    /// migration's `heartRateMigrationEndKey`/`FloorKey`, so an interrupted walk resumes where it
    /// stopped instead of restarting.
    private static let hrvRepairEndKey = "noop.health.hrvSdnnRepair.v2.end"
    private static let hrvRepairFloorKey = "noop.health.hrvSdnnRepair.v2.floor"
    private static let hrvRepairDoneKey = "noop.health.hrvSdnnRepair.v2.done"
    /// Bigger than the HR migration's 14 days: one nightly value per day is a few hundred samples per
    /// chunk, not a per-second series. Starting value — tune it from a measured run.
    private static let hrvRepairChunkDays = 90

    /// Did the v1 migration truncate this install's Apple Health HRV series? Lets the UI say WHY the
    /// repair is offered instead of presenting an unexplained button.
    var hrvHistoryWasTruncated: Bool { UserDefaults.standard.bool(forKey: Self.hrvSdnnMigrationKey) }
    var hrvRepairCompleted: Bool { UserDefaults.standard.bool(forKey: Self.hrvRepairDoneKey) }

    var heartRateEncoding: HealthWriteback.HeartRateSampleEncoding {
        let raw = UserDefaults.standard.string(forKey: Self.heartRateEncodingKey)
        return HealthWriteback.HeartRateSampleEncoding(rawValue: raw ?? "") ?? .interval60Seconds
    }

    init(repo: Repository, appleDeviceId: String, noopDeviceId: String) {
        self.repo = repo
        self.appleDeviceId = appleDeviceId
        self.noopDeviceId = noopDeviceId
        // Order matters: a free-signed build with no HealthKit entitlement is dead in the water even
        // where the hardware supports Health, so surface that first. `.unavailable` (no HealthKit at
        // all, e.g. iPad without the framework) still wins where it applies because we only reach the
        // entitlement check when `isHealthDataAvailable()` is true.
        if !HKHealthStore.isHealthDataAvailable() {
            auth = .unavailable
        } else if !HealthKitBridge.hasHealthKitEntitlement {
            auth = .entitlementMissing
        }
        if let data = UserDefaults.standard.data(forKey: Self.heartRateExperimentKey),
           let saved = try? JSONDecoder().decode(HealthHeartRateExperiment.self, from: data) {
            heartRateExperiment = saved
        }
    }

    // MARK: - Types

    private var readTypes: Set<HKObjectType> {
        var s = Set<HKObjectType>()
        for id in HealthKitBridge.quantityReadIds { if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) } }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        s.insert(HKObjectType.workoutType())
        return s
    }

    /// Lookback (days) for the sparse body-composition reads (weight/body-fat/lean/BMI), decoupled from
    /// the 30-day daily-vitals window. ~10 years so a monthly-or-rarer weigh-in still lands, and the
    /// history matches the all-history file importer. Cheap: sparse discrete reads yield only real days.
    private static let bodyCompositionLookbackDays = 3650

    private var writeTypes: Set<HKSampleType> {
        var s = Set<HKSampleType>()
        for id in HealthKitBridge.quantityWriteIds + HealthKitBridge.highResQuantityWriteIds + HealthKitBridge.bodyMassWriteIds {
            if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        s.insert(HKObjectType.workoutType())
        return s
    }

    /// The write set as it existed before the high-res write-back (4 nightly vitals + sleep). A
    /// returning user granted THIS set; `refreshAuthIfPreviouslyGranted` must resume off it — checking
    /// the full `writeTypes` would leave every pre-existing grant stuck at `.unknown` after the update
    /// because the new types are still `.notDetermined`.
    private var legacyCoreWriteTypes: Set<HKSampleType> {
        var s = Set<HKSampleType>()
        for id in HealthKitBridge.quantityWriteIds { if let t = HKObjectType.quantityType(forIdentifier: id) { s.insert(t) } }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { s.insert(sleep) }
        return s
    }

    // Every id here ends up in the HealthKit permission dialog. Only request what `sync` actually
    // aggregates into `DayAgg`; adding read scopes the app never consumes makes the consent prompt
    // noisier and surfaces a privacy ask we don't honour.
    private static let quantityReadIds: [HKQuantityTypeIdentifier] = [
        .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .oxygenSaturation,
        .respiratoryRate, .bodyTemperature, .stepCount, .activeEnergyBurned,
        .basalEnergyBurned, .vo2Max,
        // Body composition — READ-ONLY (#20) for body-fat/lean-mass/BMI (no reliable NOOP-computed
        // source for them). Weight is the one exception: see `bodyMassWriteIds`/`writeWeight` below —
        // a later, user-requested reversal of this file's original "never write these back" stance,
        // scoped to weight only. All four still import under the apple-health source as before.
        .bodyMass, .bodyFatPercentage, .leanBodyMass, .bodyMassIndex,
        // Water — READ-ONLY (#949), so drinks logged in a dedicated hydration app (or by a smart bottle)
        // show up without being typed in twice. Lands in the hydration source rather than apple-health,
        // because the hydration screen is what consumes it. Never written back.
        .dietaryWater,
        // Caffeine — READ-ONLY (#949). Feeds the caffeine window's decay estimate, which already stores
        // time + optional mg per intake, so a Health sample maps onto it directly. Apple exposes this as
        // its own narrow type; Health Connect has no caffeine-only scope (caffeine is a field on
        // NutritionRecord, behind READ_NUTRITION — the whole food log), which is why Android is not
        // matched here. Never written back.
        .dietaryCaffeine
    ]
    private static let quantityWriteIds: [HKQuantityTypeIdentifier] = [
        .restingHeartRate, .heartRateVariabilitySDNN, .oxygenSaturation, .respiratoryRate
    ]
    // High-res write-back shares: the continuous 1-minute HR stream, and the energy/distance samples
    // attached to written workouts. Kept out of `quantityWriteIds` so `legacyCoreWriteTypes` (the
    // auth-resume set) stays exactly what pre-update users granted.
    private static let highResQuantityWriteIds: [HKQuantityTypeIdentifier] = [
        .heartRate, .activeEnergyBurned, .distanceWalkingRunning, .distanceCycling
    ]
    // Weight write-back: the user's own PROFILE edit, not strap-derived data — see `writeWeight` below.
    // Kept as its own array for the same reason as `highResQuantityWriteIds`: `legacyCoreWriteTypes`
    // must stay exactly what pre-update users granted, or a returning user regresses to unauthorized.
    private static let bodyMassWriteIds: [HKQuantityTypeIdentifier] = [.bodyMass]

    // MARK: - Authorization

    /// UserDefaults key holding the read set the user was last asked about.
    private static let readTypeSignatureKey = "noop.health.readTypeSignature"

    /// A stable fingerprint of the read scopes surfaced in the consent dialog — the sorted quantity read
    /// ids plus stable markers for the sleep + workout reads. When a later version ADDS a read-only type
    /// (body composition #20, water/caffeine #949), this string changes, and both top-up paths below use
    /// the mismatch to re-request once. Purely local (never crosses the `.noopbak` boundary), so the raw
    /// joined string is fine — no neutral hash needed.
    private static var readTypeSignature: String {
        (quantityReadIds.map(\.rawValue).sorted() + ["category:sleepAnalysis", "workout"])
            .joined(separator: ",")
    }

    private static func persistReadTypeSignature() {
        UserDefaults.standard.set(readTypeSignature, forKey: readTypeSignatureKey)
    }

    /// Re-request authorization when the app has STARTED reading a type it never used to (#949).
    ///
    /// HealthKit never reports read authorization, and `requestAuthorization` is only called from the
    /// connect button. So a read type added in an update stays `.notDetermined` for everyone who granted
    /// access before it existed, and its queries return empty forever — indistinguishable from "you have
    /// no water in Health", and silent. Water and caffeine would have done nothing at all for every
    /// existing user, which is most of them.
    ///
    /// Comparing a stored fingerprint of the read set catches that. Re-requesting is cheap and quiet:
    /// HealthKit presents the sheet ONLY for types that are still undetermined, so a user whose set is
    /// unchanged sees no UI, and a returning user is asked about exactly the new ones. The signature is
    /// stored only on success, so a failed request is retried rather than silently swallowed.
    private func requestNewReadTypesIfNeeded() async {
        // FOREGROUND only. `sync` is also driven by background observer wakes, and asking there would
        // spend the one request we get where no sheet can be presented — if that call reported success
        // without showing anything, the signature would be stored and the user never asked at all.
        guard auth == .authorized,
              UIApplication.shared.applicationState == .active,
              UserDefaults.standard.string(forKey: HealthKitBridge.readTypeSignatureKey)
                  != HealthKitBridge.readTypeSignature
        else { return }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            HealthKitBridge.persistReadTypeSignature()
        } catch {
            // Leave the signature unset so the next sync tries again. Not surfaced in `lastError`: the
            // user did not ask for this, and the rest of the sync is unaffected.
        }
    }

    /// Request read + write permission. HealthKit never reveals whether *read* was granted, so we
    /// treat a successful request as `.authorized` and let queries return empty if the user declined.
    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else { auth = .unavailable; return }
        // A free-signed build (no `com.apple.developer.healthkit` entitlement) can NEVER reach Health:
        // `requestAuthorization` either throws "Missing application-identifier"/"missing entitlement"
        // or returns without ever presenting the sheet and leaves every type `.notDetermined`. Either
        // way the honest answer is "this build can't use Apple Health directly", NOT "you denied it" —
        // so never fall through to `.denied` (which tells the user to fix it in Settings, where the app
        // can never appear). Detect via the embedded provisioning profile up front (#348).
        guard HealthKitBridge.hasHealthKitEntitlement else { auth = .entitlementMissing; return }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            // The entitlement is present (the guard above proved it via the embedded profile, or there's
            // no profile = App Store build), so a successful request means the bridge is usable. We do
            // NOT reclassify to `.entitlementMissing` off the post-request `.notDetermined` heuristic
            // here: on a genuinely-entitled build the user could grant only reads (writes stay
            // `.notDetermined`) or dismiss the share sheet, and that must stay `.authorized` with the
            // normal Settings guidance — never the file-import reroute. The provisioning-profile check is
            // the authoritative signal; the `.notDetermined` fallback only matters when that check can't
            // run, which on iOS means an App Store build that by definition has the entitlement.
            auth = .authorized
            // This grant covered the CURRENT read set, so record it — a later read-only addition changes
            // the signature and triggers exactly one top-up re-request; a fresh grant does not. See
            // `requestNewReadTypesIfNeeded` and `refreshAuthIfPreviouslyGranted`.
            HealthKitBridge.persistReadTypeSignature()
        } catch {
            // A thrown error here is on a build that carries the entitlement (guarded above), so it's a
            // genuine denial / request failure — keep the normal `.denied` "enable in Settings" path,
            // never the entitlement-missing reroute.
            auth = .denied
        }
        // First successful grant in this process: arm the live HealthKit stream so a watch-only user
        // gets continuous ingestion (new SDNN/RHR/sleep/etc. land within the hour) instead of only on
        // app foreground. Guarded inside enableLiveDelivery on auth == .authorized, so the .denied path
        // above is a no-op.
        enableLiveDelivery()
    }

    /// Resume a prior grant on launch without re-prompting. `auth` is a fresh `.unknown` every
    /// process (the bridge isn't persisted), so a user who already enabled Apple Health would
    /// otherwise have to re-tap "Enable" each session before the scenePhase sync runs. HealthKit
    /// never reveals *read* status, but *write*/share status is observable — if the user already
    /// authorized all of our write types, treat the bridge as `.authorized`. This only reads
    /// status, so no system permission sheet is shown.
    func refreshAuthIfPreviouslyGranted() {
        guard auth == .unknown, HKHealthStore.isHealthDataAvailable() else { return }
        let granted = legacyCoreWriteTypes.allSatisfy { store.authorizationStatus(for: $0) == .sharingAuthorized }
        if granted {
            auth = .authorized
            // A returning user who already granted access should get the live stream re-armed for this
            // process. enableLiveDelivery is idempotent (HealthKit dedups observers + background
            // delivery per type), so calling it here as well as after a fresh requestAuthorization is safe.
            enableLiveDelivery()
            // The high-res write-back added share types (HR stream, workouts, energy/distance) that a
            // pre-update grant has as `.notDetermined`. Re-request once: HealthKit shows a single sheet
            // listing ONLY the new types, and each write feature independently guards on its own type's
            // share status, so declining any checkbox just skips that feature.
            //
            // Read-only additions need the SAME top-up but can't be seen via `authorizationStatus`
            // (HealthKit never reveals read status), so `newTypesPending` — a WRITE-only probe — misses
            // them: body composition (#20) is read-only, so a returning user whose writes were already
            // determined was never asked for weight/BMI/lean/body-fat and HealthKit silently returned
            // nothing. Compare the persisted read-scope signature to detect a grown read set and re-request.
            //
            // Raw request, NOT requestAuthorization(): that method reclassifies a thrown error as
            // `.denied`, which must never demote a bridge that just resumed a valid legacy grant.
            //
            // FOREGROUND only, for the same reason `requestNewReadTypesIfNeeded` is: this resume is now
            // also called from the offload write-back (#1021), which runs in processes that were never
            // foregrounded. Asking there would spend the one request we get where no sheet can be
            // presented. The status read above is unaffected, so a legacy grant still resumes.
            let newTypesPending = writeTypes.contains { store.authorizationStatus(for: $0) == .notDetermined }
            let readGrew = UserDefaults.standard.string(forKey: HealthKitBridge.readTypeSignatureKey)
                != HealthKitBridge.readTypeSignature
            if (newTypesPending || readGrew), UIApplication.shared.applicationState == .active {
                Task {
                    do {
                        try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
                        // Only record the signature on success, so a dismissed/failed request retries next
                        // resume instead of being marked satisfied.
                        HealthKitBridge.persistReadTypeSignature()
                    } catch { /* keep the old signature; try again on the next resume */ }
                }
            }
        }
    }

    // MARK: - Live delivery (continuous ingestion)

    /// The scored read types we want a live observer + hourly background delivery on. This is the
    /// subset of `quantityReadIds` (plus sleep) that actually feeds Charge/Rest/Effort/Fitness Age, so
    /// a watch-only user's numbers refresh on their own rather than only when the app is foregrounded.
    /// We deliberately do NOT observe the body-composition reads (weight/BMI/etc.) — those don't move a
    /// score and a manual weigh-in shouldn't wake the app every hour.
    private static let liveQuantityIds: [HKQuantityTypeIdentifier] = [
        .heartRateVariabilitySDNN, .restingHeartRate, .activeEnergyBurned, .heartRate, .vo2Max
    ]

    /// Long-lived observer queries, retained so HealthKit doesn't tear them down. Keyed by the sample
    /// type's identifier so a second `enableLiveDelivery()` call replaces rather than duplicates.
    private var observerQueries: [String: HKObserverQuery] = [:]

    /// Register one `HKObserverQuery` per scored read type and turn on hourly background delivery, so
    /// new Apple Watch data is ingested continuously. Each observer's update handler runs an anchored
    /// delta sync of just the affected window and then calls HealthKit's completion handler (required —
    /// HealthKit stops delivering to an observer that never acknowledges). Idempotent and guarded behind
    /// `auth == .authorized`; safe to call from several entry points.
    func enableLiveDelivery() {
        guard auth == .authorized, HKHealthStore.isHealthDataAvailable() else { return }

        var types: [HKSampleType] = []
        for id in HealthKitBridge.liveQuantityIds {
            if let t = HKObjectType.quantityType(forIdentifier: id) { types.append(t) }
        }
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.append(sleep) }

        for type in types {
            let key = type.identifier
            // Tear down a prior observer for this type before re-registering, so a re-arm (e.g. a
            // returning user hitting both requestAuthorization and refreshAuthIfPreviouslyGranted) can
            // never leave two live observers fighting over the same completion handler.
            if let existing = observerQueries[key] {
                store.stop(existing)
                observerQueries[key] = nil
            }
            let observer = HKObserverQuery(sampleType: type, predicate: nil) { [weak self] _, completion, _ in
                // HealthKit invokes this on a background queue. Hop to the main actor (the bridge is
                // @MainActor and `sync` mutates published state), run the incremental catch-up, then
                // ALWAYS call completion so HealthKit keeps delivering. We don't tie completion to sync
                // success: a transient store error shouldn't make HealthKit think we never handled the
                // update and back off — the next foreground catch-up will reconcile.
                guard let self else { completion(); return }
                Task { @MainActor in
                    await self.syncFromObserver(type: type)
                    completion()
                }
            }
            store.execute(observer)
            observerQueries[key] = observer

            // Hourly is the finest cadence HealthKit honours for most types and is plenty for daily
            // aggregate scores. Failure here is non-fatal: the foreground catch-up still backfills.
            store.enableBackgroundDelivery(for: type, frequency: .hourly) { _, _ in }
        }
    }

    /// Foreground catch-up. Call on app-active so anything background delivery missed (the system can
    /// throttle or skip wakes) is backfilled. A short window is enough because live delivery keeps the
    /// recent days current; 7 covers a weekend of missed wakes. Exposed for the existing scenePhase
    /// hook in `StrandiOSApp` to call — no other file is edited.
    func foregroundCatchUp() async {
        await sync(days: 7)
    }

    /// Drive an incremental sync off an observer wake. We use an `HKAnchoredObjectQuery` per type to
    /// learn the span of days touched since we last looked (persisting the anchor so the same samples
    /// aren't walked twice and nothing between wakes is missed), then re-aggregate just that day window
    /// via the existing `sync(days:)` path. Re-aggregating the window (rather than the deltas alone)
    /// keeps every per-day average correct and idempotent — `sync` upserts are keyed by day.
    private func syncFromObserver(type: HKSampleType) async {
        guard auth == .authorized else { return }
        let touched = await fetchTouchedDayWindow(type: type)
        // No new samples since the last anchor (a spurious wake): nothing to do.
        guard let touched else { return }
        let cal = Calendar.current
        let daysBack = cal.dateComponents([.day], from: cal.startOfDay(for: touched),
                                          to: cal.startOfDay(for: Date())).day ?? 0
        // Clamp to a sane window: at least today, and never re-walk more than a month from one wake.
        let window = max(1, min(31, daysBack + 1))
        await sync(days: window)
    }

    /// Advance this type's stored anchor over any new samples and return the OLDEST sample date seen,
    /// or nil when there were no new samples. Anchors are persisted in UserDefaults per type so live
    /// deltas are neither re-ingested nor missed across launches. We don't consume the samples here —
    /// `sync(days:)` re-reads the aggregate for the affected window — the anchor's only job is to tell
    /// us how far back the change reached.
    private func fetchTouchedDayWindow(type: HKSampleType) async -> Date? {
        let key = HealthKitBridge.anchorDefaultsKey(for: type)
        let priorAnchor: HKQueryAnchor? = {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
        }()

        return await withCheckedContinuation { (cont: CheckedContinuation<Date?, Never>) in
            let q = HKAnchoredObjectQuery(
                type: type, predicate: Self.notNoopAuthored,
                anchor: priorAnchor, limit: HKObjectQueryNoLimit
            ) { _, samples, _, newAnchor, _ in
                // Persist the advanced anchor so the next wake only sees genuinely-new samples. Skip the
                // write on a query error (newAnchor nil) so we don't blow away a good cursor.
                if let newAnchor,
                   let data = try? NSKeyedArchiver.archivedData(withRootObject: newAnchor, requiringSecureCoding: true) {
                    UserDefaults.standard.set(data, forKey: key)
                }
                // The query predicate excludes current source and the stable origin marker. HealthKit
                // does not support `.beginsWith` for HKExternalUUID in object-query predicates (it
                // raises an Objective-C exception rather than returning an error), so legacy `noop:`
                // external ids are deliberately excluded only by this client-side check.
                let oldest = (samples ?? [])
                    .filter { !Self.isNoopAuthored($0) }
                    .map { $0.startDate }
                    .min()
                cont.resume(returning: oldest)
            }
            store.execute(q)
        }
    }

    /// UserDefaults key for a type's persisted HealthKit anchor. Namespaced so it can't collide with
    /// other app defaults, and keyed by the stable HK identifier so it survives across launches.
    private static func anchorDefaultsKey(for type: HKSampleType) -> String {
        "hkAnchor.v1.\(type.identifier)"
    }

    // MARK: - Read → store

    /// Pull the last `days` of Apple Health into the on-device store under the `apple-health` source,
    /// then write NOOP's own computed metrics back into Health. Safe to call repeatedly (idempotent
    /// upserts keyed by day).
    func sync(days: Int = 30, importingFullHistory: Bool = false) async {
        guard auth == .authorized, !syncing else { return }
        syncing = true
        if importingFullHistory {
            fullHistoryImporting = true
            fullHistoryProgress = 0
        }
        defer {
            syncing = false
            if importingFullHistory {
                fullHistoryImporting = false
                fullHistoryProgress = nil
            }
        }
        // Before reading: pick up any read type this version added that the user was never asked about
        // (#949). No-op once the stored signature matches, which is every sync after the first.
        await requestNewReadTypesIfNeeded()
        guard let store = await repo.storeHandle() else { return }

        func progress(_ value: Double) {
            guard importingFullHistory else { return }
            fullHistoryProgress = min(1, max(0, value))
        }

        let cal = Calendar.current
        let end = Date()
        guard let start = cal.date(byAdding: .day, value: -days, to: cal.startOfDay(for: end)) else { return }
        // Body composition (weight/body-fat/lean/BMI) is SPARSE and slow-moving — a weigh-in can be weeks
        // or months apart — so the 30-day vitals window frequently holds no sample at all and the metric
        // silently never imports (the daily HR/steps/sleep reads are unaffected). Give these four types a
        // long lookback so the latest value AND the full history land, matching the all-history file
        // importer. Cheap despite the span: they're sparse discrete reads, so enumeration only yields the
        // handful of days that actually carry a sample.
        let bodyStart = cal.date(byAdding: .day, value: -HealthKitBridge.bodyCompositionLookbackDays,
                                 to: cal.startOfDay(for: end)) ?? start

        var byDay: [String: DayAgg] = [:]
        func agg(_ day: String) -> DayAgg { byDay[day] ?? DayAgg() }

        // Quantity aggregates per day.
        await collect(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.restingHr = v; byDay[day] = a
        }
        await collect(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.avgHr = v; byDay[day] = a
        }
        await collect(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteMax) { day, v in
            var a = agg(day); a.maxHr = v; byDay[day] = a
        }
        await collect(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.hrv = v; byDay[day] = a
        }
        await collect(.oxygenSaturation, unit: .percent(), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.spo2 = v * 100; byDay[day] = a   // 0…1 → percent
        }
        await collect(.respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.respRate = v; byDay[day] = a
        }
        await collect(.stepCount, unit: .count(), start: start, end: end, op: .cumulativeSum) { day, v in
            var a = agg(day); a.steps = v; byDay[day] = a
        }
        await collect(.activeEnergyBurned, unit: .kilocalorie(), start: start, end: end, op: .cumulativeSum) { day, v in
            var a = agg(day); a.activeKcal = v; byDay[day] = a
        }
        await collect(.basalEnergyBurned, unit: .kilocalorie(), start: start, end: end, op: .cumulativeSum) { day, v in
            var a = agg(day); a.basalKcal = v; byDay[day] = a
        }
        await collect(.vo2Max, unit: HKUnit(from: "ml/kg*min"), start: start, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.vo2max = v; byDay[day] = a
        }
        progress(0.40)
        guard !Task.isCancelled else { return }

        // Body composition — READ-ONLY import under the apple-health source (#20). Weight, lean mass
        // and BMI are point-in-time readings, so take the latest-of-day; body-fat reads fine as a
        // daily average. Body-fat HealthKit gives a 0…1 fraction, scaled to percent like spo2 above.
        // These use `bodyStart` (long lookback), NOT the 30-day vitals `start`, because they're sparse.
        await collect(.bodyMass, unit: .gramUnit(with: .kilo), start: bodyStart, end: end, op: .discreteMostRecent) { day, v in
            var a = agg(day); a.weightKg = v; byDay[day] = a
        }
        await collect(.bodyFatPercentage, unit: .percent(), start: bodyStart, end: end, op: .discreteAverage) { day, v in
            var a = agg(day); a.bodyFatPct = v * 100; byDay[day] = a   // 0…1 → percent
        }
        await collect(.leanBodyMass, unit: .gramUnit(with: .kilo), start: bodyStart, end: end, op: .discreteMostRecent) { day, v in
            var a = agg(day); a.leanMassKg = v; byDay[day] = a
        }
        await collect(.bodyMassIndex, unit: .count(), start: bodyStart, end: end, op: .discreteMostRecent) { day, v in
            var a = agg(day); a.bmi = v; byDay[day] = a
        }
        progress(0.60)
        guard !Task.isCancelled else { return }

        // Water logged in other apps (#949). A cumulative day SUM, like steps — HealthKit re-adds every
        // sample in the day on each sync, so the figure this produces is a full replacement rather than a
        // delta, which is exactly what `setImportedHydration` wants. `notNoopAuthored` (applied inside
        // `collect`) keeps NOOP's own drinks out, so a tap in NOOP can never come back as an import.
        //
        // The result is KEPT here, unlike every aggregate above: the write below replaces the stored
        // figure, so a failed query must not be mistaken for an authoritative zero and wipe the window.
        let waterReadOk = await collect(.dietaryWater, unit: .literUnit(with: .milli),
                                        start: start, end: end, op: .cumulativeSum) { day, v in
            var a = agg(day); a.waterMl = v; byDay[day] = a
        }

        // Sleep minutes per day (asleep stages summed; attributed to wake day).
        await collectSleep(start: start, end: end) { day, asleepMin, deepMin, remMin, coreMin in
            var a = agg(day)
            a.asleepMin = asleepMin; a.deepMin = deepMin; a.remMin = remMin; a.coreMin = coreMin
            byDay[day] = a
        }
        progress(0.75)
        guard !Task.isCancelled else { return }

        // Build + upsert the store rows under the apple-health source.
        let appleRows = byDay.map { (day, a) in
            AppleDaily(day: day, steps: a.steps.map { Int($0) },
                       activeKcal: a.activeKcal, basalKcal: a.basalKcal, vo2max: a.vo2max,
                       avgHr: a.avgHr.map { Int($0.rounded()) }, maxHr: a.maxHr.map { Int($0.rounded()) },
                       walkingHr: nil, weightKg: a.weightKg)
        }
        let dmRows = byDay.map { (day, a) in
            DailyMetric(day: day, totalSleepMin: a.asleepMin, efficiency: nil,
                        deepMin: a.deepMin, remMin: a.remMin, lightMin: a.coreMin, disturbances: nil,
                        restingHr: a.restingHr.map { Int($0.rounded()) }, avgHrv: a.hrv,
                        recovery: nil, strain: nil, exerciseCount: nil,
                        spo2Pct: a.spo2, skinTempDevC: nil, respRateBpm: a.respRate,
                        avgSdnn: a.hrv)   // Apple's HRV IS SDNN — mirror it into the SDNN field too
        }
        // Flatten to the generic metricSeries the shared Apple Health screen, the Today apple-health
        // sparklines, and the Metric Explorer read from — repo.series(key:source:"apple-health")
        // queries ONLY metricSeries, so without this every tile/chart renders "—" after a successful
        // sync. Reuse the importer's canonical key mapping so the keys match the macOS path exactly.
        // Body composition (weight/body_fat/lean_mass/bmi) now reads live on iOS (#20) and flows
        // through the same metricPoints keys as the file importer. iOS still doesn't collect
        // awake/in-bed minutes, so those stay nil and emit no points — correct.
        let aggregates = byDay.map { (day, a) in
            AppleDailyAggregate(
                day: day,
                restingHr: a.restingHr,
                hrvSDNN: a.hrv,
                spo2Pct: a.spo2,
                respRate: a.respRate,
                avgHr: a.avgHr,
                maxHr: a.maxHr,
                steps: a.steps,
                activeKcal: a.activeKcal,
                basalKcal: a.basalKcal,
                vo2max: a.vo2max,
                weightKg: a.weightKg,
                bodyFatPct: a.bodyFatPct,
                leanMassKg: a.leanMassKg,
                bmi: a.bmi,
                asleepMin: a.asleepMin,
                deepMin: a.deepMin,
                remMin: a.remMin,
                coreMin: a.coreMin
            )
        }
        let points = AppleHealthAggregator.metricPoints(aggregates)
            .map { MetricPoint(day: $0.day, key: $0.key, value: $0.value) }

        // Workouts the user logged in Apple Health (Apple Watch rings, gym apps, etc.). macOS already
        // imports these from a static Health export and Android reads them from Health Connect; iOS now
        // reads them live on-device too, so the platforms reach parity. ON-DEVICE ONLY: this is a plain
        // HealthKit read of workouts NOOP did NOT author, never any cloud/3rd-party API. (#835)
        let workoutRows = await collectWorkouts(start: start, end: end)
        progress(0.85)
        guard !Task.isCancelled else { return }

        // Persist all the apple-health rows AND write back, advancing lastSync only when the WHOLE
        // round-trip succeeds. The three read-side upserts used to be swallowed by `try?`, so a failed
        // import (e.g. a disk-full GRDB write) dropped rows yet still cleared lastError and advanced
        // lastSync — a false "success", and the next delta sync skipped the window. (Reimplemented
        // from @vulnix0x4's PR #375.)
        do {
            try await store.upsertAppleDaily(appleRows, deviceId: appleDeviceId)
            try await store.upsertDailyMetrics(dmRows, deviceId: appleDeviceId)
            try await store.upsertMetricSeries(points, deviceId: appleDeviceId)
            if !workoutRows.isEmpty { try await store.upsertWorkouts(workoutRows, deviceId: appleDeviceId) }
            // Imported water (#949) goes to the hydration source, not apple-health, because the hydration
            // screen is what reads it. Every day in the window is written — including the ones with no
            // water at all, as 0 — so deleting a drink in the source app takes it away here on the next
            // sync instead of stranding the old figure. `byDay` only holds days that had SOME metric, so
            // the zero-fill has to come from the date range rather than from its keys.
            //
            // Gated on the hydration toggle, which is opt-in and default OFF: an import must not quietly
            // populate a feature the user has turned off, and skipping it avoids writing a window of rows
            // nothing will read.
            if waterReadOk, UserDefaults.standard.bool(forKey: HydrationStore.enabledKey) {
                var waterByDay: [String: Double] = [:]
                var cursor = cal.startOfDay(for: start)
                while cursor <= end {
                    waterByDay[HealthKitBridge.dayString(cursor)] = 0
                    guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
                    cursor = next
                }
                for (day, a) in byDay { if let ml = a.waterMl { waterByDay[day] = ml } }
                await repo.setImportedHydration(waterByDay)
            }
            // Imported caffeine (#949) — only the last `CaffeineLogStore.retentionHours`, because the
            // store prunes past that on load and the decay estimate is long dead by then. Reading the
            // full 30-day sync window would hand over hundreds of samples for them all to be dropped.
            //
            // The caffeine card is manual-first and shows nothing until something is logged, so unlike
            // hydration there is no separate opt-in toggle to gate on: an empty Health cupboard still
            // leaves the card exactly as quiet as it is today.
            if let caffeineStart = cal.date(byAdding: .hour,
                                            value: -Int(CaffeineLogStore.retentionHours), to: end) {
                // nil means the READ failed; only an actual empty result is allowed to clear the set.
                if let imported = await collectCaffeine(start: caffeineStart, end: end) {
                    CaffeineLogStore.shared.replaceImported(imported)
                }
            }
            try await writeBack(whoopStore: store)
            lastSync = Date()
            if importingFullHistory { lastFullHistoryImport = lastSync }
            lastError = nil
            // Newest realistic weigh-in from this sync, for the one-time profile seed. Latest = the
            // highest day key carrying a >10 kg reading; nil when Health held none.
            latestImportedWeightKg = appleRows
                .filter { ($0.weightKg ?? 0) > 10 }
                .max { $0.day < $1.day }?
                .weightKg
            progress(1)
        } catch {
            lastError = String(localized: "Apple Health sync failed: \(error.localizedDescription)")
        }
    }

    /// Build the local Apple-Health history used by long-range Coach questions. This is an explicit
    /// action because a multi-year HealthKit query can take noticeable time; subsequent normal syncs
    /// remain incremental/short-window. Ten years matches the existing sparse body-composition lookback.
    func startFullHistoryImport() {
        guard auth == .authorized, !syncing, !fullHistoryImporting else { return }
        // Publish synchronously so the view cannot mistake the scheduling gap for a completed import.
        fullHistoryImporting = true
        fullHistoryProgress = 0
        fullHistoryTask = Task { [weak self] in
            guard let self else { return }
            await self.sync(days: Self.bodyCompositionLookbackDays, importingFullHistory: true)
            self.fullHistoryTask = nil
        }
    }

    /// HealthKit queries are cooperative: the current aggregate query may finish, but no later category
    /// or database write is started after cancellation. A later tap safely starts the full, idempotent
    /// import again; day-keyed upserts prevent duplicates.
    func cancelFullHistoryImport() {
        fullHistoryTask?.cancel()
        fullHistoryTask = nil
    }

    /// Write-back only, for when fresh strap data lands (#1021).
    ///
    /// `sync` is the two-way pass and runs on foreground entry, which is the wrong moment: the same
    /// scenePhase block kicks the strap offload, so the write raced the data it was meant to publish and
    /// last night's sleep only reached Health on the NEXT app open. `AppModel.refreshAfterCompletedBackfill`
    /// is the real "new data landed" signal - the same one #980 already publishes the widget from - and it
    /// also fires for a backfill that completes while the app is backgrounded.
    ///
    /// Deliberately not `sync()`: that would re-read 30 days out of Health and re-run the hydration /
    /// caffeine imports on every offload, to write the same rows. The Android twin is the same shape -
    /// `WhoopBleClient` calls `HealthConnectWriter.write` after the backfill, not a full re-sync.
    ///
    /// `lastSync` is left alone: it marks the last full two-way pass, and a write-only run advancing it
    /// would misreport when NOOP last READ from Health.
    ///
    /// Shares the `syncing` flag with `sync()` on purpose: two write-backs must never interleave, because
    /// the vitals dedup deletes our prior samples for a key before saving the fresh batch. The cost is
    /// that a foreground `sync()` arriving during a background write skips that one read pass and picks
    /// up on the next open - a few seconds' window, and nothing is lost.
    func writeBackAfterNewData() async {
        // A backfill routinely completes in a process that was never foregrounded (a background offload,
        // or a BLE relaunch) - the case this exists for. `auth` is still `.unknown` there, because the
        // only resume runs on scenePhase == .active, so without this the guard below would silently drop
        // exactly the writes this is meant to deliver. Idempotent, and never prompts: it reads share
        // status, and its re-request for new types is foreground-gated.
        refreshAuthIfPreviouslyGranted()
        guard auth == .authorized, !syncing else { return }
        syncing = true
        defer { syncing = false }
        guard let store = await repo.storeHandle() else { return }
        do {
            try await writeBack(whoopStore: store)
            lastError = nil
        } catch {
            lastError = String(localized: "Apple Health sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Write back (NOOP → Health)

    /// Write NOOP's strap-derived data into Apple Health: sleep sessions with full stage segments,
    /// the continuous 1-minute heart-rate stream, strap/manual workouts, and the nightly vitals
    /// (resting HR, HRV, SpO₂, respiratory rate) stamped at that day's wake time.
    ///
    /// Each feature saves independently and guards on ITS OWN type's share status, so one declined
    /// Health checkbox (or a save error) skips that feature without sinking the rest; the first error
    /// is rethrown at the end so `sync` still surfaces it in `lastError` without advancing `lastSync`.
    ///
    /// Dedup model (vitals): each emitted sample carries a deterministic `HKMetadataKeyExternalUUID`
    /// from `noopDeviceId + metric + day`. Before saving, we delete any of *our* prior samples that
    /// carry the same key (scoped to `HKSource.default()` so we never touch another app's data) and
    /// then save the fresh batch. HealthKit assigns a new UUID per save, so the previous strategy
    /// (no metadata, no delete) flooded Health with duplicates on every `sync()`.
    ///
    /// Throws on save failure so the caller can decide whether to advance `lastSync`.
    private func writeBack(whoopStore: WhoopStore, days: Int = 14) async throws {
        guard auth == .authorized else { return }
        let now = Date()
        guard let fromDate = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return }
        let fromTs = Int(fromDate.timeIntervalSince1970)
        let nowTs = Int(now.timeIntervalSince1970)

        // Sleep sessions drive both the sleep write and the vitals' wake-time stamps: computed
        // sessions (deviceId + "-noop") first, imported rows override on startTs collision — the
        // same source precedence as the dailies union below and IntelligenceEngine's sleep reads.
        let computedSleeps = (try? await whoopStore.sleepSessions(deviceId: computedDeviceId, from: fromTs, to: nowTs, limit: 200)) ?? []
        let importedSleeps = (try? await whoopStore.sleepSessions(deviceId: noopDeviceId, from: fromTs, to: nowTs, limit: 200)) ?? []
        var sleepsByStart: [Int: CachedSleepSession] = [:]
        for s in computedSleeps { sleepsByStart[s.startTs] = s }
        for s in importedSleeps { sleepsByStart[s.startTs] = s }
        let sessions = sleepsByStart.keys.sorted().map { sleepsByStart[$0]! }

        var firstError: Error?
        var reportEntries: [HealthWritebackReport.Entry] = []
        func attempt(_ id: String, types: [HKObjectType], _ op: () async throws -> Int) async {
            let authorized = types.filter { store.authorizationStatus(for: $0) == .sharingAuthorized }.count
            do {
                let count = try await op()
                reportEntries.append(.init(id: id, count: count,
                                           authorizedTypes: authorized, totalTypes: types.count,
                                           detail: count == 0
                                            ? String(localized: "No data")
                                            : String(localized: "Saved")))
            } catch {
                reportEntries.append(.init(id: id, count: 0,
                                           authorizedTypes: authorized, totalTypes: types.count,
                                           detail: error.localizedDescription))
                if firstError == nil { firstError = error }
            }
        }
        let vitalTypes: [HKObjectType] = [
            HKQuantityType.quantityType(forIdentifier: .restingHeartRate),
            HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
            HKQuantityType.quantityType(forIdentifier: .oxygenSaturation),
            HKQuantityType.quantityType(forIdentifier: .respiratoryRate),
        ].compactMap { $0 }
        await attempt("Vitals", types: vitalTypes) {
            try await writeVitals(whoopStore: whoopStore, days: days, sessions: sessions)
        }
        await attempt("Sleep", types: [HKObjectType.categoryType(forIdentifier: .sleepAnalysis)].compactMap { $0 }) {
            try await writeSleep(sessions: sessions)
        }
        await attempt("Heart rate", types: [HKQuantityType.quantityType(forIdentifier: .heartRate)].compactMap { $0 }) {
            let current = try await writeHeartRate(whoopStore: whoopStore, fromTs: fromTs, nowTs: nowTs)
            let migrated = try await continueHeartRateEncodingMigration(whoopStore: whoopStore)
            return current + migrated
        }
        await attempt("Workouts", types: [.workoutType()]) {
            try await writeWorkouts(whoopStore: whoopStore, fromTs: fromTs, toTs: nowTs)
        }
        lastWritebackReport = .init(completedAt: Date(), entries: reportEntries)
        if let firstError { throw firstError }
    }

    /// The nightly vitals write (the original write-back), now stamped at the day's wake time when
    /// that day has a sleep session — a real timestamp inside the night the value describes, instead
    /// of a fabricated noon. Keys are unchanged, so re-stamped samples replace their noon ancestors.
    private func writeVitals(whoopStore: WhoopStore, days: Int,
                             sessions: [CachedSleepSession]) async throws -> Int {
        let cal = Calendar.current
        let to = HealthKitBridge.dayString(Date())
        guard let fromDate = cal.date(byAdding: .day, value: -days, to: Date()) else { return 0 }
        let from = HealthKitBridge.dayString(fromDate)

        // day (of wake) → wake instant. Ascending session order means the latest wake of a day wins,
        // matching collectSleep's end-date day attribution.
        var wakeByDay: [String: Date] = [:]
        for s in sessions where s.endTs > s.effectiveStartTs {
            let wake = Date(timeIntervalSince1970: TimeInterval(s.endTs))
            wakeByDay[HealthKitBridge.dayString(wake)] = wake
        }
        // Read NOOP's COMPUTED dailies (deviceId + "-noop"), which is the only place a strap-only
        // user's recovery/HRV/RHR/SpO₂/resp lives, then union with any imported `noopDeviceId` rows so
        // a user who ALSO imported a WHOOP export still gets the imported values. Imported overrides
        // computed per day, matching the dashboard's source precedence.
        let computed = (try? await whoopStore.dailyMetrics(deviceId: computedDeviceId, from: from, to: to)) ?? []
        let imported = (try? await whoopStore.dailyMetrics(deviceId: noopDeviceId, from: from, to: to)) ?? []
        var byDay: [String: DailyMetric] = [:]
        for r in computed { byDay[r.day] = r }   // computed first
        for r in imported { byDay[r.day] = r }   // imported overrides
        let rows = byDay.keys.sorted().map { byDay[$0]! }

        // HealthKit's HRV identifier is SDNN, while DailyMetric.avgHrv is NOOP's RMSSD. The SDNN this
        // exports is `DailyMetric.avgSdnn`, computed and stored by the analytics pass; nothing is
        // recomputed here. This used to derive its own whole-night SDNN from the longest sleep block,
        // which was the right REFUSAL (untrustworthy R-R spread is rejected) applied to the wrong
        // QUANTITY — see the export site below.
        struct Candidate { let type: HKQuantityType; let key: String; let sample: HKQuantitySample }
        var candidates: [Candidate] = []
        func add(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double, _ day: String,
                 _ at: Date, algorithmVersion: Int? = nil) {
            guard let type = HKQuantityType.quantityType(forIdentifier: id),
                  store.authorizationStatus(for: type) == .sharingAuthorized else { return }
            let key = HealthWriteback.vitalsExternalKey(noopDeviceId: noopDeviceId,
                                                       identifier: id.rawValue, day: day)
            var metadata: [String: Any] = [HKMetadataKeyExternalUUID: key,
                                           Self.originMetadataKey: Self.originMetadataValue]
            if let algorithmVersion {
                metadata[HKMetadataKeyAlgorithmVersion] = NSNumber(value: algorithmVersion)
            }
            let sample = HKQuantitySample(
                type: type,
                quantity: .init(unit: unit, doubleValue: value),
                start: at, end: at,
                metadata: metadata
            )
            candidates.append(Candidate(type: type, key: key, sample: sample))
        }

        for row in rows {
            guard let date = HealthKitBridge.date(from: row.day) else { continue }
            let noon = cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
            let at = wakeByDay[row.day] ?? noon
            if let rhr = row.restingHr {
                add(.restingHeartRate, HKUnit.count().unitDivided(by: .minute()), Double(rhr), row.day, at)
            }
            // Export the persisted 5-min SDNN INDEX (`avgSdnn`), never `avgHrv`: HealthKit's single HRV
            // field IS SDNN, and NOOP's `avgHrv` is RMSSD, so writing that here mislabels it. The index
            // rather than a whole-night SD because Apple's own SDNN samples are short-window — see the
            // derivation in `AnalyticsEngine`, where a whole-night SD is shown to read 2-3× high. A row
            // without one exports no HRV at all; a wrong number in the user's Health history is worse
            // than a gap. (This replaces an export-time whole-night recomputation that had the same
            // mislabelling problem upstream ryanbr/noop fixed in #1334.)
            if let sdnn = row.avgSdnn {
                add(.heartRateVariabilitySDNN, .secondUnit(with: .milli), sdnn, row.day, at,
                    algorithmVersion: 1)
            }
            if let spo2 = row.spo2Pct {
                add(.oxygenSaturation, .percent(), spo2 / 100, row.day, at)
            }
            if let rr = row.respRateBpm {
                add(.respiratoryRate, HKUnit.count().unitDivided(by: .minute()), rr, row.day, at)
            }
        }
        // The one-time RMSSD→SDNN semantic migration used to live HERE, and deleted every NOOP-authored
        // sample of this type across ALL dates before writing this pass's candidates. That is a
        // data-loss shape: the delete was unbounded while `rows` above spans only `days` (14 by
        // default, and every caller uses the default), so a multi-year Apple Health HRV series
        // collapsed to the last two weeks on the first launch after the upgrade. It also blocked the
        // launch path, because this `await` runs inside the scenePhase == .active task.
        //
        // It now lives in `replaceOwnHrvWindow` below, which deletes exactly the days it rewrites in
        // that chunk, and is driven by an explicit user action rather than a launch side effect.
        // Nothing about the regular write-back changed: the dedup below is still key-scoped, so this
        // pass keeps overwriting its own last-14-days samples exactly as before.

        guard !candidates.isEmpty else { return 0 }

        // Delete any of OUR prior samples that carry the same metadata keys, then write the fresh
        // batch. Scoped to HKSource.default() so we never touch a sample written by another app
        // that happens to use the same external UUID. Delete failures are non-fatal (e.g., nothing
        // to delete on first run) — only the save throws.
        let bySource = HKQuery.predicateForObjects(from: HKSource.default())
        let grouped = Dictionary(grouping: candidates, by: { $0.type })
        for (type, items) in grouped {
            let keys = Array(Set(items.map { $0.key }))
            let byKey = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID,
                                                    allowedValues: keys)
            let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [bySource, byKey])
            _ = try? await self.store.deleteObjects(of: type, predicate: pred)
        }
        try await self.store.save(candidates.map { $0.sample })
        return candidates.count
    }

    /// Writes the user's current PROFILE weight into Apple Health — the one write-back whose source is a
    /// user edit, not strap-derived `WhoopStore` data, so it is deliberately NOT called from the periodic
    /// `writeBack(whoopStore:days:)` sync loop like `writeVitals`/`writeSleep`/`writeHeartRate`/
    /// `writeWorkouts` above. Triggered from `ProfileStore.weightKg` changing, wired in `StrandiOSApp.swift`.
    /// Same dedup model as `writeVitals`: one sample per day, keyed `noop:<noopDeviceId>:bodyMass:<day>`,
    /// delete-then-save so repeated edits the same day replace rather than duplicate.
    func writeWeight(kg: Double, day: String = HealthKitBridge.dayString(Date())) async throws {
        guard kg > 10,
              let type = HKQuantityType.quantityType(forIdentifier: .bodyMass),
              store.authorizationStatus(for: type) == .sharingAuthorized,
              let date = HealthKitBridge.date(from: day) else { return }
        let cal = Calendar.current
        let at = cal.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? date
        let key = "noop:\(noopDeviceId):bodyMass:\(day)"
        let sample = HKQuantitySample(
            type: type,
            quantity: .init(unit: .gramUnit(with: .kilo), doubleValue: kg),
            start: at, end: at,
            metadata: [HKMetadataKeyExternalUUID: key,
                       Self.originMetadataKey: Self.originMetadataValue]
        )
        let bySource = HKQuery.predicateForObjects(from: HKSource.default())
        let byKey = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [key])
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [bySource, byKey])
        _ = try? await store.deleteObjects(of: type, predicate: pred)
        try await store.save(sample)
    }

    /// Write each BRIDGED NIGHT (#364) as one `.inBed` sample plus one category sample per stage
    /// segment (`deep → .asleepDeep`, `rem → .asleepREM`, `light → .asleepCore`, `wake → .awake`) —
    /// the same shape Oura and Apple Watch write, so Health renders the full hypnogram. A night the
    /// detector split on a brief mid-night wake exports as ONE entry whose gap is an explicit
    /// `.awake` segment (grouped by `SleepStageTotals.bridgedNightGroups`, the SAME bridge the daily
    /// totals score with, #561); naps never bridge and stay their own entries. Fragments whose
    /// `stagesJSON` carries no timing (the legacy aggregate-minutes shapes) get one honest
    /// `.asleepUnspecified` block instead of fabricated stage placement.
    ///
    /// Dedup: every sample of a night carries `HKMetadataKeyExternalUUID =
    /// noop:<deviceId>:sleep:<startTs>` keyed by the group's EARLIEST fragment's immutable detected
    /// onset (a user edit moves the span, never the key). The delete predicate carries EVERY
    /// fragment's key, so a night previously written as two entries fully clears when it becomes
    /// one; delete-then-write scoped to our own `HKSource`, like the vitals.
    private func writeSleep(sessions: [CachedSleepSession]) async throws -> Int {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis),
              store.authorizationStatus(for: type) == .sharingAuthorized else { return 0 }
        let blocks = sessions.map { SleepStageTotals.NightBlock(start: $0.effectiveStartTs, end: $0.endTs) }
        let groups = SleepStageTotals.bridgedNightGroups(blocks, offsetSec: TimeZone.current.secondsFromGMT())
            .map { g in
                g.indices.map { i -> HealthWriteback.SleepFragment in
                    let s = sessions[i]
                    return .init(startTs: s.startTs, effectiveStartTs: s.effectiveStartTs,
                                 endTs: s.endTs, stagesJSON: s.stagesJSON)
                }
            }
        var samples: [HKCategorySample] = []
        var keys: [String] = []
        for entry in HealthWriteback.mergedSleepPlan(groups: groups) {
            let key = "noop:\(noopDeviceId):sleep:\(entry.keyStartTs)"
            let meta = [HKMetadataKeyExternalUUID: key,
                        Self.originMetadataKey: Self.originMetadataValue]
            keys.append(contentsOf: entry.allKeyStartTs.map { "noop:\(noopDeviceId):sleep:\($0)" })
            samples.append(HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                                            start: Date(timeIntervalSince1970: TimeInterval(entry.spanStart)),
                                            end: Date(timeIntervalSince1970: TimeInterval(entry.spanEnd)),
                                            metadata: meta))
            for seg in entry.intervals {
                let value: HKCategoryValueSleepAnalysis
                switch seg.kind {
                case .awake:       value = .awake
                case .light:       value = .asleepCore
                case .deep:        value = .asleepDeep
                case .rem:         value = .asleepREM
                case .unspecified: value = .asleepUnspecified
                }
                samples.append(HKCategorySample(
                    type: type, value: value.rawValue,
                    start: Date(timeIntervalSince1970: TimeInterval(seg.start)),
                    end: Date(timeIntervalSince1970: TimeInterval(seg.end)),
                    metadata: meta))
            }
        }
        guard !samples.isEmpty else { return 0 }
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: keys),
        ])
        _ = try? await store.deleteObjects(of: type, predicate: pred)
        try await store.save(samples)
        return samples.count
    }

    /// UserDefaults key for the HR write cursor (the newest bucket ts we've written). Per-strap so a
    /// device switch restarts the backfill for the new strap instead of resuming mid-stream.
    private var hrWriteCursorKey: String { "hkHRWriteCursor.v1.\(noopDeviceId)" }

    /// Write the strap's continuous heart rate as 1-minute mean samples — the same `hrBuckets` SQL
    /// the charts read (measured-first, PPG fallback), so Health sees exactly what NOOP plots. Raw
    /// ~1 Hz is deliberately downsampled: a fully-worn day is ~86k samples, which bloats the Health
    /// store; 1/min matches Apple Watch's background cadence.
    ///
    /// Dedup: forward-only cursor plus a 48 h rewrite window. Each run deletes OUR OWN prior HR
    /// samples in `[windowStart, now]` (source-scoped, date-range predicate — far cheaper than per-
    /// sample external-UUID keys at this volume) and rewrites the window, so a strap offload that
    /// backfills a recent night reconciles. Offloads older than 48 h behind the cursor are missed
    /// until the cursor is cleared — accepted trade-off for not re-walking 14 days every sync.
    private func writeHeartRate(whoopStore: WhoopStore, fromTs: Int,
                                nowTs: Int, forceFromTs: Int? = nil) async throws -> Int {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate),
              store.authorizationStatus(for: type) == .sharingAuthorized else { return 0 }
        let cursor = UserDefaults.standard.integer(forKey: hrWriteCursorKey)
        let windowStart = forceFromTs ?? (cursor > 0 ? max(fromTs, cursor - 48 * 3600) : fromTs)
        let buckets = (try? await whoopStore.hrBuckets(deviceId: noopDeviceId, from: windowStart,
                                                       to: nowTs, bucketSeconds: 60)) ?? []
        guard !buckets.isEmpty else { return 0 }

        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(withStart: Date(timeIntervalSince1970: TimeInterval(windowStart)),
                                        end: Date(timeIntervalSince1970: TimeInterval(nowTs) + 60),
                                        options: [.strictStartDate, .strictEndDate]),
        ])
        _ = try? await store.deleteObjects(of: type, predicate: pred)

        let unit = HKUnit.count().unitDivided(by: .minute())
        let descriptors = HealthWriteback.heartRateSamples(
            buckets: buckets.map { .init(startTs: $0.ts, bpm: $0.bpm) },
            encoding: heartRateEncoding,
            nowTs: nowTs)
        let samples = descriptors.map { descriptor in
            let key = "noop:\(noopDeviceId):hr:\(descriptor.bucketTs)"
            return HKQuantitySample(type: type,
                                    quantity: .init(unit: unit, doubleValue: descriptor.bpm),
                                    start: Date(timeIntervalSince1970: TimeInterval(descriptor.startTs)),
                                    end: Date(timeIntervalSince1970: TimeInterval(descriptor.endTs)),
                                    metadata: [HKMetadataKeyExternalUUID: key,
                                               Self.originMetadataKey: Self.originMetadataValue,
                                               HKMetadataKeyAlgorithmVersion: NSNumber(value: 1)])
        }
        // First run backfills ~20k samples (14 d × 1440/day); chunk the saves so no single HealthKit
        // transaction is oversized. Cursor only advances past what actually saved.
        var lastSaved = cursor
        var pending = samples[...]
        var pendingTs = descriptors.map(\.bucketTs)[...]
        while !pending.isEmpty {
            let chunk = Array(pending.prefix(5000))
            let chunkTs = Array(pendingTs.prefix(5000))
            pending = pending.dropFirst(chunk.count)
            pendingTs = pendingTs.dropFirst(chunk.count)
            try await store.save(chunk)
            lastSaved = max(lastSaved, chunkTs.last ?? lastSaved)
            UserDefaults.standard.set(lastSaved, forKey: hrWriteCursorKey)
        }
        return samples.count
    }

    /// Install the reversible A/B pair outside the normal 48-hour rewrite window. The user can leave
    /// NOOP, inspect Apple's merged day graph, return, and record which representation appeared.
    func startHeartRateGraphExperiment() async {
        guard auth == .authorized, heartRateExperiment == nil, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            guard let whoopStore = await repo.storeHandle(),
                  let type = HKQuantityType.quantityType(forIdentifier: .heartRate),
                  store.authorizationStatus(for: type) == .sharingAuthorized else {
                throw NSError(domain: "NOOP.HealthKit", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Heart-rate write access is not enabled."])
            }
            guard UserDefaults.standard.integer(forKey: hrWriteCursorKey) > 0 else {
                throw NSError(domain: "NOOP.HealthKit", code: 3,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Run one normal Apple Health sync before starting the graph experiment."])
            }
            let nowTs = Int(Date().timeIntervalSince1970)
            let fromTs = nowTs - 7 * 86_400
            let toTs = nowTs - 72 * 3_600
            let buckets = try await whoopStore.hrBuckets(deviceId: noopDeviceId, from: fromTs,
                                                          to: toTs, bucketSeconds: 60)
            let candidateWindows = HealthWriteback.heartRateExperimentWindows(
                buckets: buckets.map { .init(startTs: $0.ts, bpm: $0.bpm) },
                maximumWindows: 12)
            guard candidateWindows.count >= 2 else {
                throw NSError(domain: "NOOP.HealthKit", code: 2,
                              userInfo: [NSLocalizedDescriptionKey:
                                "Two dense two-hour heart-rate windows were not available between three and seven days ago."])
            }
            var overlapByWindow: [(window: HealthWriteback.HeartRateExperimentWindow, count: Int)] = []
            for window in candidateWindows {
                overlapByWindow.append((window, await externalHeartRateSampleCount(in: window)))
            }
            overlapByWindow.sort {
                if $0.count != $1.count { return $0.count < $1.count }
                return $0.window.startTs < $1.window.startTs
            }
            let intervalWindow = overlapByWindow[0]
            let pointWindow = overlapByWindow[1]
            let experiment = HealthHeartRateExperiment(
                id: UUID().uuidString,
                startedAt: Date(),
                intervalWindow: intervalWindow.window,
                pointWindow: pointWindow.window,
                intervalExternalOverlap: intervalWindow.count,
                pointExternalOverlap: pointWindow.count)
            let persisted = try JSONEncoder().encode(experiment)
            UserDefaults.standard.set(persisted, forKey: Self.heartRateExperimentKey)
            heartRateExperiment = experiment

            _ = try await replaceOwnHeartRateWindow(whoopStore: whoopStore,
                                                    window: intervalWindow.window,
                                                    encoding: .interval60Seconds,
                                                    experimentId: experiment.id + ":interval")
            _ = try await replaceOwnHeartRateWindow(whoopStore: whoopStore,
                                                    window: pointWindow.window,
                                                    encoding: .pointAtBucketMidpoint,
                                                    experimentId: experiment.id + ":point")
            lastError = nil
        } catch {
            lastError = String(localized: "Apple Health sync failed: \(error.localizedDescription)")
        }
    }

    /// Record the observed graph result and restore a single production encoding. A points-only result
    /// selects points; interval-only or ambiguous/Apple-suppressed results retain the safer interval form.
    func finishHeartRateGraphExperiment(result: HealthHeartRateExperiment.Result) async {
        guard heartRateExperiment != nil, !syncing else { return }
        syncing = true
        defer { syncing = false }
        do {
            guard let whoopStore = await repo.storeHandle() else { return }
            let chosen: HealthWriteback.HeartRateSampleEncoding =
                result == .pointVisible ? .pointAtBucketMidpoint : .interval60Seconds
            UserDefaults.standard.set(chosen.rawValue, forKey: Self.heartRateEncodingKey)

            // Re-encode the complete normal lookback now, including both experiment windows. Older
            // history migrates in bounded 14-day chunks on this and later syncs; the persisted bounds
            // make the operation resumable after termination and work in either direction.
            let nowTs = Int(Date().timeIntervalSince1970)
            let lookbackStart = nowTs - 14 * 86_400
            _ = try await writeHeartRate(whoopStore: whoopStore,
                                         fromTs: lookbackStart,
                                         nowTs: nowTs,
                                         forceFromTs: lookbackStart)
            try await prepareHeartRateEncodingMigration(whoopStore: whoopStore,
                                                        beforeTs: lookbackStart)
            _ = try await continueHeartRateEncodingMigration(whoopStore: whoopStore)
            UserDefaults.standard.removeObject(forKey: Self.heartRateExperimentKey)
            heartRateExperiment = nil
            lastError = nil
        } catch {
            lastError = String(localized: "Apple Health sync failed: \(error.localizedDescription)")
        }
    }

    private func prepareHeartRateEncodingMigration(whoopStore: WhoopStore,
                                                    beforeTs: Int) async throws {
        let earliest = try await whoopStore.hrSamples(deviceId: noopDeviceId,
                                                       from: 0, to: beforeTs - 1, limit: 1).first?.ts
        guard let earliest else {
            UserDefaults.standard.removeObject(forKey: Self.heartRateMigrationEndKey)
            UserDefaults.standard.removeObject(forKey: Self.heartRateMigrationFloorKey)
            return
        }
        UserDefaults.standard.set(beforeTs, forKey: Self.heartRateMigrationEndKey)
        UserDefaults.standard.set(earliest, forKey: Self.heartRateMigrationFloorKey)
    }

    /// Migrate one bounded historical chunk per sync. This keeps HealthKit transactions predictable
    /// even for multi-year archives, while every completed chunk is durable and idempotent.
    private func continueHeartRateEncodingMigration(whoopStore: WhoopStore) async throws -> Int {
        let end = UserDefaults.standard.integer(forKey: Self.heartRateMigrationEndKey)
        let floor = UserDefaults.standard.integer(forKey: Self.heartRateMigrationFloorKey)
        guard let chunk = HealthWriteback.heartRateMigrationChunk(endTs: end, floorTs: floor) else {
            return 0
        }
        let count = try await replaceOwnHeartRateWindow(whoopStore: whoopStore,
                                                        window: chunk.window,
                                                        encoding: heartRateEncoding,
                                                        experimentId: nil)
        if chunk.completesMigration {
            UserDefaults.standard.removeObject(forKey: Self.heartRateMigrationEndKey)
            UserDefaults.standard.removeObject(forKey: Self.heartRateMigrationFloorKey)
        } else {
            UserDefaults.standard.set(chunk.window.startTs, forKey: Self.heartRateMigrationEndKey)
        }
        return count
    }

    private func replaceOwnHeartRateWindow(whoopStore: WhoopStore,
                                           window: HealthWriteback.HeartRateExperimentWindow,
                                           encoding: HealthWriteback.HeartRateSampleEncoding,
                                           experimentId: String?) async throws -> Int {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return 0 }
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(
                withStart: Date(timeIntervalSince1970: TimeInterval(window.startTs)),
                end: Date(timeIntervalSince1970: TimeInterval(window.endTs)),
                options: [.strictStartDate, .strictEndDate]),
        ])
        _ = try await store.deleteObjects(of: type, predicate: pred)
        let buckets = try await whoopStore.hrBuckets(deviceId: noopDeviceId,
                                                      from: window.startTs,
                                                      to: window.endTs - 1,
                                                      bucketSeconds: 60)
        let descriptors = HealthWriteback.heartRateSamples(
            buckets: buckets.map { .init(startTs: $0.ts, bpm: $0.bpm) },
            encoding: encoding,
            nowTs: window.endTs)
        let unit = HKUnit.count().unitDivided(by: .minute())
        let samples = descriptors.map { descriptor in
            let key = experimentId.map { "noop:diag:\($0):\(descriptor.bucketTs)" }
                ?? "noop:\(noopDeviceId):hr:\(descriptor.bucketTs)"
            return HKQuantitySample(
                type: type,
                quantity: .init(unit: unit, doubleValue: descriptor.bpm),
                start: Date(timeIntervalSince1970: TimeInterval(descriptor.startTs)),
                end: Date(timeIntervalSince1970: TimeInterval(descriptor.endTs)),
                metadata: [HKMetadataKeyExternalUUID: key,
                           Self.originMetadataKey: Self.originMetadataValue,
                           HKMetadataKeyAlgorithmVersion: NSNumber(value: 1)])
        }
        var pending = samples[...]
        while !pending.isEmpty {
            let chunk = Array(pending.prefix(5_000))
            try await store.save(chunk)
            pending = pending.dropFirst(chunk.count)
        }
        return samples.count
    }

    // MARK: - HRV/SDNN repair (#hrv-sdnn-truncation)

    /// Rebuild NOOP's Apple Health HRV series as true SDNN, walking history backwards in bounded chunks.
    ///
    /// Why this exists: 10.0.0 shipped a one-shot migration that deleted every NOOP-authored sample of
    /// this type across ALL dates (correct in intent — the old values were RMSSD under the SDNN
    /// identifier) but only rewrote the regular 14-day write-back window. Installs that ran it lost
    /// their accumulated HRV series beyond two weeks; installs that never ran it still hold the
    /// mislabelled values. This repair covers both, and is idempotent, so re-running it is harmless.
    ///
    /// Explicit action, never automatic: it writes years of samples into a store the user shares with
    /// every other health app. Same rationale as `startFullHistoryImport`.
    func startHrvSdnnRepair() {
        guard auth == .authorized, !syncing, !fullHistoryImporting, !hrvRepairRunning else { return }
        // Publish synchronously so the view cannot mistake the scheduling gap for a finished run.
        hrvRepairRunning = true
        hrvRepairProgress = 0
        hrvRepairTask = Task { [weak self] in
            guard let self else { return }
            await self.runHrvSdnnRepair()
            self.hrvRepairTask = nil
        }
    }

    /// Cooperative, like `cancelFullHistoryImport`: the chunk in flight finishes its own
    /// delete-and-rewrite (so it cannot be left half-replaced) and no later chunk is started. The
    /// persisted cursor means a later tap continues instead of starting over.
    func cancelHrvSdnnRepair() {
        hrvRepairTask?.cancel()
        hrvRepairTask = nil
    }

    private func runHrvSdnnRepair() async {
        defer {
            hrvRepairRunning = false
            hrvRepairProgress = nil
        }
        guard let whoopStore = await repo.storeHandle() else { return }
        guard let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN),
              store.authorizationStatus(for: hrvType) == .sharingAuthorized else {
            lastError = String(localized: "Apple Health has not granted HRV write access.")
            return
        }
        do {
            try await prepareHrvSdnnRepair(whoopStore: whoopStore)
            let floor = UserDefaults.standard.integer(forKey: Self.hrvRepairFloorKey)
            let top = UserDefaults.standard.integer(forKey: Self.hrvRepairEndKey)
            guard floor > 0, top > floor else {
                // No R-R beats on device ⇒ no true SDNN is computable for ANY day. Deliberately does
                // NOT delete the legacy values and does NOT mark the repair done: removing wrong
                // numbers with nothing to replace them is the very loss this change exists to undo,
                // and a later sync may make the repair possible.
                lastWritebackReport = HealthWritebackReport(completedAt: Date(), entries: [
                    .init(id: "HRV repair", count: 0, authorizedTypes: 1, totalTypes: 1,
                          detail: String(localized: "No R-R data on device — nothing to rebuild")),
                ])
                return
            }
            let span = Double(top - floor)
            var written = 0
            var skipped = 0
            var completed = false
            while !Task.isCancelled {
                let end = UserDefaults.standard.integer(forKey: Self.hrvRepairEndKey)
                guard let chunk = HealthWriteback.backwardMigrationChunk(
                    endTs: end, floorTs: floor, chunkDays: Self.hrvRepairChunkDays) else { break }
                let result = try await replaceOwnHrvWindow(whoopStore: whoopStore, window: chunk.window)
                written += result.written
                skipped += result.skipped
                if chunk.completesMigration {
                    // Marker set ONLY here — after the oldest chunk committed. An interrupted walk
                    // leaves the cursor in place and stays "not done", which is what makes a resume
                    // possible instead of a silent half-repair.
                    UserDefaults.standard.set(true, forKey: Self.hrvRepairDoneKey)
                    UserDefaults.standard.removeObject(forKey: Self.hrvRepairEndKey)
                    UserDefaults.standard.removeObject(forKey: Self.hrvRepairFloorKey)
                    hrvRepairProgress = 1
                    completed = true
                    break
                }
                UserDefaults.standard.set(chunk.window.startTs, forKey: Self.hrvRepairEndKey)
                hrvRepairProgress = min(1, max(0, Double(top - chunk.window.startTs) / span))
            }
            lastWritebackReport = HealthWritebackReport(completedAt: Date(), entries: [
                .init(id: "HRV repair", count: written, authorizedTypes: 1, totalTypes: 1,
                      detail: completed
                        ? String(localized: "Rebuilt · \(skipped) day(s) without R-R skipped")
                        : String(localized: "Paused · \(skipped) day(s) without R-R skipped — tap to continue")),
            ])
            lastError = nil
        } catch {
            lastError = String(localized: "Apple Health sync failed: \(error.localizedDescription)")
        }
    }

    /// Set the backward cursor and the floor, unless a previous run left a cursor to resume from.
    ///
    /// The floor is the EARLIEST R-R beat NOOP actually holds, because that is the oldest day for which
    /// a true SDNN can be computed at all. Walking further back would only delete legacy values without
    /// replacing them, so the repair stops there by design rather than fabricating or blanking days.
    private func prepareHrvSdnnRepair(whoopStore: WhoopStore) async throws {
        guard UserDefaults.standard.object(forKey: Self.hrvRepairEndKey) == nil else { return }
        let nowTs = Int(Date().timeIntervalSince1970)
        let earliest = try await whoopStore.rrIntervals(deviceId: noopDeviceId,
                                                        from: 0, to: nowTs, limit: 1).first?.ts
        guard let earliest, earliest > 0 else {
            UserDefaults.standard.removeObject(forKey: Self.hrvRepairFloorKey)
            return
        }
        UserDefaults.standard.set(nowTs, forKey: Self.hrvRepairEndKey)
        UserDefaults.standard.set(earliest, forKey: Self.hrvRepairFloorKey)
    }

    /// Replace this app's SDNN samples for the rewritable days inside ONE bounded window.
    ///
    /// The invariant that makes the repair safe to interrupt: the delete predicate covers exactly the
    /// days this call is about to save, so the worst case is a day rewritten twice — never a hole in
    /// untouched history, which is precisely what the removed unbounded delete produced.
    ///
    /// The new values are computed BEFORE anything is deleted, so a read or analysis failure leaves
    /// Apple Health untouched instead of emptied.
    private func replaceOwnHrvWindow(whoopStore: WhoopStore,
                                     window: HealthWriteback.TimeWindow)
    async throws -> (written: Int, skipped: Int) {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) else {
            return (0, 0)
        }
        // `sleepSessions` selects by startTs, so read a day early: a night that STARTS before this
        // window but WAKES inside it owns one of its days. The wake filter below decides membership,
        // so the pad cannot pull a foreign day into the chunk.
        let sessions = try await hrvRepairSessions(whoopStore: whoopStore,
                                                   fromTs: window.startTs - 86_400,
                                                   toTs: window.endTs)
        // Longest session per civil wake day — the same rule `writeVitals` uses, so a nap can never
        // replace the main night's recording window and the repair agrees with the regular write-back.
        var mainSleepByDay: [String: CachedSleepSession] = [:]
        for session in sessions where session.endTs > session.effectiveStartTs {
            guard session.endTs >= window.startTs, session.endTs < window.endTs else { continue }
            let day = HealthKitBridge.dayString(Date(timeIntervalSince1970: TimeInterval(session.endTs)))
            let previous = mainSleepByDay[day].map { $0.endTs - $0.effectiveStartTs } ?? -1
            if session.endTs - session.effectiveStartTs > previous { mainSleepByDay[day] = session }
        }

        var samples: [HKQuantitySample] = []
        var rewrittenDays: [String] = []
        var skipped = 0
        for (day, session) in mainSleepByDay {
            let rr = (try? await whoopStore.rrIntervals(deviceId: noopDeviceId,
                                                        from: session.effectiveStartTs,
                                                        to: session.endTs,
                                                        limit: 100_000)) ?? []
            // Same analyzer as the regular write-back — no second implementation, so a repaired day and
            // a freshly written day carry identical values.
            guard let sdnn = HRVAnalyzer.trustedSdnnForExport(rr).sdnn else {
                skipped += 1
                continue
            }
            let at = Date(timeIntervalSince1970: TimeInterval(session.endTs))
            let key = HealthWriteback.vitalsExternalKey(
                noopDeviceId: noopDeviceId,
                identifier: HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue,
                day: day)
            samples.append(HKQuantitySample(
                type: type,
                quantity: .init(unit: .secondUnit(with: .milli), doubleValue: sdnn),
                start: at, end: at,
                metadata: [HKMetadataKeyExternalUUID: key,
                           Self.originMetadataKey: Self.originMetadataValue,
                           HKMetadataKeyAlgorithmVersion: NSNumber(value: 1)]))
            rewrittenDays.append(day)
        }

        // Delete EXACTLY the days about to be rewritten — not the whole window.
        //
        // The invariant at the finest granularity available: a day with no computable SDNN (no stored
        // R-R, which is most CSV-imported history) is left ALONE rather than blanked. Blanking it would
        // reproduce this very bug one chunk at a time, and it is the irreversible direction — a later
        // pass can always delete more, but nothing can restore a deleted series.
        //
        // Scoped by DAY RANGE rather than by external-UUID key on purpose: builds older than the
        // metadata dedup scheme (see `writeBack`'s note on duplicate flooding) wrote samples with NO
        // external key at all, so a key-scoped delete would leave those behind as duplicates on exactly
        // the days being rewritten.
        var dayPredicates: [NSPredicate] = []
        for day in rewrittenDays {
            guard let dayStart = HealthKitBridge.date(from: day),
                  let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
            else { continue }
            dayPredicates.append(HKQuery.predicateForSamples(
                withStart: dayStart, end: dayEnd, options: [.strictStartDate]))
        }
        guard !dayPredicates.isEmpty else { return (0, skipped) }
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            NSCompoundPredicate(orPredicateWithSubpredicates: dayPredicates),
        ])
        _ = try await store.deleteObjects(of: type, predicate: pred)
        try await store.save(samples)
        return (samples.count, skipped)
    }

    /// Computed sessions first, imported overriding on a startTs collision — the same source precedence
    /// as `writeBack` and `IntelligenceEngine`'s sleep reads, so the repair scores the same nights the
    /// dashboard shows.
    private func hrvRepairSessions(whoopStore: WhoopStore,
                                   fromTs: Int, toTs: Int) async throws -> [CachedSleepSession] {
        let computed = (try? await whoopStore.sleepSessions(deviceId: computedDeviceId,
                                                            from: fromTs, to: toTs, limit: 2_000)) ?? []
        let imported = (try? await whoopStore.sleepSessions(deviceId: noopDeviceId,
                                                            from: fromTs, to: toTs, limit: 2_000)) ?? []
        var byStart: [Int: CachedSleepSession] = [:]
        for s in computed { byStart[s.startTs] = s }
        for s in imported { byStart[s.startTs] = s }
        return byStart.keys.sorted().map { byStart[$0]! }
    }

    private func externalHeartRateSampleCount(
        in window: HealthWriteback.HeartRateExperimentWindow) async -> Int {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return 0 }
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            Self.notNoopAuthored,
            HKQuery.predicateForSamples(
                withStart: Date(timeIntervalSince1970: TimeInterval(window.startTs)),
                end: Date(timeIntervalSince1970: TimeInterval(window.endTs)), options: []),
        ])
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: pred,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: samples?.count ?? 0)
            }
            store.execute(query)
        }
    }

    /// Read only the HR samples authored by this app in a workout window. These objects are already in
    /// HealthKit; associating them with a workout adds detail without creating a duplicate HR series.
    private func ownHeartRateSamples(start: Date, end: Date) async -> [HKQuantitySample] {
        guard let type = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return [] }
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForSamples(withStart: start, end: end,
                                        options: [.strictStartDate, .strictEndDate]),
        ])
        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: pred,
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                continuation.resume(returning: samples as? [HKQuantitySample] ?? [])
            }
            store.execute(query)
        }
    }

    /// Write strap-detected and manual workouts into Health via `HKWorkoutBuilder`, with an
    /// `activeEnergyBurned` sample when the row has energy and a distance sample for distance
    /// sports. Workouts whose source is `apple-health` are EXCLUDED — those were imported FROM
    /// Health, and writing them back would duplicate the user's own Apple Watch/gym-app workouts.
    ///
    /// Dedup: `HKMetadataKeyExternalUUID = noop:<deviceId>:workout:<startTs>` in the workout
    /// metadata; delete-then-write scoped to our own source, like sleep and the vitals.
    private func writeWorkouts(whoopStore: WhoopStore, fromTs: Int, toTs: Int) async throws -> Int {
        guard store.authorizationStatus(for: .workoutType()) == .sharingAuthorized else { return 0 }
        let mine = (try? await whoopStore.workouts(deviceId: noopDeviceId, from: fromTs, to: toTs, limit: 500)) ?? []
        let computed = (try? await whoopStore.workouts(deviceId: computedDeviceId, from: fromTs, to: toTs, limit: 500)) ?? []
        var byKey: [String: WorkoutRow] = [:]
        for w in computed + mine where w.source != HealthKitBridge.appleWorkoutSource {
            byKey["\(w.startTs):\(w.sport)"] = w
        }
        let rows = byKey.values.sorted { $0.startTs < $1.startTs }
        guard !rows.isEmpty else { return 0 }

        func key(_ row: WorkoutRow) -> String { "noop:\(noopDeviceId):workout:\(row.startTs)" }
        let pred = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID,
                                        allowedValues: rows.map(key)),
        ])
        _ = try? await store.deleteObjects(of: .workoutType(), predicate: pred)

        var written = 0
        for row in rows {
            let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
            let end = Date(timeIntervalSince1970: TimeInterval(row.endTs))
            guard end > start else { continue }
            let config = HKWorkoutConfiguration()
            config.activityType = Self.activityType(forSport: row.sport)
            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
            do {
                try await builder.beginCollection(at: start)
                try await builder.addMetadata([HKMetadataKeyExternalUUID: key(row),
                                               Self.originMetadataKey: Self.originMetadataValue])
                var extras: [HKSample] = []
                if let kcal = row.energyKcal, kcal > 0,
                   let t = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
                   store.authorizationStatus(for: t) == .sharingAuthorized {
                    extras.append(HKQuantitySample(type: t, quantity: .init(unit: .kilocalorie(), doubleValue: kcal),
                                                   start: start, end: end,
                                                   metadata: [Self.originMetadataKey: Self.originMetadataValue]))
                }
                if let meters = row.distanceM, meters > 0,
                   let id = Self.distanceTypeId(forSport: row.sport),
                   let t = HKQuantityType.quantityType(forIdentifier: id),
                   store.authorizationStatus(for: t) == .sharingAuthorized {
                    extras.append(HKQuantitySample(type: t, quantity: .init(unit: .meter(), doubleValue: meters),
                                                   start: start, end: end,
                                                   metadata: [Self.originMetadataKey: Self.originMetadataValue]))
                }
                let heartRate = await ownHeartRateSamples(start: start, end: end)
                extras.append(contentsOf: heartRate.map { $0 as HKSample })
                if !extras.isEmpty { try await builder.addSamples(extras) }
                try await builder.endCollection(at: end)
                guard try await builder.finishWorkout() != nil else { continue }
                written += 1
            } catch {
                builder.discardWorkout()
                throw error
            }
        }
        return written
    }

    /// Reverse of `sportName`: NOOP's sport label → the `HKWorkoutActivityType` written to Health.
    /// Labels the forward map collapses (e.g. boxing/kickboxing → "Boxing") reverse to the first
    /// member; unknown labels fall back to `.other`, never dropped.
    private static func activityType(forSport sport: String) -> HKWorkoutActivityType {
        if sport == LiftingImporter.sport { return .traditionalStrengthTraining }
        switch sport.lowercased() {
        case "running":       return .running
        case "walking":       return .walking
        case "hiking":        return .hiking
        case "cycling":       return .cycling
        case "hiit":          return .highIntensityIntervalTraining
        case "core training": return .coreTraining
        case "yoga":          return .yoga
        case "pilates":       return .pilates
        case "rowing":        return .rowing
        case "elliptical":    return .elliptical
        case "stairs":        return .stairClimbing
        case "jump rope":     return .jumpRope
        case "boxing":        return .boxing
        case "basketball":    return .basketball
        case "soccer":        return .soccer
        case "football":      return .americanFootball
        case "baseball":      return .baseball
        case "badminton":     return .badminton
        case "tennis":        return .tennis
        case "table tennis":  return .tableTennis
        case "volleyball":    return .volleyball
        case "squash":        return .squash
        case "martial arts":  return .martialArts
        case "dancing":       return .dance
        case "golf":          return .golf
        case "climbing":      return .climbing
        case "skiing":        return .downhillSkiing
        case "snowboarding":  return .snowboarding
        case "swimming":      return .swimming
        case "surfing":       return .surfingSports
        case "paddling":      return .paddleSports
        default:              return .other
        }
    }

    /// Which distance quantity a sport's `distanceM` maps to; nil for sports whose Health distance
    /// type NOOP doesn't request share access for (e.g. swimming).
    private static func distanceTypeId(forSport sport: String) -> HKQuantityTypeIdentifier? {
        switch sport.lowercased() {
        case "running", "walking", "hiking": return .distanceWalkingRunning
        case "cycling":                      return .distanceCycling
        default:                             return nil
        }
    }

    private struct DayAgg {
        var restingHr: Double?; var avgHr: Double?; var maxHr: Double?; var hrv: Double?
        var spo2: Double?; var respRate: Double?; var steps: Double?
        var activeKcal: Double?; var basalKcal: Double?; var vo2max: Double?
        var weightKg: Double?; var bodyFatPct: Double?; var leanMassKg: Double?; var bmi: Double?
        var asleepMin: Double?; var deepMin: Double?; var remMin: Double?; var coreMin: Double?
        var waterMl: Double?
    }

    /// Excludes NOOP's own write-back samples from reads, so the two-way sync never reads its own
    /// output back in as "apple-health" data — which would make the strap and "Apple Health" plot the
    /// same line for a strap-only user, and bias the apple-health average for someone who also has a
    /// watch. `HKSource.default()` is this app's own source. (Reimplemented from @vulnix0x4's PR #375.)
    nonisolated static var notNoopAuthored: NSPredicate {
        let currentSource = HKQuery.predicateForObjects(from: [HKSource.default()])
        let stableOrigin = HKQuery.predicateForObjects(
            withMetadataKey: originMetadataKey,
            allowedValues: [originMetadataValue])
        return NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSCompoundPredicate(notPredicateWithSubpredicate: currentSource),
            NSCompoundPredicate(notPredicateWithSubpredicate: stableOrigin),
        ])
    }

    /// Client-side superset of `notNoopAuthored`. The prefix fallback must remain here because
    /// HealthKit rejects `.beginsWith` for `HKMetadataKeyExternalUUID` at query execution time.
    nonisolated private static func isNoopAuthored(_ object: HKObject) -> Bool {
        isNoopAuthored(currentSource: object.sourceRevision.source == HKSource.default(),
                       origin: object.metadata?[originMetadataKey] as? String,
                       externalUUID: object.metadata?[HKMetadataKeyExternalUUID] as? String)
    }

    /// Pure seam for the three generations of write-back identity. Kept internal so the iOS test target
    /// can prove that current-source, stable-origin and legacy UUID samples are rejected independently.
    nonisolated static func isNoopAuthored(currentSource: Bool, origin: String?, externalUUID: String?) -> Bool {
        currentSource || origin == originMetadataValue || externalUUID?.hasPrefix("noop:") == true
    }

    /// Returns TRUE when the query completed, FALSE when HealthKit handed back an error.
    ///
    /// Every aggregate caller ignores this: a failed type simply contributes nothing to `DayAgg` and the
    /// affected fields stay nil, so no row is written for them. It matters only for a caller whose write
    /// REPLACES rather than adds (#949 imported water), where "read nothing" and "there is nothing" are
    /// the same empty result — and treating a failed query as an authoritative zero would wipe the
    /// stored figure for the whole window.
    @discardableResult
    private func collect(_ id: HKQuantityTypeIdentifier, unit: HKUnit, start: Date, end: Date,
                         op: HKStatisticsOptions, sink: @escaping (String, Double) -> Void) async -> Bool {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return false }
        let cal = Calendar.current
        let anchor = cal.startOfDay(for: start)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
            Self.notNoopAuthored,
        ])
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let q = HKStatisticsCollectionQuery(quantityType: type, quantitySamplePredicate: predicate,
                                                options: op, anchorDate: anchor,
                                                intervalComponents: DateComponents(day: 1))
            q.initialResultsHandler = { _, results, error in
                // A nil `results` with an error is a FAILED read, not an empty one — see the note on
                // the return value. Both are reported as false so the caller can tell them apart from
                // a query that genuinely found nothing.
                guard error == nil, let results else { cont.resume(returning: false); return }
                results.enumerateStatistics(from: start, to: end) { stats, _ in
                    let q: HKQuantity?
                    switch op {
                    case .cumulativeSum:     q = stats.sumQuantity()
                    case .discreteAverage:   q = stats.averageQuantity()
                    case .discreteMax:       q = stats.maximumQuantity()
                    case .discreteMostRecent: q = stats.mostRecentQuantity()
                    default:                 q = stats.averageQuantity()
                    }
                    if let q { sink(HealthKitBridge.dayString(stats.startDate), q.doubleValue(for: unit)) }
                }
                cont.resume(returning: true)
            }
            store.execute(q)
        }
    }

    private func collectSleep(start: Date, end: Date,
                              sink: @escaping (String, Double?, Double?, Double?, Double?) -> Void) async {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: []),
            Self.notNoopAuthored,
        ])
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let q = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                var asleep: [String: Double] = [:], deep: [String: Double] = [:]
                var rem: [String: Double] = [:], core: [String: Double] = [:]
                for case let s as HKCategorySample in samples ?? [] where !Self.isNoopAuthored(s) {
                    let mins = s.endDate.timeIntervalSince(s.startDate) / 60
                    let day = HealthKitBridge.dayString(s.endDate)
                    switch s.value {
                    case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                        deep[day, default: 0] += mins; asleep[day, default: 0] += mins
                    case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                        rem[day, default: 0] += mins; asleep[day, default: 0] += mins
                    case HKCategoryValueSleepAnalysis.asleepCore.rawValue, HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
                        core[day, default: 0] += mins; asleep[day, default: 0] += mins
                    default:
                        break
                    }
                }
                for day in Set(asleep.keys) {
                    sink(day, asleep[day], deep[day], rem[day], core[day])
                }
                cont.resume()
            }
            store.execute(q)
        }
    }

    // MARK: - Workouts (#835)

    /// Read the workouts the user logged in Apple Health over `[start, end)` and map each to a
    /// `WorkoutRow` under the apple-health source. ON-DEVICE ONLY: a straight HealthKit `HKWorkout` query,
    /// no cloud or third-party API. NOOP-authored workouts are excluded (the same `notNoopAuthored`
    /// predicate the metric reads use) so our own write-back never re-imports as "Apple Health". Mirrors
    /// the macOS export importer and the Android Health Connect importer, which already ingest workouts,
    /// closing the iOS gap. The upsert is idempotent on (deviceId, startTs), so re-running a sync window
    /// refreshes rather than duplicates.
    /// Individual caffeine samples in the window, newest first (#949).
    ///
    /// A SAMPLE query, not the day-bucketed `collect`: the caffeine card estimates what is still active
    /// from a half-life decay, so it needs each intake's own timestamp. A day total would collapse a 7am
    /// coffee and a 9pm one into a single number that answers no question the card asks.
    ///
    /// Each sample keeps its HealthKit UUID as `externalId` so a re-import can tell an intake it already
    /// has from a new one. `notNoopAuthored` keeps NOOP's own samples out — we do not write caffeine
    /// today, but the predicate costs nothing and closes the loop if that ever changes.
    ///
    /// Returns nil when the read FAILED, as distinct from an empty array meaning "no caffeine logged".
    /// The caller replaces the imported set wholesale, so collapsing those two cases would let a failed
    /// query silently delete every imported intake.
    private func collectCaffeine(start: Date, end: Date) async -> [CaffeineIntake]? {
        guard let type = HKQuantityType.quantityType(forIdentifier: .dietaryCaffeine) else { return nil }
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
            Self.notNoopAuthored,
        ])
        return await withCheckedContinuation { (cont: CheckedContinuation<[CaffeineIntake]?, Never>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
            let q = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, error in
                // The CAST is part of the failure test, not a fallback. `?? []` here would turn an
                // unexpected sample type into "no caffeine tonight", and the caller replaces the imported
                // set wholesale — so a cast that ever failed would silently delete every imported intake.
                // Same reasoning as the error check beside it.
                guard error == nil, let samples = samples as? [HKQuantitySample] else {
                    cont.resume(returning: nil); return
                }
                let out: [CaffeineIntake] = samples.compactMap { s in
                    guard !Self.isNoopAuthored(s) else { return nil }
                    let mg = s.quantity.doubleValue(for: .gramUnit(with: .milli))
                    // A zero or non-finite sample carries no dose worth showing; skip it rather than log
                    // a 0 mg intake, which would pad the "intakes still active" count with nothing.
                    guard mg.isFinite, mg > 0 else { return nil }
                    // The sample's OWN uuid as the intake id, not a fresh one. `CaffeineIntake` defaults
                    // `id` to `UUID()`, so minting one here would give the same coffee a different
                    // identity on every sync: `replaceImported`'s no-op guard would never match (a
                    // pointless JSON rewrite + republish each time), and `ForEach` would see the whole
                    // logged list as new rows and rebuild it. HealthKit sample uuids are stable.
                    return CaffeineIntake(id: s.uuid, at: s.startDate, mg: mg,
                                          externalId: s.uuid.uuidString)
                }
                cont.resume(returning: out)
            }
            store.execute(q)
        }
    }

    private func collectWorkouts(start: Date, end: Date) async -> [WorkoutRow] {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
            Self.notNoopAuthored,
        ])
        return await withCheckedContinuation { (cont: CheckedContinuation<[WorkoutRow], Never>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, samples, _ in
                var rows: [WorkoutRow] = []
                for case let workout as HKWorkout in samples ?? [] where !Self.isNoopAuthored(workout) {
                    let startTs = Int(workout.startDate.timeIntervalSince1970)
                    let endTs = max(Int(workout.endDate.timeIntervalSince1970), startTs)
                    let duration = workout.duration > 0 ? workout.duration : Double(endTs - startTs)
                    rows.append(WorkoutRow(
                        startTs: startTs,
                        endTs: endTs,
                        sport: Self.sportName(workout.workoutActivityType),
                        source: HealthKitBridge.appleWorkoutSource,
                        durationS: duration,
                        energyKcal: workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()),
                        avgHr: nil,
                        maxHr: nil,
                        strain: nil,
                        distanceM: workout.totalDistance?.doubleValue(for: .meter()),
                        zonesJSON: nil,
                        notes: nil))
                }
                cont.resume(returning: rows)
            }
            store.execute(q)
        }
    }

    /// Source tag stamped on workouts imported from Apple Health. Matches the macOS importer's
    /// `WorkoutSource.appleHealthSource` ("apple-health") and `appleDeviceId`, so the workout list and
    /// source filters treat an iOS-read workout exactly like a macOS-imported one.
    static let appleWorkoutSource = "apple-health"

    /// Map an `HKWorkoutActivityType` to NOOP's human sport label. Strength training routes to the
    /// shared lifting sport so a gym session lands in the Lifting lane; anything we don't name explicitly
    /// falls back to a generic "Workout" rather than an opaque numeric type.
    private static func sportName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running:                    return "Running"
        case .walking:                    return "Walking"
        case .hiking:                     return "Hiking"
        case .cycling:                    return "Cycling"
        case .traditionalStrengthTraining,
             .functionalStrengthTraining: return LiftingImporter.sport
        case .highIntensityIntervalTraining: return "HIIT"
        case .coreTraining:               return "Core training"
        case .yoga:                       return "Yoga"
        case .pilates:                    return "Pilates"
        case .rowing:                     return "Rowing"
        case .elliptical:                 return "Elliptical"
        case .stairClimbing, .stairs:     return "Stairs"
        case .jumpRope:                   return "Jump rope"
        case .boxing, .kickboxing:        return "Boxing"
        case .basketball:                 return "Basketball"
        case .soccer:                     return "Soccer"
        case .americanFootball:           return "Football"
        case .baseball:                   return "Baseball"
        case .badminton:                  return "Badminton"
        case .tennis:                     return "Tennis"
        case .tableTennis:                return "Table tennis"
        case .volleyball:                 return "Volleyball"
        case .squash, .racquetball:       return "Squash"
        case .martialArts, .taiChi:       return "Martial arts"
        case .dance, .cardioDance, .socialDance: return "Dancing"
        case .golf:                       return "Golf"
        case .climbing:                   return "Climbing"
        case .downhillSkiing, .crossCountrySkiing: return "Skiing"
        case .snowboarding:               return "Snowboarding"
        case .swimming:                   return "Swimming"
        case .surfingSports:              return "Surfing"
        case .paddleSports:               return "Paddling"
        default:                          return "Workout"
        }
    }

    // MARK: - Entitlement detection (#348)

    /// True when this running build actually carries the `com.apple.developer.healthkit` entitlement —
    /// i.e. it can genuinely reach Apple Health. False for a free-Apple-ID / AltStore / Sideloadly
    /// re-sign, which strips the HealthKit capability: the framework links and `isHealthDataAvailable()`
    /// is still true, but `requestAuthorization` is a dead-end and the app can never appear under
    /// Settings › Health › Data Access & Devices.
    ///
    /// Resolution order (most authoritative first), mirroring `IOSDiagnostics`'s profile parse:
    ///  1. If an `embedded.mobileprovision` is present (every dev / sideloaded / TestFlight build ships
    ///     one), slice the wrapped XML plist and look for `com.apple.developer.healthkit` in its
    ///     `Entitlements` dict. A free re-sign re-writes this profile WITHOUT that key. This is the
    ///     definitive signal and is unaffected by whether the user later granted/denied permission.
    ///  2. No embedded profile → an App Store install (App Store strips it). Those are properly signed
    ///     with whatever capabilities the app declares, so treat the entitlement as PRESENT. This is the
    ///     conservative default: it never down-routes a legitimately-signed build, so a user who simply
    ///     denied permission keeps the normal Settings guidance rather than the file-import reroute.
    ///
    /// Computed once and cached: the bundle's profile can't change within a process lifetime.
    static let hasHealthKitEntitlement: Bool = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            // No embedded profile = App Store build = properly signed. Assume present.
            return true
        }
        guard let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(of: Data("</plist>".utf8)) else {
            // Profile present but unparseable — don't claim a missing entitlement off a parse failure;
            // assume present so we never wrongly down-route a real build.
            return true
        }
        let plistData = data.subdata(in: xmlStart.lowerBound..<xmlEnd.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else {
            return true
        }
        // The key is present (and truthy) on an entitled build; a free re-sign omits it entirely.
        return entitlements["com.apple.developer.healthkit"] != nil
    }()

    // MARK: - Date helpers

    // LOCAL civil day: the rest of the store keys days by the device-local civil day —
    // AppleHealthAggregator.localDay shifts each sample into its own offset, and
    // Repository.dayFormatter leaves timeZone at the default (local) zone. The
    // HKStatisticsCollectionQuery here already buckets in Calendar.current (anchor =
    // startOfDay, interval = 1 day), so labelling those local-midnight bucket starts with a
    // matching local formatter is strictly 1:1; using UTC instead mislabelled a full local day
    // under the previous UTC date for users east of UTC, so apple-health rows never merged with
    // the strap-computed/imported rows for the same civil day.
    // `nonisolated` so the HealthKit query completion handlers — which HealthKit invokes on a private
    // background queue (a nonisolated context) — can label day buckets without a main-actor-isolation
    // warning. They only read a thread-safe DateFormatter, so this is safe off the main actor.
    nonisolated private static let dayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone.current; return f
    }()
    nonisolated private static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }
    nonisolated private static func date(from day: String) -> Date? { dayFormatter.date(from: day) }
}
#endif
