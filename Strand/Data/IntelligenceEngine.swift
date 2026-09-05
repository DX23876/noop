import Foundation
import Combine
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// On-device "intelligence": computes recovery / day-strain / sleep from the raw strap streams using
/// the same model shape WHOOP uses (HRV vs personal baseline ~60%, resting HR ~20%, sleep ~15%,
/// respiration ~5%; strain 0–21 from cardiovascular load). This is what makes NOOP independent of
/// WHOOP's cloud , for any day the strap collected raw data with NOOP connected, NOOP scores it
/// itself rather than relying on the values WHOOP computed in the imported CSV.
@MainActor
final class IntelligenceEngine: ObservableObject {
    /// Minimum raw HR samples required before a day is scored. Shared by the gate and its diagnostics so
    /// the threshold cannot drift between code paths (RyanBR #1538 parity).
    static let minHrSamples = 200

    /// Version of the *meaning* of persisted derived scores. App marketing/build versions are
    /// deliberately unrelated: bump this only when an analytics change makes existing scores stale.
    // v2: RyanBR v11 changes persisted analysis inputs/outputs (including absolute nightly skin
    // temperature and scoring-source handling). Existing v1 rows need one bounded refresh.
    static let currentAnalysisRecipeVersion = 2
    static let analysisRecipeCursor = "analysis:recipeVersion"
    static let analysisLastRunKey = "noop.analysisMaintenance.lastRun"

    enum AnalysisMaintenancePhase: Equatable {
        case idle
        case checking
        case migrating(from: Int, to: Int)
        case manualRecent
        case refreshingToday
        case completed(Date)
        case failed(String)
    }

    enum AnalysisRecipeDecision: Equatable {
        /// Existing installs predate the cursor. Trust their current rows and establish the baseline
        /// without turning an ordinary reinstall into a historical reanalysis.
        case anchorCurrent
        case upToDate
        case migrate(from: Int, to: Int)
    }

    static func analysisRecipeDecision(storedVersion: Int?) -> AnalysisRecipeDecision {
        guard let storedVersion else { return .anchorCurrent }
        guard storedVersion < currentAnalysisRecipeVersion else { return .upToDate }
        return .migrate(from: storedVersion, to: currentAnalysisRecipeVersion)
    }

    private let repo: Repository
    private let profile: ProfileStore
    /// The CANONICAL id under whose `-noop` sibling this engine WRITES the computed daily rows, and from
    /// which it reads the imported-only baseline (`hist`). STABLE on "my-whoop", it must NOT follow the
    /// active strap, or a remove+re-add would orphan the computed history banked under the canonical id
    /// (the #814 follow-up union model). The engine still reads + scores a re-added strap's RAW streams:
    /// per-day owner resolution (`resolveDayOwner`) reads the registry's OWN active id directly (`regActiveId`
    /// below) and pulls each day's raw under the resolved owner, then persists the result to this STABLE
    /// canonical `-noop` sibling. The Repository's union read then surfaces both the canonical computed
    /// history and the active strap's live data together. So this never moves after construction.
    private let deviceId: String

    @Published var results: [Computed] = []      // newest first
    @Published var computing = false
    @Published var note: String?
    @Published private(set) var analysisRecipeVersion = 0
    @Published private(set) var analysisMaintenancePhase: AnalysisMaintenancePhase = .idle
    /// Live progress of the running pass, or nil when none is in flight. See `AnalysisProgress` for why a
    /// spinner was not enough. Written once per day (plus one per surrounding stage) from the detached
    /// scan through a main-actor hop, so it costs one published write per ~15 s of work.
    @Published private(set) var analysisProgress: AnalysisProgress?

    /// Accept a progress step, refusing any that would move the day counter BACKWARDS. Each step hops to
    /// the main actor as its own `Task`, and separate tasks carry no ordering guarantee between them — so
    /// without this a late-delivered step could make the bar and the day number jump back, which reads as
    /// the pass restarting. The stage is allowed to advance freely; only the day counter is monotonic.
    func noteAnalysisProgress(_ next: AnalysisProgress) {
        if let current = analysisProgress, current.stage == next.stage,
           next.completedDays < current.completedDays { return }
        analysisProgress = next
    }

    enum AnalysisReason: Int, Sendable {
        case rawMutation = 0
        case ownerChange = 1
        case timestampHeal = 2
        case effortMigration = 3
        case semanticChange = 4
    }

    /// The shape of the pass that SETTLES an outstanding re-score debt (#1538), as a value so the choice
    /// is pinned by a test rather than left as four defaults at a call site.
    ///
    /// A debt is recorded in two situations, and this has to be right for both:
    ///
    ///  • the post-offload pass was DEFERRED because the app was backgrounded. That pass would have run
    ///    as `skipIfUnchanged: true, allowDayReuse: true` — a completed offload is a pure raw-data change
    ///    in specific days, which is exactly what the per-day fingerprint resolves.
    ///  • a pass was KILLED partway. It wrote no fingerprints (they are written at the end), so the days
    ///    it would have re-derived still carry their previous ones and are re-derived again on the next
    ///    pass if — and only if — their raw inputs actually moved.
    ///
    /// So: FORCED, because the debt is already the answer to "is there work?" and gating on the whole-
    /// window fingerprint would ask it again. But with day reuse ALLOWED, because the debt says work
    /// exists SOMEWHERE in the window, never that all 21 days must be re-derived from raw.
    ///
    /// Settling with `allowDayReuse: false` — the previous behaviour, inherited from the defaults — turned
    /// every foreground entry after a background sync into a full 21-day re-derivation, and on a library
    /// where a pass exceeds `RescoreBackgroundPolicy.backgroundBudgetSeconds` that is self-sustaining: the
    /// long pass keeps `lastCompletedPassSeconds` over budget, so the next background offload defers
    /// again, records another debt, and the next foreground entry pays the full cost again. The wearer
    /// sees the app re-analysing every single time they open it, with nothing having changed.
    nonisolated static func deferredRescorePlan()
        -> (force: Bool, skipIfUnchanged: Bool, allowDayReuse: Bool, reason: AnalysisReason) {
        (force: true, skipIfUnchanged: false, allowDayReuse: true, reason: .rawMutation)
    }

    private struct PendingAnalysis {
        var maxDays: Int
        var force: Bool
        var skipIfUnchanged: Bool
        var allowDayReuse: Bool
        var reason: AnalysisReason
        var affectedLower: Int?
        var affectedUpper: Int?
        var waiters: [CheckedContinuation<Void, Never>]

        mutating func merge(maxDays: Int, force: Bool, skipIfUnchanged: Bool,
                            allowDayReuse: Bool, reason: AnalysisReason,
                            affectedUTCInterval: Range<Int>?,
                            waiter: CheckedContinuation<Void, Never>? = nil) {
            self.maxDays = max(self.maxDays, maxDays)
            self.force = self.force || force
            // A coalesced pass may only use an optimisation when every request permits it.
            self.skipIfUnchanged = self.skipIfUnchanged && skipIfUnchanged
            self.allowDayReuse = self.allowDayReuse && allowDayReuse
            if reason.rawValue > self.reason.rawValue { self.reason = reason }
            if let range = affectedUTCInterval {
                affectedLower = min(affectedLower ?? range.lowerBound, range.lowerBound)
                affectedUpper = max(affectedUpper ?? range.upperBound, range.upperBound)
            }
            if let waiter { waiters.append(waiter) }
        }
    }

    private var pendingAnalysis: PendingAnalysis?
    private var analysisRunnerActive = false
    /// Coalesce foreground, backfill, and workout-finish requests onto one small current-day read.
    /// These signals often arrive together; letting each one scan the same day independently would
    /// recreate the contention this fast path is intended to avoid.
    private var currentDayActivityRefreshTask: Task<Bool, Never>?
    private var analysisMaintenanceTask: Task<Bool, Never>?
    /// #899 heal bound: true while the last heal already re-armed a rescore, so a heal firing again on
    /// the very next pass cannot re-arm a second time (the Android twin is hard-bounded to exactly one
    /// re-pass; this mirrors it). Reset by any pass whose heal finds nothing, restoring the budget.
    private var healRearmedThisCycle = false

    // #1005 (upstream) landed an IN-MEMORY per-day reuse cache for `analyzeRecent`'s pass-1 loop. This
    // fork skips the same work through the PERSISTED `dayScanFingerprint` / `analysisInputRevision` rows
    // instead (v38-v40; see the skip block in `analyzeRecent`), which survives relaunch and is invalidated
    // by the write-side revision rather than by a session-local key — so the in-memory twin is not carried
    // here. `AnalyzeRecentDayCache` (StrandAnalytics) still ships with upstream's key derivation, unused.

    /// Who supplies the dashboard headline for a By-Day row. The By-Day card always shows NOOP's OWN
    /// on-device numbers, but the WHOLE-DASHBOARD value for the same day can come from an IMPORTED row
    /// that won the per-day merge (imports win field-by-field over computed , see Repository.mergeDaily).
    /// We resolve the REAL provenance so the card's badge tells a strap-scored night apart from an
    /// imported one, instead of always claiming "NOOP-computed". (Sleep overhaul §2.6 honesty fix.)
    /// The `stages=` token of the per-day sleep diagnostic line (#386): `<deep>+<rem>+<light>=<sum>` in
    /// rounded minutes when the day carries a full banked stage split, `nil` when any component is
    /// absent (an unstaged night, or an imported day that only brought a total). The sum is printed
    /// rather than left to the reader so a rollup-vs-stages divergence — the exact identity a "homepage
    /// disagrees with the Sleep tab" report hinges on — is a one-line visual check against the
    /// `totalSleepMin=` field beside it. Pure; mirrors the Android `sleepStagesLogToken` byte-for-byte.
    static func sleepStagesLogToken(deep: Double?, rem: Double?, light: Double?) -> String {
        guard let deep, let rem, let light else { return "nil" }
        return "\(Int(deep.rounded()))+\(Int(rem.rounded()))+\(Int(light.rounded()))=\(Int((deep + rem + light).rounded()))"
    }

    enum DaySource: Equatable {
        /// NOOP scored this day itself from the raw strap streams; no import covers it.
        case computed
        /// A WHOOP export covers this day and wins the dashboard merge.
        case whoopImport
        /// An Apple Health import covers this day and wins the dashboard merge.
        case appleHealth

        /// The badge shown on the By-Day card. Brand wording matches the rest of the app
        /// (SleepView "On-device"/"Whoop", Today "Apple Health"). NO em-dashes.
        var badge: String {
            switch self {
            case .computed:    return String(localized: "On-device")
            case .whoopImport: return "Whoop"
            case .appleHealth: return "Apple Health"
            }
        }

        /// The short token for the per-day strap-log diagnostic (privacy-safe; no device ids leak).
        var logToken: String {
            switch self {
            case .computed:    return "computed"
            case .whoopImport: return "imported:whoop"
            case .appleHealth: return "imported:apple"
            }
        }

        /// Resolve a day's provenance from the imported day-key sets. A WHOOP export covering the day
        /// WINS the dashboard merge over our computed row (imports win field-by-field , Repository
        /// .mergeDaily), so it takes precedence; Apple Health is next; otherwise the day is purely
        /// computed. WHOOP-over-Apple matches the merge's source priority (whoopImport 0 < appleHealth 2
        /// in DailyMetricSource.vitalPriority). Pure + set-based so it's unit-tested directly and is the
        /// SAME logic `analyzeRecent` ships. Mirrors the Android `IntelligenceEngine.daySourceToken`. (§2.6)
        static func classify(day: String, importedWhoopDays: Set<String>,
                             appleHealthDays: Set<String>) -> DaySource {
            if importedWhoopDays.contains(day) { return .whoopImport }
            if appleHealthDays.contains(day) { return .appleHealth }
            return .computed
        }
    }

    /// One day's off-actor scan output (FIX 1). Carries the pure `AnalyticsEngine.DayResult` produced by
    /// the off-main scan loop plus the pre-computed RHR floor-vs-mean diagnostic line (#691) , computed
    /// inside the detached task from pure inputs so the main actor can replay it through the
    /// MainActor-bound `diagnosticSink` in the SAME per-day order. Deliberately NOT marked `Sendable`:
    /// its `AnalyticsEngine.DayResult` member isn't formally `Sendable` either, and the per-day loop ALREADY
    /// returned a `DayResult` across the `Task.detached` boundary under this project's `minimal` strict-
    /// concurrency setting (SWIFT_STRICT_CONCURRENCY: minimal, Swift 5 mode) , this wraps the same value
    /// type the same way, so it crosses the boundary identically.
    private struct DayScan {
        let result: AnalyticsEngine.DayResult
        /// Revisions of every scoring-relevant input intersecting this day's exact read window. Recorded
        /// only after scores persist. nil means the probe failed and the day is deliberately not reusable.
        let inputProbe: AnalysisInputRevision?
        let rhrLine: String?
        /// #1331 respiratory diagnostic line (see `respRateLogLine`); replayed with `rhrLine`.
        let respLine: String?
        /// CAPTURE-B (#814/#799): the resolved READ owner id this day was scored from, and how many HR rows
        /// that owner returned for the night window, carried out of the off-actor loop so the main-actor
        /// fold can emit the universal `dayOwner …` self-diagnostic line (it needs the registry active id +
        /// provenance sets, which are resolved on the main actor).
        let readOwner: String
        let hrRows: Int
        /// Sleep & Rest test-mode gate-trace + Rest sub-score lines for this day, collected off the main
        /// actor and replayed through `diagnosticSink` tagged `.sleep` in per-day order. Empty unless the
        /// Sleep mode is active (the gate is read once before the loop), so the default path is unchanged.
        let sleepTrace: [String]
        /// Steps test-mode raw-counter trace lines (5/MG cumulative @57 series + wrap-aware deltas + dropped
        /// deltas) for this day, collected off the main actor and replayed tagged `.steps` in per-day order.
        /// Empty unless the Steps mode is active (the gate is read once before the loop), so the default path
        /// is byte-identical: the trace recomputes the SAME wrap-aware sum analyzeDay already computed.
        let stepsTrace: [String]
        /// HRV test-mode nightly trace lines (per-5-min-window RMSSD by sleep stage + the whole-night vs
        /// deep-only vs last-SWS summary) for this day, collected off the main actor and replayed tagged
        /// `.hrv` in per-day order. Empty unless the HRV mode is active. (#141)
        let hrvTrace: [String]
        /// #195: the ALWAYS-ON whole-night HRV cleaning summary (`hrv diag …`), built off the main actor
        /// where `rr` is in scope and replayed through `diagnosticSink` in pass 2 (which is main-actor
        /// isolated). nil when the night has no in-sleep R-R.
        let hrvDiag: String?
        /// #103/queue-11a: the nightly SpO₂ candidate mean for this day, computed off the main actor when
        /// the SpO₂ candidate display toggle is ON. A WHOOP owner gets the `spo2_candidate_82` V18Aux
        /// byte mean (unchanged); an Oura owner gets the ring's ceiling@100 `0x6F` mean
        /// (`AnalyticsEngine.nightlySpo2CeilingMean`, queue 11a). nil when the toggle is OFF or the
        /// night has no in-band reading for its owner's device. Written to metricSeries as
        /// "spo2_candidate" under the "-noop" device ID in pass 2 — same key for both devices, since the
        /// series is always read scoped to one device's own computed ID.
        let spo2Candidate: Int?
        /// #1118: whether this night's in-sleep R-R is OVER-COUNTED (`crossSecondOverCount` /
        /// `sameSecondOverCount`) — the WHOOP-4.0 two-optical-channel artifact that inflates R-R and
        /// contaminates the displayed HRV. nil when the night has no in-sleep R-R (no HRV to caveat).
        /// Persisted to metricSeries as "hrv_rr_overcount" (1/0) in pass 2 so the HRV card can flag the
        /// reading "unverified" until the de-dup fix lands. Same verdict the always-on `hrv diag` logs.
        let hrvOverCounted: Bool?
        /// #1169 SHADOW METRIC: the primary-session MEAN resting HR (PrimarySessionRestingHR, #1174) for this
        /// day, computed off the main actor beside the shipped nightly HR FLOOR (`daily.restingHr`). nil when
        /// no session clears the coverage gate. Written to metricSeries as "rhr_primary_session" in pass 2 —
        /// instrumentation only, never shown and never fed to any score.
        let primarySessionRHR: Double?
        /// #1169 coverage inputs for the shadow mean above (valid-sample count + primary-session duration),
        /// written as "rhr_primary_session_valid_samples" / "rhr_primary_session_duration_s" in pass 2. nil
        /// in lockstep with `primarySessionRHR`.
        let primarySessionRHRCoverage: PrimarySessionRestingHR.Coverage?
    }

    struct Computed: Identifiable {
        let day: String
        let recovery: Double?
        let strain: Double?
        let sleepMin: Double?
        let hrv: Double?
        let rhr: Int?
        /// REAL provenance of the day's dashboard headline (computed vs an import that won the merge), so
        /// the By-Day badge is honest. Defaults to `.computed` (the engine always writes a computed row);
        /// set per day from the imported day-key sets resolved in `analyzeRecent`.
        var source: DaySource = .computed
        /// Charge (recovery) confidence for the day. Defaults `.solid` for a strap-scored night (the gauge
        /// already gates on the HRV baseline being usable); the Apple-Watch fold below sets this to the
        /// `WatchRecovery` confidence so a watch-only recovery reads "calibrating" until it has enough nights.
        var confidence: ScoreConfidence = .solid
        /// SHARED CONTRACT (engine <-> UI): the ordered "what shaped it" Charge driver list, biggest mover
        /// first. One row per term that actually fed the score (`RecoveryScorer.chargeDrivers`); empty when
        /// there is no score (cold-start) or for a non-strap row whose drivers we don't recompute. The UI
        /// renders one row per driver under the Charge ring and gates gracefully when this is empty.
        var drivers: [ChargeDriver] = []
        /// The night's skin temperature expressed as a RELATIVE deviation from the personal baseline
        /// (`RecoveryScorer.skinTempRelative`), or nil when no deviation is available. Surfaced as
        /// "+0.3 C vs your normal" with a relative tier tag; never a fake clinical absolute.
        var skinTempRel: SkinTempRelative? = nil
        var id: String { day }
    }

    /// Optional sink for the per-day scoring diagnostic, fed line-by-line into the SAME shareable strap
    /// log the user already exports (PII-scrubbed by `LiveState.append(log:)`). Defaults to nil so the
    /// engine stays testable with no UI. Each line is a concise, counts-only summary ("sleep day=…
    /// totalSleepMin=… matched=… source=…") so the next bug report ships proof of what was computed per
    /// day, addressing the project's log-failures-not-successes blind spot and the data needed to settle
    /// "Rest repeats across days". (Sleep overhaul §2.5.)
    /// `AppModel` wires it to `live.append(log:domain:)`. Each line is a concise, counts-only summary,
    /// optionally tagged with the TestDomain so the Sleep/Battery emitters land under their profile tag.
    var diagnosticSink: ((String, TestDomain?) -> Void)?

    init(repo: Repository, profile: ProfileStore, deviceId: String) {
        self.repo = repo; self.profile = profile; self.deviceId = deviceId
    }

    // NOTE (#814 union-model follow-up): the engine intentionally has NO `adoptActiveDeviceId`. Its write
    // target (`deviceId + "-noop"`) and imported-baseline read (`hist` under `deviceId`) stay STABLE on the
    // canonical "my-whoop" so a remove+re-add never orphans the computed history. The active strap's raw is
    // still read + scored per day via `resolveDayOwner` (which uses the registry's own active id), and the
    // result lands on the canonical `-noop` sibling; the Repository unions the canonical history with the
    // active strap's live data at read time.

    /// Median of a list (0 when empty) , used to denoise the 7-day resting-HR for Fitness Age.
    static func medianOf(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted(); let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// The per-day RHR floor-vs-mean diagnostic line (#691). NOOP's `floor` is the WHOOP-style resting
    /// HR , the lowest SUSTAINED 5-min in-bed level (SleepStager picks the min 5-min rolling-mean HR per
    /// session, the day takes the .min() across them) , whereas a "sleeping HR" app reports the night MEAN
    /// over the whole asleep span. The mean always sits at-or-above the floor, so NOOP reading lower is BY
    /// DESIGN, not a bug; logging both makes a "NOOP RHR is lower than my other app" report explainable
    /// from the strap log. `inBedBpms` is the bpm of every HR sample inside a matched in-bed session (the
    /// SAME span the floor came from, so the two numbers are directly comparable). Empty in-bed → nightMean
    /// is "nil". Counts/bpm only , no timestamps or PII. Pure so it's unit-tested directly and is the SAME
    /// line `analyzeRecent` ships. Byte-identical to the Android `rhrFloorMeanLogLine`.
    /// #1331 diagnostic line: the night's computed respiratory rate and, when it is missing after the
    /// HRV block ran, whether the RSA beat-accuracy gate refused the R-R input.
    nonisolated static func respRateLogLine(day: String,
                                            respRateBpm: Double?,
                                            beatAccurate: Double? = nil,
                                            rrIntegrity: String? = nil) -> String {
        let base = "resp day=\(day) rpm=\(respRateBpm.map { String(format: "%.1f", $0) } ?? "nil")"
        guard respRateBpm == nil, let beatAccurate else { return base }
        let acc = beatAccurate.isNaN ? "NaN" : String(format: "%.2f", beatAccurate)
        let gate = String(format: "%.2f", HRVAnalyzer.beatAccuracyMinFraction)
        let integrity = rrIntegrity ?? "unknown"
        if beatAccurate < HRVAnalyzer.beatAccuracyMinFraction {
            return "\(base) beatAccurate=\(acc)<\(gate) rrIntegrity=\(integrity) — RSA gate refused the R-R"
        }
        return "\(base) beatAccurate=\(acc)>=\(gate) rrIntegrity=\(integrity) — gate passed, cause is elsewhere"
    }

    nonisolated static func rhrFloorMeanLogLine(day: String, floor: Int, inBedBpms: [Int]) -> String {
        let meanLog: String = inBedBpms.isEmpty ? "nil"
            : String(Int((Double(inBedBpms.reduce(0, +)) / Double(inBedBpms.count)).rounded()))
        return "rhr day=\(day) floor=\(floor) nightMean=\(meanLog) inBedSamples=\(inBedBpms.count) "
            + "(floor = WHOOP-style lowest-sustained = NOOP RHR; mean = sleeping-HR-app number)"
    }

    /// #1244: one line for a day that CLEARED the ≥200-HR gate yet detected NO in-bed session, so the
    /// dashboard shows "HR tracked but no sleep". Today only the summary `sleep day=… totalSleepMin=nil`
    /// rides the log — with no clue WHY, since every other night trace (`rhr`/`rrsample`/`hrv diag`) only
    /// emits once a session exists. This names the raw inputs the stager was handed so the next capture
    /// separates the causes: `grav=0` = no motion offloaded (the in-bed detector can't gate — the WHOOP
    /// 4.0 sparse-motion path has no HR-only fallback); a large `hr` with a night still empty = coverage
    /// gap or the sleep hours fell outside `window`; `provided=` = a persisted hypnogram was (not) available.
    /// The END of the window the sleep pipeline reads for the night that finishes on `dayStart`'s day.
    ///
    /// A PAST day reads through to the next local midnight: the night may end any time before it — late
    /// sleepers, weekend lie-ins, shift workers who wake well after noon. A hard `dayStart + 18h` (6 PM)
    /// bound truncated the read at exactly 18:00 and reported a flat 18:00 wake (#500).
    ///
    /// **#500 follow-up — the half that was left broken.** TODAY kept the 18:00 cap, on the reasoning that
    /// "the store clamps to `now` anyway". That holds only for someone who wakes in the MORNING. A
    /// day-sleeper — asleep ~12:00, awake ~20:00 — is still inside today when they wake, so the cap cut the
    /// read three hours short and reported a flat 18:00 wake for the entire evening. At the next local
    /// midnight the day became PAST, the other branch took over, and the SAME night silently re-scored to
    /// the real time. That is exactly the reported symptom: *"it shows 18:00 every day no matter what time
    /// I wake up, then as soon as it hits 00:01 it updates to the actual wake time."* Not offload lag, not
    /// a stager gate, not clock drift — this bound.
    ///
    /// Today is now capped at `now`, which keeps the only property the old bound was there for — never read
    /// past the present — and is what that original comment already assumed was happening. It stops the
    /// window from asserting that nobody wakes after 6 PM.
    nonisolated static func sleepReadWindowEnd(dayStart: Int, nowLocalMidnight: Int, now: Int) -> Int {
        let nextMidnight = dayStart + 86_400
        return dayStart < nowLocalMidnight ? nextMidnight : min(nextMidnight, now)
    }

    /// Counts + a window length only — same privacy class as the sibling `sleep day=` line, no PII. Pure so
    /// it's unit-tested directly; byte-identical to the Android `sleepDetectNoNightLogLine`.
    nonisolated static func sleepDetectNoNightLogLine(day: String, hrCount: Int, rrCount: Int,
                                                      respCount: Int, gravCount: Int, stepCount: Int,
                                                      providedCount: Int, windowHours: Int) -> String {
        let reason = gravCount == 0 ? "no-motion" : "staged-none"
        return "sleep-detect day=\(day) NO-NIGHT hr=\(hrCount) rr=\(rrCount) resp=\(respCount) "
            + "grav=\(gravCount) steps=\(stepCount) provided=\(providedCount) window=\(windowHours)h "
            + "reason=\(reason)"
    }

    /// #674/#1244: the "sleep total with no matched session" divergence line. A COMPUTED day whose fresh
    /// scoring pass matched ZERO detected sleep sessions yet still carries a non-nil totalSleepMin — the
    /// value comes from a folded edited/hand-logged block (sleepEditedDaily) on a day the detector staged
    /// nothing (often a day absorbed into a neighbour's coupled window, so it never got its own pass). That
    /// total leaks to Today/Coupled while the Sleep tab (session-backed) shows nothing. `editFold` = how
    /// many edited/manual rows folded a total onto this session-less day, so the next capture proves whether
    /// it's an orphaned edit. Counts only, no PII. Pure; byte-identical to the Kotlin `sleepDivergenceLogLine`.
    nonisolated static func sleepDivergenceLogLine(day: String, totalSleepMin: Int, editFold: Int) -> String {
        return "sleep divergence day=\(day) totalSleepMin=\(totalSleepMin) matched=0 editFold=\(editFold)"
    }

    /// #1248: the device ids the banked-sleep heal (#899) must sweep — the computed-scores id AND every
    /// registered device id. A live source (an Oura ring) banks its OWN hypnogram under its OWN device id,
    /// so a computedId-only heal never sees (or collapses) those rows, and they are re-read as
    /// `providedSleep` and re-detected every pass — one night ballooned to 14 stored rows / 9 phantom
    /// "naps". The de-duplicated union, sorted for a deterministic sweep order. Pure so it's unit-tested
    /// directly; byte-identical to the Android `healDeviceIds`.
    nonisolated static func healDeviceIds(computedId: String, registeredIds: [String]) -> [String] {
        Set([computedId] + registeredIds).sorted()
    }

    /// The Saturday on-or-before a "yyyy-MM-dd" local-day string , the weekly key Fitness Age writes to.
    static func saturdayKey(onOrBefore dayStr: String) -> String {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
        let fmt = DateFormatter(); fmt.calendar = cal; fmt.timeZone = cal.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.dateFormat = "yyyy-MM-dd"
        guard let d = fmt.date(from: dayStr) else { return dayStr }
        let back = cal.component(.weekday, from: d) % 7   // Sat(7)→0, Sun(1)→1 … Fri(6)→6
        let sat = cal.date(byAdding: .day, value: -back, to: d) ?? d
        return fmt.string(from: sat)
    }

    /// Assess Fitness Age readiness from `gateDays` (the merged last-7 the readiness card counts) and, when
    /// ready, build the fitness_age (+ optional vo2max) points for `satKey`. Empty when not ready. The
    /// SINGLE source of the gate + compute , shared by the recompute pass and the manual "refresh Fitness
    /// Age" button so the two can never drift. Profile passed as primitives (no cross-actor object read).
    /// Mirrors the Android `IntelligenceEngine.fitnessAgeRows`.
    static func fitnessAgeRows(
        gateDays: [DailyMetric], age: Int, sex: String, waistCm: Double, heightCm: Double, weightKg: Double,
        computedId: String, satKey: String,
    ) -> [MetricPoint] {
        let rhrs = gateDays.compactMap { $0.restingHr }.map(Double.init)
        let strains = gateDays.compactMap { $0.strain }.filter { $0 >= 30 }
        let meanStrain = strains.isEmpty ? 0 : strains.reduce(0, +) / Double(strains.count)
        let waist: Double? = waistCm > 0 ? waistCm : nil
        let ready = FitnessAgeEngine.assessReadiness(
            hasAge: age > 0, hasSex: !sex.isEmpty,
            rhrDays: rhrs.count, activityDays: gateDays.compactMap { $0.strain }.count,
            hasHeightWeight: heightCm > 0 && weightKg > 0, hasWaist: waist != nil)
        guard ready.canCompute,
              let res = FitnessAgeEngine.compute(
                age: Double(age), sex: sex,
                restingHR: medianOf(rhrs),
                paIndex: FitnessAgeEngine.physicalActivityIndexFromStrain(
                    activeDaysPerWeek: strains.count, meanActiveStrain: meanStrain),
                waistCm: waist) else { return [] }
        var rows = [MetricPoint(day: satKey, key: "fitness_age", value: res.fitnessAge)]
        // #1391: offer a VO₂max even without a waist. res.vo2max is the Nes 2011 waist-based estimate (nil
        // when no waist is set). Fall back to the Uth 2004 HR-ratio estimate (15.3·HRmax/RHR — waist-free,
        // the SAME formula the calorie path already uses), so any user past the age+RHR fitness-age gate gets
        // a (rougher) VO₂max instead of a blank. HRmax via the shared Tanaka estimator (no HR history here →
        // age-predicted); RHR = the same median the Nes value used. Both persist under "vo2max_est"; the card
        // labels it "Estimated". Mirrors the Android twin.
        let vo2 = res.vo2max
            ?? Calories.vo2maxFor(hrmax: StrainScorer.estimateHRmax([], age: Double(age)).0, restingHR: medianOf(rhrs))
        if let v = vo2 { rows.append(MetricPoint(day: satKey, key: "vo2max_est", value: v)) }
        return rows
    }

    /// Daily 0–3 stress-proxy points (#R-stress-chart) — the SAME z-score formula `StressView` derives
    /// live when nothing is stored for a day (`StressMath.rawScore`/`.squash` over a rolling RHR/HRV
    /// baseline), computed here so it can be PERSISTED and therefore charted (`plot_metric`'s generic
    /// day-series lookup only finds keys that are actually in the store — "stress" never was). `days` must
    /// be oldest→newest; the baseline for each day is up to the 30 days ending the day BEFORE it, the exact
    /// window `StressModel.init` uses, so a plotted chart and the live Stress screen never disagree. A day
    /// with neither a resting HR nor an HRV reading (and no baseline to fall back on either) is skipped —
    /// no fabricated value.
    nonisolated static func stressProxyRows(days: [DailyMetric]) -> [MetricPoint] {
        var rows: [MetricPoint] = []
        for (idx, today) in days.enumerated() {
            let baseline = idx > 0 ? Array(days[0..<idx].suffix(30)) : []
            let rhrBase = baseline.compactMap { $0.restingHr }.map(Double.init)
            let hrvBase = baseline.compactMap { $0.avgHrv }
            let meanRHR = StressMath.mean(rhrBase)
            let sdRHR = StressMath.std(rhrBase, mean: meanRHR)
            let meanHRV = StressMath.mean(hrvBase)
            let sdHRV = StressMath.std(hrvBase, mean: meanHRV)
            let rhrToday = today.restingHr.map(Double.init)
            let hrvToday = today.avgHrv
            guard (rhrToday != nil && meanRHR != nil) || (hrvToday != nil && meanHRV != nil) else { continue }
            let raw = StressMath.rawScore(rhrToday: rhrToday, meanRHR: meanRHR, sdRHR: sdRHR,
                                          hrvToday: hrvToday, meanHRV: meanHRV, sdHRV: sdHRV)
            rows.append(MetricPoint(day: today.day, key: "stress", value: StressMath.squash(raw)))
        }
        return rows
    }

    /// Estimator provenance captured with a newly computed VO₂max point.
    static func vo2MaxProvenance(
        points: [MetricPoint], waistCm: Double
    ) -> [ScoreInputProvenanceRow] {
        guard let point = points.first(where: { $0.key == "vo2max_est" }) else { return [] }
        return [ScoreInputProvenanceRow(
            day: point.day,
            key: point.key,
            sourceId: Vo2MaxEstimator.forWaistCm(waistCm).rawValue
        )]
    }

    /// Manual "refresh Fitness Age" (the button on the not-ready card): recompute the weekly Fitness Age NOW
    /// from the PERSISTED merged daily history , NO raw-HR rescoring , and upsert it. Same gate
    /// (`fitnessAgeRows`) + date/window logic as the recompute pass, so it reads exactly what the readiness
    /// card shows. Light + works offline (stored data only). Returns true if a value was written. Mirrors
    /// the Android `recomputeFitnessAgeOnly`.
    func recomputeFitnessAgeOnly(maxDays: Int = 21) async -> Bool {
        guard let store = await repo.storeHandle() else { return false }
        let computedId = deviceId + "-noop"
        let now = Int(Date().timeIntervalSince1970)
        let tzOffset = TimeZone.current.secondsFromGMT()
        let nowLocalMidnight = Self.midnightLocal(now, offsetSec: tzOffset)
        let newestDay = AnalyticsEngine.dayString(nowLocalMidnight, offsetSec: tzOffset)
        let oldestDay = AnalyticsEngine.dayString(nowLocalMidnight - (maxDays - 1) * 86_400, offsetSec: tzOffset)
        let gate7 = Array((await repo.dailyMetrics(fromDay: oldestDay, toDay: newestDay))
            .sorted { $0.day < $1.day }.suffix(7))
        let rows = Self.fitnessAgeRows(
            gateDays: gate7, age: profile.age, sex: profile.sex, waistCm: profile.waistCm,
            heightCm: profile.heightCm, weightKg: profile.weightKg, computedId: computedId,
            satKey: Self.saturdayKey(onOrBefore: newestDay))
        if !rows.isEmpty {
            try? await store.persistMetricSeriesWithProvenance(
                points: rows,
                provenance: Self.vo2MaxProvenance(points: rows, waistCm: profile.waistCm),
                deviceId: computedId
            )
        }
        return !rows.isEmpty
    }

    /// UserDefaults flag guarding the one-shot #313 full-history Effort rescore (below). Set once the
    /// pass completes so it never re-runs.
    static let effortRescoreFlagKey = "intelligence.effortRescore.v313.done"
    static let effortRescoreCursorKey = "intelligence.effortRescore.v313.cursor"

    /// Anchor or migrate the persisted analytics recipe. A database with no cursor predates this
    /// coordinator; its existing scores are accepted as the baseline so shipping the coordinator itself
    /// does not create the very launch-time 21-day pass it is designed to remove.
    @discardableResult
    func prepareAnalysisRecipe() async -> Bool {
        guard let store = await repo.storeHandle() else { return false }
        analysisMaintenancePhase = .checking
        do {
            let stored = try await store.cursor(Self.analysisRecipeCursor)
            switch Self.analysisRecipeDecision(storedVersion: stored) {
            case .anchorCurrent:
                try await store.setCursor(Self.analysisRecipeCursor, Self.currentAnalysisRecipeVersion)
                analysisRecipeVersion = Self.currentAnalysisRecipeVersion
                analysisMaintenancePhase = .idle
                return true
            case .upToDate:
                analysisRecipeVersion = stored ?? Self.currentAnalysisRecipeVersion
                analysisMaintenancePhase = .idle
                return true
            case .migrate(let from, let to):
                analysisRecipeVersion = from
                return await runAnalysisMaintenance(
                    phase: .migrating(from: from, to: to),
                    markRecipeOnSuccess: true)
            }
        } catch {
            analysisMaintenancePhase = .failed(error.localizedDescription)
            return false
        }
    }

    /// Explicit user action from Settings. It recomputes derived rows only; raw samples and user edits
    /// remain authoritative inputs. It intentionally does not advance the recipe cursor unless a pending
    /// migration is being fulfilled by the same run.
    @discardableResult
    func manuallyReanalyzeRecent() async -> Bool {
        guard let store = await repo.storeHandle() else { return false }
        let stored = (try? await store.cursor(Self.analysisRecipeCursor))
            ?? Self.currentAnalysisRecipeVersion
        let owesMigration = stored < Self.currentAnalysisRecipeVersion
        let phase: AnalysisMaintenancePhase = owesMigration
            ? .migrating(from: stored, to: Self.currentAnalysisRecipeVersion)
            : .manualRecent
        return await runAnalysisMaintenance(phase: phase, markRecipeOnSuccess: owesMigration)
    }

    @discardableResult
    func manuallyRefreshCurrentDayActivity() async -> Bool {
        guard analysisMaintenanceTask == nil else { return false }
        analysisMaintenancePhase = .refreshingToday
        let ok = await refreshCurrentDayActivity()
        let finished = Date()
        if ok {
            UserDefaults.standard.set(finished.timeIntervalSince1970, forKey: Self.analysisLastRunKey)
            analysisMaintenancePhase = .completed(finished)
        } else {
            analysisMaintenancePhase = .failed(String(localized: "No current-day activity data was available."))
        }
        return ok
    }

    private func runAnalysisMaintenance(phase: AnalysisMaintenancePhase,
                                        markRecipeOnSuccess: Bool) async -> Bool {
        if let analysisMaintenanceTask { return await analysisMaintenanceTask.value }
        analysisMaintenancePhase = phase
        let task = Task { @MainActor [weak self] in
            guard let self, let store = await self.repo.storeHandle() else { return false }
            await self.analyzeRecent(maxDays: 21, force: true, allowDayReuse: false,
                                     reason: .semanticChange)
            guard !Task.isCancelled else { return false }
            if markRecipeOnSuccess {
                do {
                    try await store.setCursor(Self.analysisRecipeCursor,
                                              Self.currentAnalysisRecipeVersion)
                    self.analysisRecipeVersion = Self.currentAnalysisRecipeVersion
                } catch {
                    self.analysisMaintenancePhase = .failed(error.localizedDescription)
                    return false
                }
            }
            await self.repo.refresh(days: 120)
            let finished = Date()
            UserDefaults.standard.set(finished.timeIntervalSince1970,
                                      forKey: Self.analysisLastRunKey)
            self.analysisMaintenancePhase = .completed(finished)
            return true
        }
        analysisMaintenanceTask = task
        let ok = await task.value
        analysisMaintenanceTask = nil
        if !ok, case .failed = analysisMaintenancePhase { return false }
        if !ok { analysisMaintenancePhase = .failed(String(localized: "The reanalysis did not finish.")) }
        return ok
    }

    /// Refresh only today's Effort and strap-step estimate from today's raw streams.
    ///
    /// The complete `analyzeRecent` pipeline remains authoritative for sleep, Charge, Rest, workouts,
    /// energy, and history. This deliberately narrow companion exists so a completed offload or workout
    /// can update the two activity values immediately instead of waiting behind a multi-day sleep pass.
    /// The store write is field-scoped, therefore an edited night's repaired sleep fields cannot be
    /// overwritten by this refresh.
    @discardableResult
    func refreshCurrentDayActivity(now: Date = Date()) async -> Bool {
        if let currentDayActivityRefreshTask {
            return await currentDayActivityRefreshTask.value
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return false }
            return await self.performCurrentDayActivityRefresh(now: now)
        }
        currentDayActivityRefreshTask = task
        let updated = await task.value
        currentDayActivityRefreshTask = nil
        return updated
    }

    private func performCurrentDayActivityRefresh(now: Date) async -> Bool {
        guard let store = await repo.storeHandle() else { return false }

        let nowTs = Int(now.timeIntervalSince1970)
        let offset = TimeZone.current.secondsFromGMT(for: now)
        let dayStart = Self.midnightLocal(nowTs, offsetSec: offset)
        let dayEnd = min(nowTs, dayStart + 86_400 - 1)
        guard dayEnd >= dayStart else { return false }
        let day = AnalyticsEngine.dayString(nowTs, offsetSec: offset)
        let computedId = deviceId + "-noop"

        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let devices = (try? registry.all()) ?? []
        let activeId = (try? registry.activeDeviceId()) ?? deviceId
        let owner = await Self.resolveDayOwner(
            day: day, from: dayStart, to: dayEnd, store: store, devices: devices,
            activeId: activeId, registry: registry, fallbackDeviceId: deviceId)

        async let hrRead = try? store.hrSamples(
            deviceId: owner, from: dayStart, to: dayEnd, limit: Int.max)
        async let stepRead = try? store.stepSamples(
            deviceId: owner, from: dayStart, to: dayEnd, limit: Int.max)
        async let existingRead = try? store.dailyMetrics(
            deviceId: computedId, from: day, to: day)
        let (hrOptional, stepOptional, existingOptional) = await (hrRead, stepRead, existingRead)
        let hr = hrOptional ?? []
        let stepSamples = stepOptional ?? []
        let existing = existingOptional?.first

        let maxHR = profile.hrMaxOverride > 0
            ? Double(profile.hrMaxOverride)
            : (profile.age > 0 ? StrainScorer.tanakaHRmax(age: Double(profile.age)) : nil)
        let restingHR = existing?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
        let effortMethod = PuffinExperiment.effortMethod
        let sex = profile.sex
        let ticksPerStep = profile.stepTicksPerStep

        let activity = await Task.detached(priority: .userInitiated) {
            let strain = StrainScorer.strain(
                hr, maxHR: maxHR, restingHR: restingHR, method: effortMethod, sex: sex)
            let steps: Int? = {
                guard let ticks = StepsCounter.stepsInWindow(stepSamples) else { return nil }
                let value = Int((Double(ticks) / max(ticksPerStep, 0.5)).rounded())
                return value > 0 ? value : nil
            }()
            return (strain: strain, steps: steps)
        }.value

        do {
            _ = try await store.upsertDailyActivity(
                day: day, strain: activity.strain, steps: activity.steps, deviceId: computedId)
            await repo.refresh()
            let strainLog = activity.strain.map { String(format: "%.1f", $0) } ?? "nil"
            let stepsLog = activity.steps.map(String.init) ?? "nil"
            diagnosticSink?(
                "activity refresh day=\(day) owner=\(owner) hr=\(hr.count) stepsRaw=\(stepSamples.count) "
                    + "effort=\(strainLog) steps=\(stepsLog)",
                nil)
            return activity.strain != nil || activity.steps != nil
        } catch {
            diagnosticSink?("activity refresh failed day=\(day): \(error.localizedDescription)", nil)
            return false
        }
    }

    /// Resumable, on-upgrade Effort-only rescore (#313 PART B). The Effort hero gauge + numbers
    /// moved from the old 0–21 axis to NOOP's own 0–100 axis. On-device computed rows since v2.6.1
    /// already store 0–100, but rows the engine computed on an OLDER build (capped at `maxDays` per run,
    /// so deep history was never revisited) may still hold 0–21 strain.
    ///
    /// The SAFE fix is to recompute strain FROM SOURCE for every day with raw HR — those regenerate at
    /// 0–100 with NO double-rescale risk , rather than a blind `strain*21→100` multiply that would
    /// double-rescale the large population already on 0–100 (→ ~0–476). We do that by running the normal
    /// the complete sleep/recovery pipeline. Each call handles a small newest-first batch, records the
    /// oldest completed day, and can resume after termination. IMPORTED rows are never rewritten.
    /// Returns true once no computed rows remain.
    @discardableResult
    func runEffortRescoreIfNeeded(batchSize: Int = 7) async -> Bool {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.effortRescoreFlagKey) { return true }
        guard let store = await repo.storeHandle() else { return false }

        let computedId = deviceId + "-noop"
        let cursor = defaults.string(forKey: Self.effortRescoreCursorKey) ?? "9999-12-31"
        let batch = (try? await store.dailyMetrics(deviceId: computedId,
                                                    before: cursor,
                                                    limit: max(1, batchSize))) ?? []
        guard !batch.isEmpty else {
            defaults.set(true, forKey: Self.effortRescoreFlagKey)
            defaults.removeObject(forKey: Self.effortRescoreCursorKey)
            return true
        }

        let offset = TimeZone.current.secondsFromGMT()
        let age = profile.age
        let sex = profile.sex
        let maxHR = profile.hrMaxOverride > 0
            ? Double(profile.hrMaxOverride)
            : (age > 0 ? StrainScorer.tanakaHRmax(age: Double(age)) : nil)
        let fallbackId = deviceId
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let devices = (try? registry.all()) ?? []
        let activeId = (try? registry.activeDeviceId()) ?? fallbackId

        let updates: [(day: String, strain: Double?)] = await Task.detached(priority: .utility) {
            var result: [(day: String, strain: Double?)] = []
            result.reserveCapacity(batch.count)
            for row in batch {
                await Task.yield()
                guard let dayStart = Self.midnightForDayKey(row.day, offsetSec: offset) else {
                    result.append((row.day, nil)); continue
                }
                let owner = await Self.resolveDayOwner(
                    day: row.day, from: dayStart - 30 * 3_600, to: dayStart + 86_400,
                    store: store, devices: devices, activeId: activeId, registry: registry,
                    fallbackDeviceId: fallbackId)
                let hr = (try? await store.hrSamples(deviceId: owner, from: dayStart,
                                                     to: dayStart + 86_400 - 1,
                                                     limit: Int.max)) ?? []
                let resting = row.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
                let strain = StrainScorer.strain(hr, maxHR: maxHR, restingHR: resting, sex: sex)
                result.append((row.day, strain))
            }
            return result
        }.value

        do {
            _ = try await store.updateDailyStrains(updates, deviceId: computedId)
            defaults.set(batch.last!.day, forKey: Self.effortRescoreCursorKey)
            if batch.count < max(1, batchSize) {
                defaults.set(true, forKey: Self.effortRescoreFlagKey)
                defaults.removeObject(forKey: Self.effortRescoreCursorKey)
                return true
            }
            return false
        } catch {
            return false
        }
    }

    /// UserDefaults flag guarding the one-shot #547 implausible-timestamp DB heal (below). Set once the
    /// heal completes so it never re-runs.
    static let timestampHealFlagKey = "intelligence.timestampHeal.v547.done"

    /// #547 RE-POLLUTION re-arm: a one-shot heal isn't enough when a strap with a WANDERING clock keeps
    /// re-sending bad-dated records across syncs. Whenever a sync's ingest gate drops implausible records
    /// (the strap demonstrably has a bad clock THIS session), `BLEManager` sets this pending flag so the
    /// next analyze tick re-runs the purge , clearing any pollution that slipped in on an OLDER build whose
    /// gate was weaker, rather than permanently gating behind the one-shot `done` flag. Cleared once the
    /// re-heal runs. Pure UserDefaults so the BLE layer can set it without an engine reference.
    static let timestampHealPendingKey = "intelligence.timestampHeal.v547.pending"

    /// Mark the #547 heal as needing a re-run because a sync just dropped implausible (bad-clock) records.
    /// Called from `BLEManager.exitBackfilling` (no engine handle there); the next `runTimestampHealIfNeeded`
    /// honours it even after the one-shot `done` flag is set.
    static func requestTimestampReheal() {
        UserDefaults.standard.set(true, forKey: timestampHealPendingKey)
    }

    /// One-shot, on-upgrade heal of a database polluted by a bad-clock strap (#547, pikapik). The ingest
    /// gate now keeps garbage-timestamped records out, but a user who synced on an older build already has
    /// rows dated to scattered garbage (far-past, a bogus 2027, FUTURE dates) , which made one ~12h block
    /// re-attribute to every day (the repeated totalSleepMin=721 across many days) and a future row surface
    /// as the Today "last night" carry-over. This purges those rows ONCE, then rescores from the surviving
    /// real raw data so the genuine days recompute cleanly. Idempotent (a clean DB deletes nothing) and
    /// re-running is harmless, but a persisted flag skips it on every later launch. Runs BEFORE the normal
    /// `analyzeRecent` loop so the rescore it triggers operates on an already-cleaned DB.
    func runTimestampHealIfNeeded(historyDays: Int = 21) async {
        // Run when the one-shot heal hasn't run yet OR a sync just flagged a re-heal (#547 re-pollution): a
        // wandering-clock strap re-sends bad-dated records across syncs, so a single on-upgrade pass can't
        // be the only line of defence. The pending flag is cleared below once the re-heal completes.
        let pending = UserDefaults.standard.bool(forKey: Self.timestampHealPendingKey)
        guard pending || !UserDefaults.standard.bool(forKey: Self.timestampHealFlagKey) else { return }
        guard let store = await repo.storeHandle() else { return }   // no store yet → retry next launch
        let result: WhoopStore.TimestampHealResult
        do {
            result = try await store.healImplausibleTimestamps()
        } catch {
            NSLog("IntelligenceEngine: timestamp heal (#547) FAILED , \(error); will retry next launch")
            return   // leave the flag unset so a transient failure retries
        }
        NSLog("[FREEZE-DIAG] runTimestampHealIfNeeded: didChange=\(result.didChange) rawDeleted=\(result.rawRowsDeleted) computedDeleted=\(result.computedRowsDeleted) (pending=\(pending))")
        if result.didChange {
            NSLog("[FREEZE-DIAG] runTimestampHealIfNeeded: scheduling bounded repair rescore (maxDays=\(historyDays))")
            diagnosticSink?("Heal(#547): purged \(result.rawRowsDeleted) raw + \(result.computedRowsDeleted) computed row(s) with implausible (bad-clock) timestamps; rescoring the real days.", nil)
            // Recompute the affected real days from the surviving raw rows so the polluted (e.g. 721)
            // blocks regenerate cleanly. The dashboard refresh happens inside analyzeRecent on persist.
            await analyzeRecent(maxDays: historyDays, reason: .timestampHeal,
                                affectedUTCInterval: result.affectedUTCInterval)
        }
        UserDefaults.standard.set(true, forKey: Self.timestampHealFlagKey)
        // Clear the re-pollution request now that this re-heal has run , a future bad-clock sync re-arms it.
        UserDefaults.standard.set(false, forKey: Self.timestampHealPendingKey)
    }

    /// Compute on-device scores for each of the last `maxDays` that actually has raw HR data.
    /// Personal baselines (HRV / resting HR) are folded from the imported history, so even the first
    /// live night can be scored against your norm.
    /// `allowDayReuse` — may this pass skip days whose raw inputs have not moved (#launch-rescore)?
    ///
    /// DELIBERATELY NOT `!force`. The two answer different questions, and conflating them gets one of
    /// them wrong: `force` says "run even if the whole-history watermark is unchanged", while this says
    /// "the change you are reacting to is one the per-day fingerprint can SEE". A completed offload is
    /// both — forced, and a pure raw-data change — so tying reuse to `!force` left every strap sync
    /// re-deriving all 21 days, which is most of the cost on a real install.
    ///
    /// Pass `true` only where the change is raw-data-shaped: a completed offload (new samples land under
    /// a device id, in specific days) and an active-device re-point (the owner is part of the
    /// fingerprint). Leave it `false` — the default, so an unaware future caller lands on the safe side —
    /// wherever the change is INVISIBLE in the raw streams: a sleep or workout edit, an import, a
    /// baseline recalibrate, an HRV/stager settings flip, the timestamp heal, the one-shot Effort
    /// rescore, and the manual "recompute" button (a user asking for a recompute should get one).
    /// Whether a pass may skip days whose persisted fingerprint still matches, unless the caller says
    /// otherwise. TRUE — reuse is the default, and refusing it is the thing that must be stated.
    ///
    /// It was false, which made the whole `dayScanFingerprint` / `analysisInputRevision` mechanism
    /// (v38–v40) unreachable from all but two of eleven call sites. Measured on a real 2.8 GB library:
    /// `day-skip: scanned=21 reused=0 of 21`, 2261 s per pass — while 15 of the last 17 days had a stored
    /// `inputRevision` byte-identical to the current one and would every one of them have been reused.
    /// A pass that long cannot drain its own queue: triggers arrive every few minutes, so the next request
    /// is always already waiting, and `runAnalysisQueue` starts the next full re-derivation 47 ms after
    /// finishing the last one. The app analyses continuously and never finishes.
    ///
    /// Upstream does not have this problem because its in-memory `AnalyzeRecentDayCache` (#1005) is
    /// UNCONDITIONAL. This fork replaced it with something better — persisted, survives relaunch,
    /// invalidated by the write side rather than a session key — and then put it behind an opt-in
    /// nobody opted into.
    ///
    /// Safe as a default because the fingerprint sees every mutation that can change a day's score:
    /// raw ingest (`StreamStore.insert`), sleep edits (`applySleepEdit` / `applySleepGroupEdit` /
    /// `deleteSleepSession`), the timestamp heal, a device wipe or re-point (`markAnalysisDeviceChanged`),
    /// and — through `semanticSignature` — every scoring toggle, profile field and baseline epoch.
    ///
    /// The ONE thing it cannot see is a workout mutation: `upsertWorkouts` / `deleteWorkouts` deliberately
    /// do not mark their days, because the analysis pass itself deletes and re-inserts detected workouts
    /// in the window it just scored — marking there would have every pass invalidate its own output and
    /// destroy reuse permanently. So the workout-edit callers pass `false` explicitly; see `WorkoutsView`.
    /// Which `semanticSignature` FIELDS differ between a stored fingerprint and the current pass, as
    /// "key: stored → current" strings. Empty when the two are equal or either side is unparseable.
    ///
    /// D1 named `semanticSignature` as the condition that invalidates all 21 days at once, which is one
    /// question deeper than "the cache missed" but still one short of actionable: the signature folds
    /// twelve values (profile fields, unit toggles, baseline epochs), and knowing WHICH of them moved
    /// between two passes 11 ms apart is the difference between a stale profile write and a genuine
    /// settings change. Pure so the parsing is unit-testable; the format is built right above.
    nonisolated static func semanticSignatureDiff(stored: String, current: String) -> [String] {
        func fields(_ s: String) -> [String: String] {
            var out: [String: String] = [:]
            for part in s.split(separator: "|") {
                guard let eq = part.firstIndex(of: "=") else { continue }
                out[String(part[part.startIndex..<eq])] = String(part[part.index(after: eq)...])
            }
            return out
        }
        let a = fields(stored), b = fields(current)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        return Set(a.keys).union(b.keys).sorted().compactMap { key in
            let old = a[key] ?? "<absent>", new = b[key] ?? "<absent>"
            return old == new ? nil : "\(key): \(old) → \(new)"
        }
    }

    /// The body mass to score each day with: the wearer's weight AS OF that day, resolved causally from
    /// the weigh-in history, falling back to the current profile value for days no observation reaches.
    ///
    /// Weight used to enter the pass as ONE number applied to the whole window, folded into the
    /// pass-global `semanticSignature`. Two consequences, and the second is why this exists:
    ///
    ///  • Historical calories were rewritten by a future weigh-in. `EnergySeries` had already rejected
    ///    that — "using today's profile weight for history leaks future information backwards and can
    ///    rewrite old calorie totals after a new weigh-in" — and resolves per day. The day scan was the
    ///    last place still doing it the old way.
    ///  • Because the number was pass-global, every Health weigh-in invalidated ALL 21 days at once.
    ///    Measured on a real device: `miss: semanticSignature=21`, with the field diff naming
    ///    `weight: 211.0 → 209.55` — one morning weigh-in, synced from Health, costing a full
    ///    re-derivation of three weeks of sleep staging that weight cannot influence at all. (It reaches
    ///    exactly two persisted values: the day's `activeKcalEst` and the kcal of already-detected
    ///    workouts. Not staging, HRV, Rest, Charge or Effort, and not WHICH workouts are found.)
    ///
    /// `CausalWeightResolver` only ever consults observations at or before the instant asked for, so a
    /// weigh-in today cannot move any earlier day's value — that property is what makes the per-day
    /// signature stable, and it is pinned by test.
    ///
    /// The resolution instant matches `EnergySeries` exactly (day noon + 12 h, i.e. the day's end). Not
    /// cosmetic: a different instant here would score a day against a different weight than the energy
    /// series shows for it, which is the drift this whole change is closing.
    nonisolated static func weightByDay(days: [String], observations: [CausalWeightObservation],
                                        fallbackKg: Double,
                                        calendar: Calendar = .current) -> [String: Double] {
        var out: [String: Double] = [:]
        for day in days {
            let resolved = WeightSeries.date(forDay: day).flatMap {
                CausalWeightResolver.weight(at: Int($0.timeIntervalSince1970 + 43_200),
                                            observations: observations, calendar: calendar)
            }
            out[day] = resolved ?? fallbackKg
        }
        return out
    }

    static let dayReuseDefault = true

    /// Metric-series keys for the cached per-day motion volume the WHOOP-4 steps calibration fits on, and
    /// the two revisions it was folded against.
    ///
    /// Stored beside the `steps_est` the same block writes, under the same computed id and the same
    /// `MetricPoint` mechanism, so this needs no schema of its own. Three rows per day for a 60-day window
    /// replace an unbounded gravity read per day — measured at 28.93 s of a 31.83 s post-loop phase, on
    /// every pass, for a value that only moves when that day's raw does.
    ///
    /// The revisions are the cache key, not a timestamp: `analysisInputRevision` already records exactly
    /// when a day's streams changed, and reusing it means this cache can never be staler than the per-day
    /// scan reuse built on the same signal. Both halves are kept — `deviceRevision` is what a wipe or a
    /// re-point moves, and ignoring it would serve a volume folded from a stream that has since re-homed.
    static let stepsMotionKey = "steps_motion"
    static let stepsMotionInputRevKey = "steps_motion_input_rev"
    static let stepsMotionDeviceRevKey = "steps_motion_device_rev"

    func analyzeRecent(maxDays: Int = 21, force: Bool = true, skipIfUnchanged: Bool = false,
                       allowDayReuse: Bool = IntelligenceEngine.dayReuseDefault,
                       reason: AnalysisReason = .semanticChange,
                       affectedUTCInterval: Range<Int>? = nil) async {
        await withCheckedContinuation { waiter in
            if pendingAnalysis != nil {
                pendingAnalysis!.merge(maxDays: maxDays, force: force,
                                       skipIfUnchanged: skipIfUnchanged,
                                       allowDayReuse: allowDayReuse, reason: reason,
                                       affectedUTCInterval: affectedUTCInterval, waiter: waiter)
            } else {
                pendingAnalysis = PendingAnalysis(
                    maxDays: maxDays, force: force,
                    skipIfUnchanged: skipIfUnchanged, allowDayReuse: allowDayReuse,
                    reason: reason,
                    affectedLower: affectedUTCInterval?.lowerBound,
                    affectedUpper: affectedUTCInterval?.upperBound,
                    waiters: [waiter])
            }
            guard !analysisRunnerActive else { return }
            analysisRunnerActive = true
            Task { await self.runAnalysisQueue() }
        }
    }

    private func runAnalysisQueue() async {
        while let request = pendingAnalysis {
            pendingAnalysis = nil
            computing = true
            await performAnalyzeRecent(maxDays: request.maxDays, force: request.force,
                                       skipIfUnchanged: request.skipIfUnchanged,
                                       allowDayReuse: request.allowDayReuse,
                                       reason: request.reason,
                                       affectedUTCInterval: {
                                           guard let lower = request.affectedLower,
                                                 let upper = request.affectedUpper,
                                                 lower < upper else { return nil }
                                           return lower..<upper
                                       }())
            computing = false
            request.waiters.forEach { $0.resume() }
        }
        analysisRunnerActive = false
    }

    /// Queue an engine-internal corrective pass without detaching an untracked Task. The active queue
    /// consumes it after the current generation and retains the same conservative merge rules.
    private func enqueueFollowup(maxDays: Int, reason: AnalysisReason) {
        if pendingAnalysis != nil {
            pendingAnalysis!.merge(maxDays: maxDays, force: true,
                                   skipIfUnchanged: false, allowDayReuse: false,
                                   reason: reason, affectedUTCInterval: nil)
        } else {
            pendingAnalysis = PendingAnalysis(maxDays: maxDays, force: true,
                                              skipIfUnchanged: false, allowDayReuse: false,
                                              reason: reason, affectedLower: nil, affectedUpper: nil,
                                              waiters: [])
        }
    }

    private func performAnalyzeRecent(maxDays: Int, force: Bool, skipIfUnchanged: Bool,
                                      allowDayReuse: Bool, reason: AnalysisReason,
                                      affectedUTCInterval: Range<Int>?) async {
        // TEMP DIAGNOSTIC (#freeze-investigation) — remove once the Goal & Journey freeze is understood.
        // Logs WHO calls this, with WHAT window, and how long the pass takes, so a UI freeze can be tied
        // to a concrete caller + workload instead of guessed at from a paused stack.
        let diagStart = Date()
        let diagCaller = Thread.callStackSymbols.dropFirst().prefix(6).joined(separator: " <- ")
        // `allowDayReuse` and `skipIfUnchanged` decide whether this pass may skip days it has already
        // scored — the difference between a few seconds and, on a deep library, tens of minutes. They were
        // missing from this line, so a log showing a full re-derivation could not say WHETHER reuse had
        // been refused by the caller or attempted and missed. That is the gap the async `caller:` stack
        // cannot close: it unwinds into concurrency trampolines, not into the call site.
        NSLog("[FREEZE-DIAG] analyzeRecent ENTER maxDays=\(maxDays) force=\(force) "
            + "allowDayReuse=\(allowDayReuse) skipIfUnchanged=\(skipIfUnchanged) reason=\(reason) "
            + "computing=\(computing)\n  caller: \(diagCaller)")
        defer {
            NSLog("[FREEZE-DIAG] analyzeRecent EXIT maxDays=\(maxDays) force=\(force) took=\(String(format: "%.2f", Date().timeIntervalSince(diagStart)))s")
        }
        // Progress starts the moment the pass does and is cleared on EVERY exit — including the early
        // `return`s below (no store, missing metric config) and a thrown error. A progress card left on
        // screen by a pass that already gave up would be the same lie as the spinner it replaces.
        let progressStartedAt = Date()
        analysisProgress = AnalysisProgress(stage: .preparing, completedDays: 0, totalDays: maxDays,
                                            startedAt: progressStartedAt, lastStepAt: progressStartedAt)
        defer { analysisProgress = nil }
        // #899-A: a concurrent pass already holds the lock. A NON-forced idle tick is safe to drop (the
        // in-flight pass already covers the same window). But a FORCED call is a real update path (a
        // post-backfill rescore after a sync) , dropping it would leave a freshly-synced night unscored
        // until the next cycle. Re-arm instead: flag it so the running pass's `defer` re-invokes once.
        guard let store = await repo.storeHandle() else { note = String(localized: "No on-device store yet."); return }
        guard let hrvCfg = Baselines.metricCfg["hrv"],
              let rhrCfg = Baselines.metricCfg["resting_hr"],
              let respCfg = Baselines.metricCfg["resp"],
              let skinCfg = Baselines.metricCfg["skin_temp"] else { return }

        // #836 (idle-tick gate): re-scoring a 21-day window re-reads ~21×54 h of raw HR and re-runs
        // analyzeDay over it. After a big Apple Health import (a reporter's: 2.1 M rows, ~190 k HR/day) that
        // is multi-second, memory-heavy work, and the 15-minute steady-state tick (AppModel) repeats it
        // every tick even when NOTHING new landed — the ongoing lag/crash in #836. A cheap whole-history HR
        // fingerprint (count+maxTs, indexed, no rows materialized) lets a NON-forced caller short-circuit
        // when the raw stream is byte-for-byte unchanged since the last successful run. All-or-nothing: it
        // never produces a PARTIAL pass, so the window-wide reconciliation (stale-day eviction, detected-
        // workout delete) is untouched and no computed history is dropped. Every real update path (sync
        // backfill, import, sleep/workout edit, baseline recalibrate, timestamp heal) calls with the default
        // `force: true` and always rescores, so a skipped tick can never hide new data.
        // The gate's change-detector, in its third form. Two things went wrong before it:
        //
        //  1. `hrFingerprint(deviceId:)` was scoped to ONE source, and `deviceId` here is the canonical
        //     "my-whoop" constant handed over at init and never re-pointed, while the WRITE side follows
        //     the device registry. On any install whose active device is a real strap the fingerprint
        //     FROZE while data kept arriving (observed: a `maxTs` four weeks stale in the very pass that
        //     read 101k HR samples for TODAY), so the gate said "nothing changed" forever and the
        //     re-score it guards silently stopped running.
        //  2. `syncedRowCount()` fixed the blindness by counting every sensor-input table instead — but
        //     it answers "did anything change" by walking 15.3 M rows / 1.7 GB, measured at 11 s per call
        //     on a real library, and it runs HERE, above every gate, so even an idle tick that then
        //     short-circuits and does no work at all pays it in full.
        //
        // `sensorWriteSeq()` is one indexed row. It is bumped inside the transaction of every sensor
        // mutation in the app (ingest, timestamp heal, per-device delete, serial re-point), and it is
        // MONOTONE, so unlike a row count it cannot return to an earlier value after a delete-then-
        // resync and go blind the way (1) did. See `WhoopStore.bumpSensorWriteSeq`.
        let diagFpStart = Date()
        let wmKey: String = (try? await store.sensorWriteSeq()).map(String.init) ?? ""
        let storedWatermark = UserDefaults.standard.string(forKey: Self.analyzeWatermarkKey)
        NSLog("[FREEZE-DIAG] sensorWriteSeq took=\(String(format: "%.3f", Date().timeIntervalSince(diagFpStart)))s key=\(wmKey)")
        // (The hrSample partition census lives in `AppModel`'s launch sequence, not here: this function is
        // reached only after the launch waits, so a census here never appeared on a slow launch.)
        if !force, !wmKey.isEmpty,
           storedWatermark == wmKey {
            NSLog("[FREEZE-DIAG] analyzeRecent SHORT-CIRCUIT (unchanged fingerprint) — no work done")
            return
        }
        // #1196/#1146: a FORCED post-offload pass can opt into the same fingerprint gate. An empty/duplicate
        // offload (fingerprint already == the watermark the last successful run advanced) has no new HR to
        // score, so a re-score would reproduce IDENTICAL rows; skip the whole pass rather than churn the
        // window. Over a flapping-link offload storm that churn made the reactive Trends/streak reads
        // flicker between full and empty — a scare that looked like data loss (#1196). Scoped via
        // `skipIfUnchanged` to the post-offload caller (refreshAfterCompletedBackfill) ONLY, so an
        // import/edit/settings/recalibrate re-score — which changes scores WITHOUT changing the HR
        // fingerprint — always runs. Twin of the Android WhoopBleClient post-offload `newData` gate.
        if force, skipIfUnchanged, !wmKey.isEmpty, storedWatermark == wmKey {
            diagnosticSink?("re-score: trigger=post-offload newData=no — skipped (nothing changed since last run)", nil)
            return
        }
        // Attribute the re-score that is ABOUT TO RUN. `trigger=post-offload` was previously logged only on
        // the SKIP path above, so a post-offload pass that actually RAN was labelled `forced` — in the strap
        // log it was indistinguishable from a settings edit or a recalibrate. #1538 lost three nights to
        // that: every one of the reporter's stalled background passes read `trigger=forced`, which pointed
        // the investigation at the wrong caller entirely. `skipIfUnchanged` is scoped to the post-offload
        // caller ONLY (see the gate directly above), so it is an exact witness for that trigger.
        //
        // A non-forced pass is the AppModel idle tick, which previously emitted NO trigger line at all when
        // it ran — a `re-score: done` with nothing before it. Every completed pass now carries one, so the
        // log can be read by pairing trigger→done instead of by inference.
        //
        // A completed offload / edit / recalibrate always re-scores past the gate above, so an empty or
        // duplicate offload still pays for a full maxDays pass over the whole raw store (#1146).
        // `newData=no` means the fingerprint already equals the watermark the last run advanced: a re-score
        // driven by the trigger, not by data (#1005 background battery). Diagnostic only; the pass runs
        // either way. Twin of the Android WhoopBleClient / AppViewModel attribution.
        let trigger = !force ? "idle" : (skipIfUnchanged ? "post-offload" : "forced")
        let hadNew = wmKey.isEmpty || storedWatermark != wmKey
        diagnosticSink?("re-score: trigger=\(trigger) "
                        + "newData=\(hadNew ? "yes" : "no (nothing changed since last run)")", nil)

        // #1005: time the whole pass — the trigger line above records WHY; this records how many nights
        // and how long (the CPU cost per run), so a re-score STORM is visible in the strap log.
        let reScoreStart = Date()
        let owedToken = RescoreBackgroundScheduler.markRescoreOwed()

        let up = UserProfile(weightKg: profile.weightKg, heightCm: profile.heightCm,
                             age: Double(profile.age), sex: profile.sex,
                             stepTicksPerStep: profile.stepTicksPerStep)

        let maxHR = profile.hrMaxOverride > 0 ? Double(profile.hrMaxOverride) : nil
        let now = Int(Date().timeIntervalSince1970)
        // Device wall-clock offset (seconds east of UTC) for the sleep detector's daytime
        // false-sleep guard (#90): the stager places each window's center on the LOCAL clock
        // so only genuinely-daytime windows face the stricter nap bar. (Computed once; a DST
        // boundary inside the window is a negligible edge case for an hour-of-day band.)
        let tzOffset = TimeZone.current.secondsFromGMT()

        // ── Pass 1: analyse each offloaded night against the IMPORTED-ONLY baseline. For a BLE-only
        // user the imported daily rows are empty, so the HRV baseline isn't usable yet and recovery is
        // null here , but each night's avgHrv/restingHr are computed baseline-INDEPENDENTLY, so we
        // harvest them to SEED the baseline and re-score in pass 2. foldHistory winsorizes outliers.
        //
        // Read the imported rows DIRECTLY (deviceId is the imported id; computed rows live under the
        // sibling `-noop` id) over the full history, sorted chronologically , NOT `repo.days`, which is
        // the merged published cache (it pre-loads prior computed `-noop` rows and back-fills nil
        // imported HRV/RHR/resp fields from computed values). Using the merge contaminated this very
        // "imported-only" baseline with computed values and made the fold window depend on whichever
        // refresh last ran (4000 vs 120 days). This mirrors the Android port's `days(importedDeviceId)`.
        let hist = ((try? await store.dailyMetrics(deviceId: deviceId, from: "0000-01-01", to: "9999-12-31")) ?? [])
            .sorted { $0.day < $1.day }
        // HRV baseline honours the manual "Recalibrate baseline" epoch (noop.hrvBaselineEpoch); the
        // resting-HR baseline honours the Charge-wide sibling (noop.recoveryBaselineEpoch). Pass the
        // per-value "yyyy-MM-dd" day keys (parallel to the values) so foldHistory can drop every night
        // before the epoch. A 0 / absent epoch makes this byte-identical to the plain fold, so scoring is
        // unchanged until the user taps Recalibrate.
        let hrvBase1 = Baselines.foldHistory(hist.map { $0.avgHrv }, dayKeys: hist.map { $0.day }, cfg: hrvCfg)
        let rhrBase1 = Baselines.foldHistory(hist.map { $0.restingHr.map(Double.init) }, dayKeys: hist.map { $0.day },
                                             cfg: rhrCfg, baselineEpoch: Baselines.recoveryBaselineEpoch())
        let baselines1 = AnalyticsEngine.ProfileBaselines(hrv: hrvBase1, restingHR: rhrBase1)

        // Keep each night's small result (daily metrics + sessions), NOT the raw streams , every field
        // except recovery is baseline-independent, so pass 2 only re-scores the cheap recovery
        // composite. The hr/rr/resp/gravity arrays go out of scope each iteration (memory stays bounded).
        var scoredNights: [(daily: DailyMetric, strain: Double?, cachedSleep: [CachedSleepSession],
                            workouts: [ExerciseSession], nightlySkin: Double?,
                            sessionMotion: [Int: [Double]],
                            sessionSleepState: [Int: [Int]],
                            hrvDiag: String?,
                            // #1545: carried beside `workouts` because it explains the times that list is
                            // EMPTY, and the emit happens in the main-actor loop below, not here.
                            detectionFunnel: WorkoutDetector.DetectionFunnel?)] = []   // #195: carried from loop 1
        // Nightly values harvested in pass 1, keyed by day, to seed the pass-2 baseline.
        var nightlyHrvByDay: [String: Double?] = [:]
        var nightlyRhrByDay: [String: Double?] = [:]
        // On-device RSA respiration + wear-gated skin-temp means (baseline-independent), harvested to
        // seed resp/skin-temp baselines the same way avgHrv seeds the HRV baseline.
        var nightlyRespByDay: [String: Double?] = [:]
        var nightlySkinByDay: [String: Double?] = [:]

        // Device-registry snapshot for per-day owner resolution (invariant I2 , a day's scores come from
        // exactly ONE source). Read once before the loop: the paired-device list + the active id are
        // stable for the run. With only the seeded 'my-whoop' row paired (the default and every
        // single-WHOOP install) the active strap is `deviceId`, so `resolveDayOwner` below returns
        // `deviceId` for every day and the per-day reads are byte-identical to the pre-I2 behaviour.
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        // #1567: `try?` used to swallow this read, and an empty device list is NOT a neutral outcome —
        // every day then resolves to `.whoop5` (see `skinTempFamily(forOwner:devices:)`), so a WHOOP 4.0's
        // raw skin-temp ADC is read as centidegrees, misses the 28–42 °C worn gate, and the night yields
        // nothing. `regDevices` also supplies the owner's model/brand below, so a failed read degrades more
        // than skin temp alone. Still non-fatal — the pass proceeds on exactly the fallbacks it always did
        // — but it no longer does so in silence. The Kotlin twin reaches this state by a different route (a
        // caller omitting `ownerSource`), hence the different cause token; see `registryUnavailableLine`.
        let regDevices: [PairedDevice]
        do {
            regDevices = try registry.all()
        } catch {
            regDevices = []
            diagnosticSink?(AnalyticsEngine.registryUnavailableLine(importedDeviceId: deviceId), nil)
        }
        let regActiveId = (try? registry.activeDeviceId()) ?? deviceId

        // Floor `now` to LOCAL midnight (#277) so each `dayStart` lands on a local-day boundary and the
        // day keys are LOCAL calendar days, consistent with the dashboard's local "today" lookup. A
        // west-of-UTC user's evening crosses midnight UTC; bucketing by UTC put it in the next UTC day,
        // which the local read never found (Toronto/UTC-4 report).
        let nowLocalMidnight = Self.midnightLocal(now, offsetSec: tzOffset)

        // ── Learned habitual midsleep (#547) ──────────────────────────────────
        // Compute the user's habitual midsleep ONCE per run from the trailing sleep history so the
        // main-night scored pick aligns to their REAL bedtime (a late/shift sleeper), not a fixed clock
        // band. Read the stored sleep sessions (imported WHOOP-export + computed "-noop") over the
        // analysis window, make one HistoryBlock per session keyed by the LOCAL calendar day of its
        // midpoint, and let the learner pick the longest block per day (so naps drop out automatically).
        // Returns nil under `habitualMinDays` of history → cold-start: every `analyzeDay`/`sleepEditedDaily`
        // call below stays on the overnight-band bonus. The same value threads into both seams so analytics
        // and the Sleep tab resolve to the identical block. (#547)
        let (habitualMidsleepSec, nightlyHours) = await Self.computeHabitualSleep(
            store: store, importedId: deviceId, computedId: deviceId + "-noop",
            windowStart: nowLocalMidnight - maxDays * 86_400 - 30 * 3_600,
            windowEnd: now, offsetSec: tzOffset)
        // Wave 0 (SL1/T1): personal sleep REGULARITY + population-anchored NEED, computed ONCE from the
        // trailing per-night durations and threaded to every analyzeDay below (mirrors the midsleep
        // learner just above — one personal trait per run, applied to the whole re-scored history so
        // Rest stops running on a flat neutral-0.5 consistency and a fixed 8 h need). Recent 28-night
        // window for regularity (a recent-behaviour signal); full history for the need's upper-quartile
        // "unrestricted nights" estimate. Both degrade honestly on thin history (consistency → nil →
        // neutral term; need → population default), so cold-start is unchanged.
        let sleepConsistency = VitalityEngine.sleepConsistency(nightlyHours: Array(nightlyHours.suffix(28)))
        let sleepNeedHours = AnalyticsEngine.Rest.personalizedNeedHours(nightlyHours: nightlyHours,
                                                                        age: profile.age)

        // ── FIX 1 (main-actor jank): run the ENTIRE per-day enumeration OFF the main actor ───────────
        // Every `await store.…` read inside this loop has its continuation RESUME on the main actor
        // (the engine is `@MainActor`), so on a fresh-import 4000-day pass the ~32 000 read-resumes
        // monopolise the main actor for ~1 minute and SwiftUI can't render. The per-day reads + scoring
        // touch NO `@Published`/`repo`/`profile` state , only the captured immutable inputs, the
        // `WhoopStore` actor, the nonisolated `registry`, and the pure `resolveDayOwner` /
        // `bandSleepStateSamples` / `AnalyticsEngine.analyzeDay`. So we hoist the whole loop into ONE
        // `Task.detached(priority:.utility)` whose continuations resume OFF the main actor, then hop back
        // here only to fold the results into `@Published`-feeding state and `refresh()` once at the end.
        // The per-day SCORING ORDER, the `hr.count >= 200` skip, and the maxDays semantics are unchanged;
        // only the executor the reads resume on changes. Diagnostic (#691) lines are computed inside (pure
        // inputs) and returned so they can be replayed through `diagnosticSink` here, in the SAME order.
        let computedId = deviceId + "-noop"
        // Bind `deviceId` (a MainActor instance `let`) to a local Sendable `String` so the @Sendable
        // detached closure captures the VALUE, never `self` (which would be an isolation violation).
        let ownerFallbackId = deviceId
        // Sleep & Rest test mode (E5): read the zero-cost gate ONCE here (a single Bool) and capture it
        // into the detached loop. When false (the default), no per-day trace sink is built and analyzeDay
        // runs its byte-identical default path. When true, each day collects its gate-trace + Rest line,
        // replayed below through `diagnosticSink` tagged `.sleep` in per-day order.
        let sleepTraceActive = TestCentre.active(.sleep)
        // HRV & Autonomic test mode (#141): read the zero-cost gate ONCE. When true, each day collects the
        // nightly per-window RMSSD (by stage) + the whole-night/deep-only/last-SWS summary, replayed below
        // tagged `.hrv`. When false (the default), no HRV trace is built and analyzeDay's path is unchanged.
        let hrvTraceActive = TestCentre.active(.hrv)
        // HRV window (#141): read ONCE. When the user picked WHOOP-style, the nightly HRV is RMSSD over deep
        // sleep only; default whole-night otherwise. Captured into the detached loop, threaded to analyzeDay.
        let deepHrvWindow = UserDefaults.standard.string(forKey: UnitPrefs.hrvWindowKey) == HrvWindow.deep.rawValue
        // Steps test mode: read the zero-cost gate ONCE here (a single Bool) and capture it into the detached
        // loop. When false (the default), no raw-counter trace is built per day. When true, each day collects
        // the 5/MG cumulative @57 series + wrap-aware deltas + dropped deltas, replayed below tagged `.steps`.
        // The trace recomputes the SAME wrap-aware sum analyzeDay already did, so the steps total is unchanged.
        let stepsTraceActive = TestCentre.active(.steps)
        // #103/queue-11a: read the SpO₂ candidate display toggle ONCE here (off the detached executor,
        // matching the other toggle reads above). When ON, each night's candidate mean (WHOOP:
        // `spo2_candidate_82`; Oura: ceiling@100 `0x6F`, see the per-day block below) is written to
        // metricSeries as "spo2_candidate" under the "-noop" device ID, so the Blood Oxygen tile can
        // surface it as a "strap estimate (unverified)" fallback. Default OFF per the derived-biosignal
        // rule (CLAUDE.md) — neither candidate is a validated calibration.
        let spo2CandidateDisplayOn = PuffinExperiment.spo2CandidateDisplayEnabled
        // Read once per pass and include in the persisted semantic signature: changing the recipe must
        // invalidate every reused day whose Effort was computed with the previous method.
        let effortMethodGlobal = PuffinExperiment.effortMethod
        // Deliberate semantic invalidation seam. Bump only when unchanged inputs intentionally produce a
        // different score. Profile/toggle values are stored separately in a stable textual signature.
        let scoringVersion = 1
        // Every day this pass will walk, in the same derivation the loop below uses, so the per-day
        // weight map is keyed identically to the days it is looked up by.
        let scanDayKeys = (0..<maxDays).map {
            AnalyticsEngine.dayString(nowLocalMidnight - $0 * 86_400, offsetSec: tzOffset)
        }
        // ONE read of the weigh-in history (NOOP's own log unioned with Apple Health — `WeightSeries.merge`),
        // resolved to a weight per day before the detached loop and captured into it as a plain value. The
        // `+ 100` days match `EnergySeries`: the resolver is a 10-day EWMA with a 90-day carry, so it needs
        // history older than the scan window to answer for the window's first day.
        let weightObservations: [CausalWeightObservation] = await repo
            .weightSeries(days: max(maxDays + 100, 100))
            .compactMap { point in
                WeightSeries.date(forDay: point.day).map {
                    CausalWeightObservation(timestamp: Int($0.timeIntervalSince1970),
                                            weightKg: point.value,
                                            source: point.source == .manual ? .manual : .health)
                }
            }
        let profileWeightKg = profile.weightKg
        let weightByDay = Self.weightByDay(days: scanDayKeys, observations: weightObservations,
                                           fallbackKg: profileWeightKg)
        // `weight` is deliberately NOT here — it is per DAY (see `weightByDay`), appended by
        // `semanticSignature(forDay:)` below. Everything in this list is genuinely pass-global: it holds
        // for every day in the window or for none, which is what makes a single miss on one of these
        // explain the whole window at once.
        let semanticSignatureBase = [
            "height=\(profile.heightCm.bitPattern)",
            "age=\(profile.age)",
            "sex=\(String(describing: profile.sex))",
            "hrmax=\(profile.hrMaxOverride)",
            "stepTicks=\(profile.stepTicksPerStep.bitPattern)",
            "tz=\(tzOffset)",
            "deepHrv=\(deepHrvWindow ? 1 : 0)",
            "spo2Candidate=\(spo2CandidateDisplayOn ? 1 : 0)",
            "effortMethod=\(String(describing: effortMethodGlobal))",
            "hrvEpoch=\(Baselines.hrvBaselineEpoch())",
            "recoveryEpoch=\(Baselines.recoveryBaselineEpoch())",
        ].joined(separator: "|")
        // The signature a day is COMPARED against and the one it is WRITTEN with have to come from here,
        // both of them. They already had to agree; now that one field varies by day, a second copy of the
        // "+ weight" step would be a copy that can disagree — and the failure it produces is silent and
        // total: no day ever matches again, and the log says only "semanticSignature".
        let semanticSignature: @Sendable (String) -> String = { day in
            "\(semanticSignatureBase)|weight=\((weightByDay[day] ?? profileWeightKg).bitPattern)"
        }
        // ── Per-day skip (#launch-rescore) ───────────────────────────────────────────────────────────
        // Re-deriving a day costs a ~54 h read (~950 k rows on a fully-worn library) plus sleep staging,
        // and the pass does it for EVERY day in the window on EVERY run. On a real install that is almost
        // entirely waste: a 21-day window on a library with 35 scored days re-computes 20 days nobody
        // touched. `dayScanFingerprint` records what each scored day was computed FROM, so an unchanged
        // day is reused from its persisted row instead of re-derived.
        //
        // Both halves are read ONCE here, on the main actor, and captured into the loop as plain values:
        // the stored fingerprints, and the persisted computed rows a reused day is rebuilt from. A day
        // needs BOTH to be reusable — a fingerprint without a row would skip a day that has no result.
        //
        // `scoringVersion` is the deliberate invalidation seam. An algorithm change moves no raw byte, so
        // every input fingerprint still matches and the new scoring would never reach the old days. It is
        // NOT the app version: keying on that would re-derive the whole window after every update, which
        // is precisely the cost this exists to remove.
        let storedFingerprints = (try? await store.dayScanFingerprints(
            deviceId: computedId, from: Self.dayKeyBound(nowLocalMidnight, maxDays: maxDays, tzOffset: tzOffset),
            to: AnalyticsEngine.dayString(nowLocalMidnight, offsetSec: tzOffset))) ?? [:]
        let persistedRowsByDay: [String: DailyMetric] = Dictionary(
            ((try? await store.dailyMetrics(
                deviceId: computedId,
                from: Self.dayKeyBound(nowLocalMidnight, maxDays: maxDays, tzOffset: tzOffset),
                to: AnalyticsEngine.dayString(nowLocalMidnight, offsetSec: tzOffset))) ?? [])
                .map { ($0.day, $0) },
            uniquingKeysWith: { _, last in last })
        let reuseAllowed = allowDayReuse
        // The learned traits THIS pass will score with, quantised once. A reused day must have been
        // scored against the same ones — they feed `analyzeDay` and therefore the stored Rest score, and
        // no amount of raw-input matching can see them move.
        let traitSignature = DayScanFingerprint.TraitSignature(
            consistency: sleepConsistency, needHours: sleepNeedHours, midsleepSec: habitualMidsleepSec)
        // Per-day progress out of the detached loop. `self` is captured WEAKLY and touched only inside the
        // main-actor hop — the loop body itself still reads nothing isolated, which is the invariant FIX 1
        // above depends on. The hop is one `Task` per day (~15 s apart), so it cannot contend with the scan.
        let publishScanStep: @Sendable (Int, Int) -> Void = { [weak self] completedDays, reusedSoFar in
            Task { @MainActor in
                self?.noteAnalysisProgress(AnalysisProgress(stage: .scanning,
                                                            completedDays: completedDays,
                                                            reusedDays: reusedSoFar,
                                                            totalDays: maxDays,
                                                            startedAt: progressStartedAt,
                                                            lastStepAt: Date()))
            }
        }
        let (scanned, skippedDayLines, reusedDays, reuseMissesByDay, firstSemanticMismatch):
            ([DayScan], [String], [String], [(day: String, misses: [String])],
             (day: String, stored: String)?) =
        await Task.detached(priority: .utility) {
            var out: [DayScan] = []
            // Days reused from their persisted row (fingerprint matched) — carried out so the main-actor
            // fold can rebuild their pass-2 state, and so the RECONCILIATION below can tell them apart from
            // days this pass actually produced. That distinction is load-bearing: the window-wide cleanups
            // (detected-workout delete, sleep dedup) assume every day in range was re-created by this pass,
            // and a reused day supplies nothing for them to re-insert.
            var reusedDays: [String] = []
            // Days skipped below (too few HR samples) never get a DayScan, so this diagnostic can't ride
            // along on one; carried out alongside `out` and replayed through `diagnosticSink` on the main
            // actor below, same as `rhrLine`/the trace arrays. Mirrors the Kotlin `diag` sink.
            var skippedDayLines: [String] = []
            // D1: per-day reuse-miss reasons, carried out and replayed on the main actor (the sink is
            // main-actor bound), same pattern as `skippedDayLines`. Empty when reuse was not attempted.
            var reuseMissesByDay: [(day: String, misses: [String])] = []
            // The FIRST day that missed on the signature, with the signature it had stored. The day
            // rides along because the signature is no longer wholly pass-global: every field except
            // `weight` holds for the whole window, `weight` is that day's own. Rebuilding the current
            // side without the day would diff against some other day's weight and invent a difference.
            var firstSemanticMismatch: (day: String, stored: String)? = nil
            // #938: the WHOOP 4.0 ADC offset is per-device, not per-night. Learn one anchor per owner
            // from the whole scan window and reuse it for every night so cross-night deviations survive.
            let skinAnchorScanFrom = nowLocalMidnight - (maxDays - 1) * 86_400 - 30 * 3_600
            let skinAnchorScanTo = nowLocalMidnight + 18 * 3_600
            var skinAnchorByOwner: [String: Double] = [:]
            var skinAnchorResolvedOwners = Set<String>()
            for offset in 0..<maxDays {
                // Cooperative hand-off between days (#goal-journey-freeze). Each day below is 10-18 s of
                // uninterrupted array crunching on a library with a deep raw-HR history (~190 k HR +
                // 200 k R-R samples per 54 h night window), and the enclosing `Task.detached(priority:
                // .utility)` is PRIORITY-ESCALATED to the awaiting caller's QoS — this class is
                // `@MainActor`, so the "background" scan actually competes with the UI. Without a
                // suspension point the whole 21-day pass runs as one unbroken block and any view that
                // needs a second layout pass (Goal & Journey does) waits minutes for it. `Task.yield()`
                // costs nothing when the CPU is free and changes NO computed value — the loop body,
                // its inputs and its output are untouched.
                await Task.yield()
                // Published here rather than at the end of the body: the loop has three `continue` paths
                // (affected-interval miss, fingerprint reuse, too-few-HR skip), and a step that only fired
                // on the full path would look stalled through a run of reused days — exactly the case where
                // the pass is moving fastest.
                publishScanStep(offset, reusedDays.count)
                let dayStart = nowLocalMidnight - offset * 86_400
                let day = AnalyticsEngine.dayString(dayStart, offsetSec: tzOffset)
                // Read a generous window around the night that ends on `day`; the stager finds the span.
                let from = dayStart - 30 * 3_600
                // Sleep read-window END — see `sleepReadWindowEnd`.
                let to = Self.sleepReadWindowEnd(dayStart: dayStart,
                                                 nowLocalMidnight: nowLocalMidnight,
                                                 now: now)

                // A repair/import caller may know the exact UTC span it changed. Preserve all existing
                // reconciliation semantics while avoiding raw-stream reads for days whose read window
                // cannot intersect that span. A missing persisted row still falls through and scans.
                if let affectedUTCInterval,
                   (to < affectedUTCInterval.lowerBound || from >= affectedUTCInterval.upperBound),
                   persistedRowsByDay[day] != nil {
                    reusedDays.append(day)
                    continue
                }

                // I2: pick the single device that owns this day, and read ITS streams below. With one device
                // this resolves to `deviceId` (active strap, has data → priority 0), so nothing changes; with
                // multiple sources the day is scored from exactly one (active strap > other live straps >
                // imports, or a locked override). Falls back to `deviceId` if the registry is unreadable.
                // NOT a cost centre — measured, so nobody re-opens this. The suspicion was that on a
                // multi-source install (where the #970 single-device fast path does not apply) the per-day
                // `hrSamples(…, limit: 1)` probe would be expensive, because SQLite would have to satisfy
                // the ORDER BY over the whole UNION — including the correlated NOT EXISTS — before it could
                // apply the LIMIT. It does not: it plans the union as a MERGE of two already-ordered index
                // scans and stops at the first row. Timed against 1.8 M rows: 62 µs.
                let diagIterStart = Date()
                let owner = await Self.resolveDayOwner(day: day, from: from, to: to, store: store,
                                                       devices: regDevices, activeId: regActiveId,
                                                       registry: registry, fallbackDeviceId: ownerFallbackId)
                let diagOwnerMs = Date().timeIntervalSince(diagIterStart) * 1000

                // ── The skip. Everything below this point is the expensive part of the pass ──────────
                // One indexed MAX over at most three UTC-day revision rows decides
                // whether the ~950 k-row read + staging that follows can be replaced by the row this day
                // already has. Reuse requires ALL of:
                //   • a stored fingerprint whose inputs match (same owner, same HR count, same newest ts),
                //   • a persisted computed row to rebuild the day's pass-2 state from,
                //   • a non-forced pass (a forced one exists precisely to re-derive).
                // Any miss falls through to the full scan, which is the only safe default: a fingerprint we
                // do not have, or do not trust, must never mean "this day is fine".
                // Probed UNCONDITIONALLY, not just when a stored fingerprint exists: a day that gets
                // scanned has to record what it was scanned FROM, or it could never be skipped later. Two
                // indexed aggregates over an index this read path already walks — the cheapest thing in
                // this loop by orders of magnitude.
                let ownerProbe = try? await store.analysisInputRevision(deviceId: owner, from: from, to: to)
                let computedProbe = try? await store.analysisInputRevision(deviceId: computedId,
                                                                            from: from, to: to)
                let probe: AnalysisInputRevision? = ownerProbe.map { ownerRevision in
                    AnalysisInputRevision(
                        inputRevision: max(ownerRevision.inputRevision,
                                           computedProbe?.inputRevision ?? 0),
                        deviceRevision: max(ownerRevision.deviceRevision,
                                            computedProbe?.deviceRevision ?? 0))
                }
                // D1: the reuse decision, and WHY. Restructured from one `if` into an explicit branch so
                // every rejected day can name the condition that rejected it. The verdict is unchanged —
                // `inputsMatch` is now literally `reuseMisses(_:).isEmpty`, so the explanation cannot
                // drift from the decision. `reuseMissesByDay` is carried out of this detached loop and
                // replayed through `diagnosticSink` on the main actor, exactly like `skippedDayLines`.
                if reuseAllowed {
                    if let probe, let stored = storedFingerprints[day], persistedRowsByDay[day] != nil {
                        let current = DayScanFingerprint(day: day, ownerId: owner,
                                                         hrCount: 0, hrMaxTs: 0,
                                                         nightlySkinC: nil, traits: traitSignature,
                                                         inputRevision: probe.inputRevision,
                                                         deviceRevision: probe.deviceRevision,
                                                         scoringVersion: scoringVersion,
                                                         semanticSignature: semanticSignature(day))
                        let misses = stored.reuseMisses(current)
                        if misses.isEmpty {
                            reusedDays.append(day)
                            continue
                        }
                        if misses.contains(.semanticSignature), firstSemanticMismatch == nil {
                            firstSemanticMismatch = (day: day, stored: stored.semanticSignature ?? "")
                            // Emitted IMMEDIATELY, not with the end-of-pass summary: waiting for the loop
                            // to finish costs a full re-derivation (~15 min on a deep library) to learn
                            // something the first miss already shows. This is the line that found the
                            // weight bug, so it stays.
                            //
                            // It reports the FIRST miss and claims no more than that. A miss on any field
                            // but `weight` is pass-global and does explain the whole window; a `weight`
                            // miss is that day's alone, and other days may differ or not.
                            // NSLog rather than `diagnosticSink`: the sink is main-actor bound and this
                            // runs inside the detached loop, and this line is read in the Xcode console.
                            let early = IntelligenceEngine.semanticSignatureDiff(
                                stored: stored.semanticSignature ?? "", current: semanticSignature(day))
                            NSLog("[FREEZE-DIAG] reuse semantic diff (first miss, day=\(day)): "
                                + (early.isEmpty ? "(no field differs — parse failure?)"
                                                 : early.joined(separator: ", ")))
                        }
                        reuseMissesByDay.append((day: day, misses: misses.map(\.rawValue)))
                    } else {
                        // Not a condition mismatch: there was nothing to compare against. Recorded
                        // separately so it can never be mistaken for a real invalidation.
                        let why = probe == nil ? "noProbe"
                            : (storedFingerprints[day] == nil ? "noStoredFingerprint" : "noPersistedRow")
                        reuseMissesByDay.append((day: day, misses: [why]))
                    }
                }

                // TEMP DIAGNOSTIC (#freeze-investigation) — attribute the per-day cost. `hrSamples` UNIONs
                // `hrSample` with `ppgHrSample` through a CORRELATED `NOT EXISTS` per PPG row, so on a dense
                // day it is a very different cost from the six plain reads. Without splitting reads from the
                // analytics, a 20-second day can't be told apart from slow math and one optimises blind.
                // Remove together with the rest of the FREEZE-DIAG block.
                // NOTE: the pre-existing `diagDayStart` below is stamped AFTER every stream read, so the
                // `took=` it reports never included them. `diagIterStart` (above, before the owner probe)
                // marks the true start of the day's work so `total=` is honest about what a day costs.
                var diagAnalyzeMs = 0.0
                var diagReadsMs = 0.0
                var diagMark = Date()
                func diagLap() -> Double {
                    let ms = Date().timeIntervalSince(diagMark) * 1000
                    diagMark = Date()
                    diagReadsMs += ms
                    return ms
                }

                let hr = (try? await store.hrSamples(deviceId: owner, from: from, to: to, limit: Int.max)) ?? []
                let diagHrMs = diagLap()
                guard hr.count >= Self.minHrSamples else {
                    // Need real raw data, not a stray sample. The skipped day gets no DayScan, so its
                    // diagnostic is carried in `skippedDayLines` and replayed through `diagnosticSink`
                    // on the main actor below (upstream #714 fix — a bare `diag()` doesn't exist in Swift).
                    skippedDayLines.append("sleep day=\(day) SKIPPED hrSamples=\(hr.count) (need ≥\(Self.minHrSamples))")
                    continue
                }
                let rr = (try? await store.rrIntervals(deviceId: owner, from: from, to: to, limit: Int.max)) ?? []
                // `forScoring` drops an Oura ring's respiration rows: those are the ring's OWN per-window
                // RATE (0x6A, milli-bpm, ~1 row per 5 min), stored as instrumentation, while the stager
                // reads this stream as a ~1 Hz raw ADC waveform. Refusing by provenance keeps the
                // instrumentation out of every scored path by construction rather than by cadence luck.
                // A WHOOP owner is unaffected, and this day scores exactly as it did before those rows
                // existed. See `OuraRespScale.forScoring`.
                // ONE read, TWO consumers, and they must not be confused for each other. `forScoring`
                // strips an Oura ring's rows from the STAGER's input: the stager reads this stream as a
                // ~1 Hz raw ADC waveform and peak-detects it, and the ring's rows are a per-window RATE —
                // the wrong shape, however good the rate. `forVendorRate` hands those same rows to
                // `analyzeDay` as what they are: the device's OWN measured respiratory rate, which
                // becomes the night's `respRateBpm` instead of the RSA estimate. A WHOOP owner gets the
                // rows in the first list and nothing in the second, so its night is unchanged.
                let respRows = (try? await store.respSamples(deviceId: owner, from: from, to: to,
                                                             limit: Int.max)) ?? []
                let resp = OuraRespScale.forScoring(respRows, deviceId: owner)
                let vendorResp = OuraRespScale.forVendorRate(respRows, deviceId: owner)
                let grav = (try? await store.gravitySamples(deviceId: owner, from: from, to: to, limit: Int.max)) ?? []
                let steps = (try? await store.stepSamples(deviceId: owner, from: from, to: to, limit: Int.max)) ?? []
                let skin = (try? await store.skinTempSamples(deviceId: owner, from: from, to: to, limit: Int.max)) ?? []
                _ = diagLap()   // TEMP DIAGNOSTIC: fold the plain reads above into `diagReadsMs`
                // #93: WHOOP 4.0 raw SpO2 PPG samples for the night; analyzeDay banks the nightly red/IR ADC
                // means on the DailyMetric. Empty on a 5/MG (no v24 spo2 channels) → the raw means stay nil.
                let spo2 = (try? await store.spo2Samples(deviceId: owner, from: from, to: to, limit: Int.max)) ?? []
                _ = diagLap()   // TEMP DIAGNOSTIC: fold the spo2 read into `diagReadsMs`
                // #938: the strap family that WROTE this owner's skin-temp rows, so analyzeDay converts the raw
                // register on the right scale (5/MG banks centidegrees, a WHOOP 4.0 v24 banks a raw ADC). The
                // registry knows each device's model; unknown/non-WHOOP owners fall back to `.whoop5` (the prior
                // /100 behaviour), so this only changes the mapping for a device positively identified as a 4.0.
                let skinFamily = Self.skinTempFamily(forOwner: owner, devices: regDevices)
                // #1467: the worn-gate timestamp tolerance for this owner (0 for WHOOP, byte-identical).
                let skinWornToleranceSec = Self.skinTempWornToleranceSec(forOwner: owner, devices: regDevices)
                // #938 (second capture): learn THIS device's worn skin-temp anchor raw ONCE, WINDOW-WIDE (the
                // whole scan window's skin samples), not per-night. The @72 skin-temp ADC's register offset is
                // per-device — a second real 4.0 strap shares the no-contact floor (~509) + 11-bit saturation
                // (2047) but a worn band ~1100–1600 (nightly mean raw ~1290), which the global 826 anchor maps
                // to 47–72 °C, so 100% of its worn samples fail the 28–42 °C gate (kept=0, no baseline, no
                // signal). WINDOW-WIDE, not per-night: a per-night re-centre would subtract each night's own
                // mean and ERASE the cross-night deviation the skinTempDevC signal exists to carry.
                // Deterministic per run; SAFE because the skin baseline is re-folded from the SAME window's
                // nightly means every run, so this constant offset cancels in the deviation. nil for a non-4.0
                // owner (`.whoop5` ignores the anchor) or when <100 in-band samples exist → the conversion
                // falls back to the global anchor (byte-identical to today).
                let skinAnchorRaw: Double?
                if skinFamily == .whoop4 {
                    if !skinAnchorResolvedOwners.contains(owner) {
                        let windowSkin = (try? await store.skinTempSamples(deviceId: owner,
                                                                           from: skinAnchorScanFrom,
                                                                           to: skinAnchorScanTo,
                                                                           limit: Int.max)) ?? []
                        if let anchor = Whoop4SkinTemp.deviceAnchorRaw(windowSkin.map { $0.raw }) {
                            skinAnchorByOwner[owner] = anchor
                        }
                        skinAnchorResolvedOwners.insert(owner)
                    }
                    skinAnchorRaw = skinAnchorByOwner[owner]
                } else {
                    skinAnchorRaw = nil
                }
                // Wrist-wear events in the night window, paired into off-wrist [start, end) intervals for the
                // off-wrist sleep backstop (#500). The HR-gap proxy in the stager is the always-on guard;
                // these explicit intervals sharpen it under the FRACTIONAL rule (#504) , a session is dropped
                // only when its off-wrist coverage reaches maxOffWristSleepFraction, so a real night with a
                // short off-wrist tail survives. Pairing needs WRIST_ON too (to bound each interval); a span
                // still open at the window end closes at `to`. Empty when the strap emitted no wrist events.
                let wristEvents = (try? await store.events(deviceId: owner, from: from, to: to, limit: 50_000)) ?? []
                let wristOff = AnalyticsEngine.offWristIntervals(events: wristEvents, windowEnd: to)

                // Calendar-day window for the ADDITIVE daily totals (steps + calories). The night window
                // above is anchored to the current time-of-day and ends at dayStart+12h, so for a PAST
                // day whose late hours sit after that bound those hours are never read and the totals
                // undercount. Read exactly [localMidnight(day), localMidnight(day)+86400) and hand it to
                // analyzeDay's dayHr/daySteps, which use it ONLY for those totals. `dayStart` is already a
                // LOCAL midnight; midnightLocal is idempotent on it (the store range is inclusive, so end
                // at -1 s). (#277 , local-day bucketing.)
                let dayMid = Self.midnightLocal(dayStart, offsetSec: tzOffset)
                let dayEnd = dayMid + 86_400 - 1
                // Same `owner` as the night window above (I2): the additive day totals must come from the
                // one device that owns the day, never a mix.
                // #997 (ryanbr): for a PAST day (20 of 21 in the default scan) the night window above reads
                // through to nextMidnight, so the calendar day [dayMid, dayEnd] is a strict subset of the
                // hr/steps/grav lists already in memory — derive the day streams by filtering them
                // (AnalyticsEngine.daySliceFromNight) instead of a second store read (~60 redundant reads
                // per pass, incl. the big HR ones). TODAY (its day runs past the 18 h night cap) and a
                // a deliberately finite diagnostic read limit would DECLINE (nil) and read directly, so
                // the shortcut can only ever skip work, never change data. Byte-identical: same owner, same inclusive
                // bounds, same ts-ASC order as the direct read. (`??` can't take an `await` right-hand
                // side, hence the explicit if/else at each site.)
                let dayHr: [HRSample]
                if let slice = AnalyticsEngine.daySliceFromNight(hr, nightLo: from, nightHi: to,
                                                                 dayLo: dayMid, dayHi: dayEnd, ts: { $0.ts }) {
                    dayHr = slice
                } else {
                    dayHr = (try? await store.hrSamples(deviceId: owner, from: dayMid, to: dayEnd, limit: Int.max)) ?? []
                }
                let daySteps: [StepSample]
                if let slice = AnalyticsEngine.daySliceFromNight(steps, nightLo: from, nightHi: to,
                                                                 dayLo: dayMid, dayHi: dayEnd, ts: { $0.ts }) {
                    daySteps = slice
                } else {
                    daySteps = (try? await store.stepSamples(deviceId: owner, from: dayMid, to: dayEnd, limit: Int.max)) ?? []
                }
                // Full calendar-day gravity for WORKOUT detection. The night window above ends at
                // dayStart+12h (≈ noon), so an afternoon/evening workout sits outside it and was only
                // detected once a later pass re-read it through the next night window , a ~day lag. This
                // [localMidnight, localMidnight+24h) read (today: clamped to `now` by the store) lets the
                // detector see the whole day, so a 5 pm run shows up on the same day.
                let dayGrav: [GravitySample]
                if let slice = AnalyticsEngine.daySliceFromNight(grav, nightLo: from, nightHi: to,
                                                                 dayLo: dayMid, dayHi: dayEnd, ts: { $0.ts }) {
                    dayGrav = slice
                } else {
                    dayGrav = (try? await store.gravitySamples(deviceId: owner, from: dayMid, to: dayEnd, limit: Int.max)) ?? []
                }

                // CONSUME (#531 / #175): the strap's OWN band sleep_state for the night window as timestamped
                // (ts, state) samples, so the H7 morning-stillness guard can confirm a borderline re-onset
                // against the strap's OWN scored band, AND analyzeDay can grid it per session for persistence.
                // #175 wired the RAW `sleepStateSample` stream end to end: read it directly from `owner` (the
                // strap that owns this night) so it is available THIS pass, not one pass behind, and it comes
                // from the real offload rather than a read-its-own-write of the per-session JSON. Empty on a
                // WHOOP 4.0 (no band_sleep_state stream) or an unbanded window → the guard falls back to the HR
                // bar and no per-session state is persisted. Honest: only real banded epochs are ever surfaced.
                // Fall back to the prior pass's persisted per-session state when the raw stream is absent (an
                // older DB banded before the v21 stream landed), so a legacy install keeps the H7 confirm.
                var bandSleepState = (try? await store.sleepStateSamples(deviceId: owner, from: from, to: to))?
                    .map { (ts: $0.ts, state: $0.state) } ?? []
                if bandSleepState.isEmpty {
                    bandSleepState = await Self.bandSleepStateSamples(computedId: computedId,
                                                                     from: from, to: to, store: store)
                }

                // #690: read the experimental-V2 toggle ONCE here (off the detached executor, matching the
                // Repository self-heal call site) and capture the Bool, so the Settings toggle now drives the
                // NORMAL detected-night staging path , not only the userEdited self-heal restage.
                // V2 is the default staging engine for EVERY strap (the toggle defaults on); turn it off to
                // fall back to V1. WHOOP 4.0 is unvalidated either way — V2 can over-stage on sparse motion
                // (#319) and V1 can badly UNDER-stage deep/REM (kavemang, #347), so neither is proven; the
                // toggle is the honest escape until real 4.0 ground truth settles it (#271/#319). Matches the
                // self-heal restage below, which reads the same toggle.
                let useSleepStagerV2 = PuffinExperiment.experimentalSleepV2Enabled
                // #364 follow-up: read the motion-aware wake refinement toggle the same way (once, off the
                // detached executor). Default OFF — see `PuffinExperiment.motionAwareWakeEnabled`. It only
                // ever runs AFTER whichever stager above just ran, and self-gates on the night's observed
                // gravity + step density, so flipping it on is a no-op for any night too sparse to trust.
                let useMotionAwareWake = PuffinExperiment.motionAwareWakeEnabled

                // Already OFF the main actor , score directly (the prior nested `Task.detached` here only
                // existed to hop off the main actor; the whole loop now runs off it, so the score is computed
                // inline with the identical inputs and identical result).
                // Sleep & Rest test mode (E5): a per-day collector for the gate trace + Rest sub-score line,
                // built ONLY when the mode is active. nil otherwise = analyzeDay's byte-identical default path.
                var sleepTrace: [String] = []
                let traceSink: ((String) -> Void)? = sleepTraceActive ? { sleepTrace.append($0) } : nil
                // HRV mode (#141): a per-day collector for the nightly per-window RMSSD + summary; nil = default.
                var hrvTrace: [String] = []
                let hrvTraceSink: ((String) -> Void)? = hrvTraceActive ? { hrvTrace.append($0) } : nil
                // TEMP DIAGNOSTIC: per-day cost + input volume, so a slow pass shows WHICH day is heavy
                // and how many samples it actually had to chew through.
                defer {
                    let f = { (s: Double) in String(format: "%.2f", s) }
                    let total = Date().timeIntervalSince(diagIterStart)
                    // `analysisPipeline` is the complete synchronous scorer. `other` is intentionally explicit
                    // rather than the old misleading `post`: it includes owner resolution, auxiliary reads and
                    // persistence preparation that are not yet timed independently.
                    let measured = (diagOwnerMs + diagReadsMs + diagAnalyzeMs) / 1000
                    let other = max(0, total - measured)
                    NSLog("[FREEZE-DIAG]   day=\(day) owner=\(owner) total=\(f(total))s "
                        + "ownerProbe=\(f(diagOwnerMs / 1000))s rawRead=\(f(diagReadsMs / 1000))s "
                        + "hrRead=\(f(diagHrMs / 1000))s analysisPipeline=\(f(diagAnalyzeMs / 1000))s "
                        + "other=\(f(other))s "
                        + "hr=\(hr.count) rr=\(rr.count) grav=\(grav.count) steps=\(steps.count)")
                }
                // #804 Fix A: when this day's owner is a device that sends NO usable gravity vector — so the
                // motion detector can't stage the night and it scored blank — AND it has persisted its OWN
                // hypnogram under its device namespace (an Oura ring's SleepNet night, #773), hand that
                // hypnogram to analyzeDay so the night scores. Gated on absent gravity (`grav.count < 2` — a
                // ring streams zero; a WHOOP always streams a gravity vector, sparse-but-present on a 4.0) plus
                // a non-canonical-WHOOP-import owner, so WHOOP straps and the "my-whoop" import namespace are
                // untouched; analyzeDay still lets a DETECTED session win where the two overlap. Reconstruct the
                // pure SleepSession from each stored CachedSleepSession (a minute-dict import row decodes to
                // nothing and is skipped, so only real stage timelines are injected).
                let providedSleep: [SleepSession]
                if owner != Repository.whoopSource, grav.count < 2 {
                    let persisted = (try? await store.sleepSessions(deviceId: owner, from: from, to: to,
                                                                    limit: 4000)) ?? []
                    providedSleep = persisted.compactMap { AnalyticsEngine.sleepSession(fromProvided: $0) }
                } else {
                    providedSleep = []
                }
                // Score this day against the body mass the wearer had ON it, not the one they have now.
                // Same `var dayProfile = profile` shape `EnergySeries` uses, and it must agree with the
                // weight `semanticSignature(day)` just claimed: a day whose signature promises one weight
                // and whose scoring uses another would be reused on a fingerprint that describes numbers
                // it does not hold.
                var dayProfile = up
                dayProfile.weightKg = weightByDay[day] ?? up.weightKg
                let diagAnalyzeStart = Date()   // TEMP DIAGNOSTIC: math cost, separated from the read cost
                let res = AnalyticsEngine.analyzeDay(day: day, hr: hr, rr: rr, resp: resp,
                                                     vendorResp: vendorResp, gravity: grav,
                                                     steps: steps, dayHr: dayHr, daySteps: daySteps,
                                                     dayGravity: dayGrav,
                                                     skinTemp: skin,
                                                     skinTempFamily: skinFamily,   // #938
                                                     skinTempAnchorRaw: skinAnchorRaw,   // #938 second capture
                                                     skinTempWornToleranceSec: skinWornToleranceSec,   // #1467
                                                     spo2: spo2,                   // #93
                                                     profile: dayProfile, baselines: baselines1, maxHROverride: maxHR,
                                                     tzOffsetSeconds: tzOffset, wristOff: wristOff,
                                                     sleepNeedHours: sleepNeedHours,
                                                     sleepConsistency: sleepConsistency,
                                                     habitualMidsleepSec: habitualMidsleepSec,
                                                     bandSleepState: bandSleepState,
                                                     // #690: thread the V2 toggle into the NORMAL staging path so
                                                     // it affects detected nights, not just the self-heal restage.
                                                     useSleepStagerV2: useSleepStagerV2,
                                                     // #364 follow-up: same threading for the motion-aware wake
                                                     // refinement post-pass.
                                                     useMotionAwareWake: useMotionAwareWake,
                                                     // #804 Fix A: the owner's own device-provided hypnogram
                                                     // (empty for WHOOP / non-ring days → default path).
                                                     providedSleep: providedSleep,
                                                     traceSink: traceSink,
                                                     hrvTraceSink: hrvTraceSink,
                                                     // Per-window HRV detail ONLY for the most-recent night
                                                     // (dayStart == today's local midnight), so the 5000-line
                                                     // ring buffer isn't flooded; every night keeps the summary.
                                                     hrvWindowDetail: dayStart == nowLocalMidnight,
                                                     deepHrvWindow: deepHrvWindow,
                                                     effortMethod: effortMethodGlobal)
                diagAnalyzeMs = Date().timeIntervalSince(diagAnalyzeStart) * 1000   // TEMP DIAGNOSTIC
                // #195: whole-night HRV cleaning-pipeline summary for the always-on strap log, so a "reads ~2x
                // too high" report is triageable without the HRV test mode: RMSSD vs SDNN (rmssd >> sdnn =
                // beat-to-beat jitter surviving the ectopic filter, not real HRV), meanNN as an HR sanity-check,
                // and how many R-R intervals survived cleaning (a low count also flags the sparse-capture /
                // calibration side — `nInput` is set before the min-beats gate, so a sparse night still shows
                // its count with rmssd=nil). A SEPARATE analyzer pass over the in-sleep R-R — does NOT touch the
                // shipped windowed avgHrv. Built here (loop 1) where `rr` is in scope, but EMITTED in the
                // main-actor replay loop below (diagnosticSink is main-actor isolated), carried on `hrvDiag`.
                // Byte-identical to the Kotlin line.
                let sleepRrRows = rr.filter { r in res.cachedSleep.contains { r.ts >= $0.startTs && r.ts < $0.endTs } }
                let sleepRr = sleepRrRows.map { Double($0.rrMs) }
                let hrvDiag: String?
                let hrvOverCounted: Bool?   // #1118: nil = no in-sleep R-R (no HRV to caveat)
                var respGateAcc: Double?
                var respGateIntegrity: String?
                if sleepRr.isEmpty {
                    hrvOverCounted = nil
                    // #1244: no in-sleep R-R means no HRV summary. If the whole night also detected NO
                    // session (past the ≥200-HR gate → this is the "HR tracked, no sleep" case), carry a
                    // counts-only reason line on the SAME loop-1 diagnostic channel (emitted in the
                    // main-actor replay below) so the report says WHY the stager found nothing. `window` is
                    // the read span in whole hours (30 h back → next local midnight, or +18 h for today).
                    if res.cachedSleep.isEmpty {
                        // from/to are Int unix seconds; the span is always a whole-hour multiple
                        // (30 h + 24 h, or 30 h + 18 h), so integer division is exact. Matches Kotlin.
                        let windowHours = (to - from) / 3_600
                        hrvDiag = Self.sleepDetectNoNightLogLine(
                            day: day, hrCount: hr.count, rrCount: rr.count, respCount: resp.count,
                            gravCount: grav.count, stepCount: steps.count,
                            providedCount: providedSleep.count, windowHours: windowHours)
                    } else {
                        hrvDiag = nil
                    }
                } else {
                    let h = HRVAnalyzer.analyze(rawRR: sleepRr)
                    func ms(_ v: Double?) -> String { v.map { String(format: "%.0f", $0) } ?? "nil" }
                    let rej = h.nInput > 0 ? String(format: "%.0f", 100 * (1 - Double(h.nClean) / Double(h.nInput))) : "0"
                    // #257: coverage (sum of NN ÷ wall-clock span; > 1.0 is impossible without double-counted
                    // R-R) + exact-duplicate beat count, so a "reads ~2x too high" report is self-diagnosing
                    // from the always-on log instead of hand-computing beat density.
                    let ts = sleepRrRows.map { $0.ts }
                    // Computed ONCE and reused for both the formatted field and the verdict below:
                    // collapsedCoverage sorts and de-dups the whole night's R-R (tens of thousands of rows
                    // on a dense capture), and this runs per day across a full re-score.
                    let covVal = HRVAnalyzer.rrCoverage(tsSec: ts, rrMs: sleepRr)
                    let cov = String(format: "%.2f", covVal)
                    // #550: collapsedCov previews a same-second R-R de-dup — well below `coverage` ⇒ the
                    // over-count is same-second (a dedup fix would work); still high ⇒ cross-second overlap.
                    let colCovVal = HRVAnalyzer.collapsedCoverage(tsSec: ts, rrMs: sleepRr)
                    let colCov = String(format: "%.2f", colCovVal)
                    let dup = HRVAnalyzer.duplicateBeatCount(tsSec: ts, rrMs: sleepRr)
                    // #550: state the CONCLUSION, not just the evidence. Reading coverage against
                    // collapsedCov is what distinguishes a same-second over-count (a de-dup would fix it)
                    // from a cross-second one (it would not) — a rule that lived only in the comment above,
                    // so triaging an "HRV reads ~2x high" report required knowing it. Now the line says which.
                    let verdict = HRVAnalyzer.classifyCoverage(coverage: covVal, collapsed: colCovVal)
                    // #550 follow-up: having stated the conclusion, ACT on it. SDNN is a spread over every
                    // interval, so an over-counted night inflates it directly — a ring whose banked R-R
                    // covers 1.25x its wall-clock reads ~197 ms across a sleeping night, against a 40-100 ms
                    // physiological range. Printing that number beside the verdict that says it cannot be
                    // trusted invites it to be read as a measurement, so it is withheld instead; the
                    // `rrIntegrity=` field on the same line says why. RMSSD/meanNN are NOT withheld — mean
                    // rate survives an over-count, and RMSSD's dominant error was the emission order fixed
                    // at the write path (#1072).
                    // P7' follow-up: the over-count verdict is necessary but NOT sufficient. The
                    // 2026-08-06 Oura night measured coverage 1.03 / `plausible` — no duplication at
                    // all, its records tiling the timeline at a fill ratio of 0.990 — and still printed
                    // SDNN 174 ms. A BANKED stream stamps a whole record of intervals on one timestamp,
                    // so its stored values are a decomposition of a record period, not beat-to-beat
                    // measurements: the per-record SUM is right to ~1% (meanNN and RHR stay correct and
                    // WHOOP-validated) while the individual intervals are not. Gate on that too.
                    let accVal = HRVAnalyzer.beatAccurateFraction(tsSec: ts, rrMs: sleepRr)
                    respGateAcc = accVal
                    respGateIntegrity = verdict.rawValue
                    let acc = String(format: "%.2f", accVal)
                    let sdnnField = HRVAnalyzer.beatSpreadIsTrustworthy(verdict)
                        && HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: accVal)
                        ? "\(ms(h.sdnn))ms" : "withheld"
                    var diagLine = "hrv diag day=\(res.daily.day) rmssd=\(ms(h.rmssd))ms sdnn=\(sdnnField) "
                        + "meanNN=\(ms(h.meanNN))ms rr=\(h.nInput)/\(h.nClean) rejected=\(rej)% coverage=\(cov) collapsedCov=\(colCov) dupBeats=\(dup) "
                        + "beatAccurate=\(acc) "
                        + "rrIntegrity=\(verdict.rawValue)"
                    // #1008: on an OVER-COUNT night only, append a raw-row sample around the densest second
                    // (carried as a second \n-joined line, split back apart at the emit site) so the
                    // over-count's MECHANISM is readable from the always-on log — clean nights stay quiet.
                    // srcChannel rides from the read model. Byte-identical to the Kotlin `hrv rrsample` line.
                    if verdict == .crossSecondOverCount || verdict == .sameSecondOverCount {
                        // Built ONCE for all three diagnostics below. Each call materialised its own copy
                        // of the night's ords — ~70k elements, on a path that runs ~21 times per
                        // analyzeRecent, every 15 minutes — so two of the three were pure waste. (#1510)
                        let rrOrds = sleepRrRows.map { $0.ord }
                        let sample = HRVAnalyzer.densestSecondWindowSample(
                            tsSec: ts, rrMs: sleepRr, srcCodes: sleepRrRows.map { $0.srcChannel?.rawValue },
                            ords: rrOrds)
                        if !sample.isEmpty { diagLine += "\nhrv rrsample day=\(res.daily.day) \(sample)" }
                        // #1331/#1008: the sample above shows ords for a handful of seconds; this counts
                        // them across the WHOLE night, which is what decides whether the fix belongs at
                        // ingest. Kotlin twin.
                        let deliveries = HRVAnalyzer.deliveryHistogram(
                            tsSec: ts, rrMs: sleepRr, ords: rrOrds)
                        if !deliveries.isEmpty { diagLine += "\n\(deliveries) day=\(res.daily.day)" }
                        // #1505: the histogram above counts deliveries per second but never compares what
                        // they wrote. If the live and historical copies are the same beat in two units, a
                        // duplicated second holds two values 1024/1000 apart; if they are different beats,
                        // the ratios scatter. One pair cannot tell those apart — a night's worth can.
                        // Measurement only, takes no view on the answer. Kotlin twin.
                        let dupPairs = HRVAnalyzer.duplicatePairRatios(
                            tsSec: ts, rrMs: sleepRr, ords: rrOrds)
                        if !dupPairs.isEmpty { diagLine += "\n\(dupPairs) day=\(res.daily.day)" }
                        // #1331/#1008/#1118 SHADOW: log the DEDUPED stream's HRV + coverage + beat-accuracy
                        // beside the raw (above), so the candidate two-channel de-dup can be validated
                        // against WHOOP's own numbers and @artemc's Polar H10 BEFORE it becomes the read
                        // path. Instrumentation only — the shipped HRV/resp is unchanged. If de-dup works:
                        // coverage→~1.0, beatAccurate high (would pass #1127's RSA gate → resp returns, the
                        // #1331 fix), and rmssd/sdnn become physiological + should match WHOOP. Kotlin twin.
                        // Two candidates so validation isn't confounded: EXACT-dup collapse (rrTolMs 0 —
                        // same ts AND same value, provably no real-beat loss) is the safe floor; the ~40 ms
                        // same-second collapse is the aggressive UPPER BOUND (it also catches the two-channel
                        // twins but can over-merge two real neighbours whose values sit within 40 ms). The
                        // real de-dup lives between them; the log shows both so we can see where.
                        // #1331 RETIRED (two of them). `xsec` — the 40 ms collapse widened to a 1-second
                        // window — was a strict UPPER BOUND that over-merges real beats, kept only to size
                        // how far a cross-second collapse COULD get. It has now produced that number in the
                        // field: covXsec 0.80 with beatAccXsec 0.26, i.e. it eats real beats exactly as its
                        // own comment predicted. And the same-second TOLERANCE SWEEP (20/34/60) was sizing a
                        // fix already ruled out — every affected night reads `crossSecondOverCount`, so no
                        // same-second tolerance can reach duplicates that straddle the boundary.
                        //
                        // Both cost real work on the phones least able to spare it: this block runs for
                        // EVERY night of an affected strap, `analyzeRecent` re-scores ~21 days every 15
                        // minutes, and each `collapseOverCount` SORTS the night's ~50-70k intervals. Six
                        // sorts per night became two. What survives is the honest floor (`ex`, exact
                        // duplicates only — provably no real-beat loss) and the incumbent candidate (`dd`,
                        // 40 ms same-second). The delivery histogram above supersedes what both retired
                        // measurements were reaching for, and costs one pass instead of nine.
                        let ex = HRVAnalyzer.collapseOverCount(tsSec: ts, rrMs: sleepRr, rrTolMs: 0)
                        let dd = HRVAnalyzer.collapseOverCount(tsSec: ts, rrMs: sleepRr)
                        let hDd = HRVAnalyzer.analyze(rawRR: dd.rrMs)
                        let covEx = HRVAnalyzer.rrCoverage(tsSec: ex.tsSec, rrMs: ex.rrMs)
                        let covDd = HRVAnalyzer.rrCoverage(tsSec: dd.tsSec, rrMs: dd.rrMs)
                        let accDd = HRVAnalyzer.beatAccurateFraction(tsSec: dd.tsSec, rrMs: dd.rrMs)
                        diagLine += "\nhrv dedup day=\(res.daily.day) exactN=\(ex.rrMs.count)/\(sleepRr.count) "
                            + "covExact=\(String(format: "%.2f", covEx)) | ch40N=\(dd.rrMs.count) "
                            + "cov40=\(String(format: "%.2f", covDd)) beatAcc40=\(String(format: "%.2f", accDd)) "
                            + "rmssd40=\(ms(hDd.rmssd))ms sdnn40=\(ms(hDd.sdnn))ms meanNN40=\(ms(hDd.meanNN))ms "
                            + "| collapse candidates only; the DELIVERY histogram above sizes the fix"
                        // #1118 sweep: the same-second collapse at a range of tolerances, so a capture shows
                        // WHICH tolerance the over-count actually responds to instead of only the one 40 ms
                        // point. 34 ms is the two-optical-channel twin spacing; 0 is exact-duplicates-only.
                        // The 0 and 40 points are NOT recomputed: `ex` and `dd` above ARE those collapses
                        // (`collapseOverCount`'s default tolerance is 40), and each collapse sorts the night's
                        // intervals — ~50k on an over-count night. Reusing them keeps the sweep to three extra
                        // passes instead of five on a block that runs for EVERY night of an affected strap,
                        // inside the per-day rescore loop #836 already had to slim down. Twin of Kotlin.
                    }
                    hrvDiag = diagLine
                    // #1118: flag this night's HRV as over-counted (same verdict the diag logs) so the
                    // HRV card can mark the reading unverified until the two-channel de-dup lands.
                    hrvOverCounted = (verdict == .crossSecondOverCount || verdict == .sameSecondOverCount)
                }
                // ── Steps test mode: 5/MG raw-counter trace ──────────────────────────────────────────────
                // Only built when the Steps mode is on (the gate was read once before the loop). Recomputes
                // the SAME wrap-aware @57 sum analyzeDay just ran, over the SAME `daySteps` calendar-day
                // stream, so the reported scaledSteps equals the day's steps_est, so the trace cannot diverge.
                // Pure inputs, carried out so the main actor replays it tagged `.steps` in per-day order.
                var stepsTrace: [String] = []
                // #807 — only a counter strap (WHOOP 5/MG) banks step samples; a WHOOP 4.0 has none, so
                // without the daySteps guard the trace spams "counterSamples=0 (need >=2 for a delta)" every
                // day and buries the motion-volume calibration trace that actually explains a 4.0's steps.
                // Mirrors the Android IntelligenceEngine guard (stepsTraceSink != null && daySteps.isNotEmpty()).
                if stepsTraceActive && !daySteps.isEmpty {
                    stepsTrace = StepsEstimateEngine.rawCounterTrace(
                        daySteps: daySteps, dayKey: day, tzOffsetSeconds: tzOffset,
                        ticksPerStep: up.stepTicksPerStep)
                }
                // ── RHR floor-vs-mean diagnostic (#691) ────────────────────────────────────────────────
                // Make the recurring "NOOP's resting HR reads LOWER than my sleeping-HR app" reports
                // explainable from the strap log instead of a guess. The two numbers measure different
                // things BY DESIGN, not a bug: NOOP's `restingHr` is the WHOOP-style FLOOR (the lowest
                // sustained 5-min in-bed level , SleepStager picks the min 5-min rolling-mean HR per session,
                // and the day takes the .min() across them), whereas a "sleeping HR" app reports the night
                // MEAN over the whole asleep span. The mean always sits above the floor, so NOOP looking
                // lower is correct. Log BOTH so a report ships proof of the gap. Mean is computed over the
                // SAME matched in-bed span the floor came from (so they're directly comparable); a night
                // with no banked floor (no matched sleep) logs nil and the line is skipped. Logging only ,
                // no scoring change. Counts/bpm only; no timestamps or PII (LiveState.append also scrubs).
                // Computed here (pure inputs) and carried out so the main actor can replay it through
                // `diagnosticSink` in the SAME per-day order , the sink is a MainActor-bound closure.
                var rhrLine: String?
                if let floor = res.daily.restingHr {
                    let inBedBpms = hr.filter { s in
                        res.cachedSleep.contains { s.ts >= $0.startTs && s.ts < $0.endTs }
                    }.map { $0.bpm }
                    rhrLine = Self.rhrFloorMeanLogLine(day: res.daily.day, floor: floor, inBedBpms: inBedBpms)
                }
                // #1331 respiratory diagnostic — a run of nil nights localises when it stopped. Same
                // pure-compute-here / replay-on-main-actor path as rhrLine.
                let respLine: String? = Self.respRateLogLine(day: res.daily.day,
                                                            respRateBpm: res.daily.respRateBpm,
                                                            beatAccurate: respGateAcc,
                                                            rrIntegrity: respGateIntegrity)
                // #103/queue-11a: SpO₂ candidate nightly mean. Only computed when the display toggle is
                // ON, and the transform is device-conditional (#1086-style brand lookup, matching
                // `skinTempWornToleranceSec`'s idiom just above): a WHOOP owner averages the in-band
                // (70–100) `spo2_candidate_82` V18Aux byte; an Oura owner averages the ring's own `0x6F`
                // SpO2 (`spo2`, already fetched above for `nightlySpo2RawMeans`) through the ceiling@100
                // transform — see `AnalyticsEngine.nightlySpo2CeilingMean`'s doc for why ceiling@100 is
                // queue 11a's starting choice. nil on a WHOOP 4.0 (no v18 aux stream) with no candidate
                // decode, an Oura night with no in-window plausible sample, or when the toggle is OFF.
                // The mean is written to metricSeries as "spo2_candidate" in pass 2, never to `spo2Pct` —
                // the guard test `testHistoricalV18OpticalFieldsAreNotNamedPhysiologically` enforces that
                // boundary for the WHOOP path.
                var spo2CandidateMean: Int? = nil
                if spo2CandidateDisplayOn {
                    if DeviceBrandCatalog.isOura(owner) {
                        if let cand = AnalyticsEngine.nightlySpo2CeilingMean(res.sleepSessions, spo2: spo2) {
                            spo2CandidateMean = cand.mean
                        }
                    } else {
                        let auxSamples = (try? await store.v18AuxSamples(
                            deviceId: owner, from: from, to: to, limit: Int.max)) ?? []
                        if !auxSamples.isEmpty {
                            if let cand = AnalyticsEngine.nightlySpo2CandidateMean(res.sleepSessions, aux: auxSamples) {
                                spo2CandidateMean = cand.mean
                            }
                        }
                    }
                }
                // #1169 SHADOW METRIC (instrumentation only): the primary-session MEAN resting HR, recorded
                // beside the shipped nightly HR FLOOR (daily.restingHr = min per session) so the mean-vs-floor
                // comparison the issue asks for accrues on real devices. NEVER shown and NEVER fed to any
                // score; #1174's definition is unchanged — this only records its per-night output. The
                // windowing + delegation lives in the byte-identical, tested `AnalyticsEngine`.
                let (primarySessionRHR, primarySessionRHRCoverage) =
                    AnalyticsEngine.primarySessionRestingHRWithCoverage(sessions: res.sleepSessions, hr: hr)
                out.append(DayScan(result: res, inputProbe: probe, rhrLine: rhrLine, respLine: respLine,
                                   readOwner: owner, hrRows: hr.count,
                                   sleepTrace: sleepTrace, stepsTrace: stepsTrace, hrvTrace: hrvTrace,
                                   hrvDiag: hrvDiag, spo2Candidate: spo2CandidateMean,
                                   hrvOverCounted: hrvOverCounted,
                                   primarySessionRHR: primarySessionRHR,
                                   primarySessionRHRCoverage: primarySessionRHRCoverage))
            }
            return (out, skippedDayLines, reusedDays, reuseMissesByDay, firstSemanticMismatch)
        }.value

        // #714: replay each skipped day's diagnostic now that we're back on the main actor (diagnosticSink
        // is MainActor-bound). Always-on , not gated behind a test mode, mirroring the Kotlin `diag` sink.
        for line in skippedDayLines { diagnosticSink?(line, nil) }

        // CAPTURE-B (#814/#799): per-day resolved READ owner + that owner's HR-row count, keyed by day, so
        // the second pass (which has the provenance sets) can emit the universal `dayOwner …` line. The
        // owner is the id this day was actually scored/read from; the registry active id is what the WRITE
        // side uses; when they DIVERGE on a day that has data, that's the #814 read/write split made
        // visible in every export.
        var readOwnerByDay: [String: (owner: String, hrRows: Int)] = [:]
        var resolvedScoreOwnerByDay: [String: String] = [:]
        // #103: SpO₂ candidate @82 nightly mean per day, carried from pass 1 for metricSeries persistence.
        var spo2CandidateByDay: [String: Int] = [:]
        // #1118: per-day HRV over-count flag, carried from pass 1 for metricSeries persistence. nil (absent)
        // for a night with no in-sleep R-R; otherwise true/false, so a re-score always overwrites the row.
        var hrvOverCountByDay: [String: Bool] = [:]
        // #1169: primary-session mean RHR shadow metric per day, carried from pass 1 for metricSeries persistence.
        var primarySessionRHRByDay: [String: Double] = [:]
        // #1169: its coverage inputs (valid-sample count + primary-session duration), same lifetime as the mean.
        var primarySessionRHRCoverageByDay: [String: PrimarySessionRestingHR.Coverage] = [:]

        // Back on the main actor: fold the off-actor results into the pass-2 state in the SAME order the
        // loop produced them. Pure assignment / appends , no further store reads , so this is cheap and the
        // main actor was free during the heavy enumeration above.
        for scan in scanned {
            let res = scan.result
            readOwnerByDay[res.daily.day] = (scan.readOwner, scan.hrRows)
            resolvedScoreOwnerByDay[res.daily.day] = scan.readOwner
            nightlyHrvByDay[res.daily.day] = res.daily.avgHrv
            nightlyRhrByDay[res.daily.day] = res.daily.restingHr.map(Double.init)
            nightlyRespByDay[res.daily.day] = res.daily.respRateBpm
            nightlySkinByDay[res.daily.day] = res.nightlySkinTempC
            // #103: carry the SpO₂ candidate @82 nightly mean into pass 2 for metricSeries persistence.
            // nil when the toggle is OFF or the night had no in-band @82 readings.
            if let cand = scan.spo2Candidate {
                spo2CandidateByDay[res.daily.day] = cand
            }
            // #1118: carry the HRV over-count flag into pass 2 for metricSeries persistence.
            if let oc = scan.hrvOverCounted {
                hrvOverCountByDay[res.daily.day] = oc
            }
            // #1169: carry the primary-session mean RHR shadow metric into pass 2 for persistence.
            if let v = scan.primarySessionRHR {
                primarySessionRHRByDay[res.daily.day] = v
            }
            if let cov = scan.primarySessionRHRCoverage {
                primarySessionRHRCoverageByDay[res.daily.day] = cov
            }
            if let line = scan.rhrLine { diagnosticSink?(line, nil) }
            if let line = scan.respLine { diagnosticSink?(line, nil) }
            // Sleep & Rest test mode (E5): replay this day's gate-trace + Rest lines tagged `.sleep` so they
            // land under the profile tag in the export. Empty unless the mode is active.
            for line in scan.sleepTrace { diagnosticSink?(line, .sleep) }
            // HRV test mode (#141): replay this day's nightly per-window RMSSD + summary tagged `.hrv`.
            // Empty unless the HRV mode is active, so the default path emits zero `.hrv` lines here.
            for line in scan.hrvTrace { diagnosticSink?(line, .hrv) }
            // Steps test mode: replay this day's 5/MG raw-counter trace tagged `.steps`. Empty unless the
            // mode is active, so the default path emits zero `.steps` lines here.
            for line in scan.stepsTrace { diagnosticSink?(line, .steps) }
            scoredNights.append((daily: res.daily, strain: res.strain, cachedSleep: res.cachedSleep,
                                 workouts: res.workouts, nightlySkin: res.nightlySkinTempC,
                                 sessionMotion: res.sessionMotionByStart,
                                 sessionSleepState: res.sessionSleepStateByStart,
                                 hrvDiag: scan.hrvDiag,
                                 detectionFunnel: res.detectionFunnel))
        }

        // The day loop is done; everything below (persist, baseline re-fold, window reconciliation) is
        // real work on a deep library, so the card must not sit at "day 21 of 21" through it.
        analysisProgress = AnalysisProgress(stage: .finishing, completedDays: maxDays,
                                            reusedDays: reusedDays.count, totalDays: maxDays,
                                            startedAt: progressStartedAt, lastStepAt: Date())

        // ── Reused days (#launch-rescore) ────────────────────────────────────────────────────────────
        // A day whose raw inputs have not moved was not re-derived above. It still has to take part in
        // everything that follows, because the baselines are folded over the WHOLE window and pass 2
        // re-scores recovery for every day in it: leaving reused days out would make the baseline — and
        // therefore every score folded off it — depend on which days happened to be skipped, which is the
        // one thing this optimisation must never do.
        //
        // Their state comes from the row they already have. `nightlySkin` comes from the FINGERPRINT, not
        // from the row: `dailyMetric` stores the skin DEVIATION, and the skin baseline folds the nightly
        // MEAN, so the mean is carried in the fingerprint precisely so a reused day re-seeds it identically.
        //
        // `cachedSleep` / `workouts` / the per-session maps are deliberately EMPTY. The persist phase below
        // treats those as "what this pass produced", and a reused day produced nothing — its sleep rows and
        // detected workouts are already stored and must be left exactly where they are. That is also why
        // the reconciliation below is scoped to `scannedDays` rather than the whole window.
        for day in reusedDays {
            guard let row = persistedRowsByDay[day] else { continue }   // preloaded above; belt-and-braces
            let fp = storedFingerprints[day]
            readOwnerByDay[day] = (fp?.ownerId ?? deviceId, 0)
            resolvedScoreOwnerByDay[day] = fp?.ownerId ?? deviceId
            nightlyHrvByDay[day] = row.avgHrv
            nightlyRhrByDay[day] = row.restingHr.map(Double.init)
            nightlyRespByDay[day] = row.respRateBpm
            nightlySkinByDay[day] = fp?.nightlySkinC
            scoredNights.append((daily: row, strain: row.strain, cachedSleep: [],
                                 workouts: [], nightlySkin: fp?.nightlySkinC,
                                 sessionMotion: [:], sessionSleepState: [:], hrvDiag: nil,
                                 detectionFunnel: nil))
        }
        // The days this pass actually re-derived. Every window-wide cleanup below is scoped to these,
        // because each of them deletes-then-reinserts and a reused day has nothing to re-insert.
        let scannedDays = Set(scanned.map { $0.result.daily.day })
        let reusedDaySet = Set(reusedDays)
        diagnosticSink?("re-score: scanned \(scannedDays.count) day(s), reused \(reusedDays.count) "
            + "unchanged day(s) from their stored scores", nil)
        NSLog("[FREEZE-DIAG] analyzeRecent day-skip: scanned=\(scannedDays.count) reused=\(reusedDays.count) of \(maxDays)")

        // D1: WHY each day was re-derived rather than reused. `day-skip` above reports the COUNT, which
        // on a real device was indistinguishable between "the cache is broken" and "a scoring input
        // legitimately moved". Five of the six conditions are pass-global — they pass for every day or
        // fail for every day — so the summary's shape names the cause outright: 20 misses on a
        // pass-global condition is a global invalidation, 1–2 on `inputRevision` is ordinary new data.
        for entry in reuseMissesByDay {
            diagnosticSink?("reuse day=\(entry.day) reuse=false miss=\(entry.misses.joined(separator: ","))",
                            nil)
        }
        if !reuseMissesByDay.isEmpty {
            var missCounts: [String: Int] = [:]
            for entry in reuseMissesByDay {
                for miss in entry.misses { missCounts[miss, default: 0] += 1 }
            }
            // Sorted by count then name so two runs of the same shape print identically and a diff of
            // two logs shows what actually moved.
            let breakdown = missCounts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
                .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            // `walked` is the whole window; `recomputed` is what actually cost anything. The first
            // draft of this line printed `scanned=` for the re-derived count AND `recomputed=` for the
            // same number, which read as if two different things happened to agree.
            let line = "reuse summary: walked=\(maxDays) reused=\(reusedDays.count) "
                + "recomputed=\(scannedDays.count) | miss: \(breakdown)"
            diagnosticSink?(line, nil)
            NSLog("[FREEZE-DIAG] \(line)")
            // The same first-miss diff as the early NSLog above, repeated into the shareable strap log —
            // which the detached loop cannot reach, the sink being main-actor bound. Named with its day,
            // since `weight` makes the signature partly per-day.
            if let firstSemanticMismatch {
                let diff = Self.semanticSignatureDiff(
                    stored: firstSemanticMismatch.stored,
                    current: semanticSignature(firstSemanticMismatch.day))
                let detail = diff.isEmpty ? "(no field differs — parse failure?)" : diff.joined(separator: ", ")
                let semanticLine = "reuse semantic diff (first miss, day=\(firstSemanticMismatch.day)): \(detail)"
                diagnosticSink?(semanticLine, nil)
                NSLog("[FREEZE-DIAG] \(semanticLine)")
            }
        }
        // TEMP DIAGNOSTIC (D3) — where the time AFTER the day loop goes.
        //
        // Measured on a real 2.8 GB library once per-day reuse worked: a pass that re-derived exactly ONE
        // day still took 93 s, and only 35–54 s of that was the day. The remainder is everything from here
        // to EXIT, and it is FIXED cost — it folds baselines over the whole history, re-scores recovery for
        // all 21 days against the new baseline, and persists the window, none of which gets cheaper because
        // reuse worked. That makes this phase the largest single item in a steady-state pass, and nothing
        // in it was timed.
        //
        // Attribution before any fix: the candidates here (a daily-metrics read spanning all of time, two
        // 100 000-row workout reads, the self-heal, pass 2, the persist tail, a full repo.refresh) are all
        // plausible and that is exactly the problem. Three hypotheses in this investigation were reasoned
        // rather than measured, and all three were wrong.
        //
        // One line per pass. The marks are placed on statement boundaries, never between a comment block
        // and the code it explains.
        //
        // The first run answered the question and raised a sharper one. Of a 33–71 s post-loop, `persist`
        // was 33–71 s and every other phase under 1.1 s — including the two this file guessed at, the
        // all-of-time Apple daily read (0.18–0.87 s) and the pair of 100 000-row workout reads
        // (0.28–1.08 s). Both suspicions wrong, which is why they were measured. `persist` is therefore
        // split further, and the split has to explain two things the aggregate could not: it does NOT
        // scale with days re-derived (33.6 s for a 21-day pass, 71.3 s for a 2-day one), and it GROWS
        // across passes in one session (33.6 → 57.4 → 60.2 → 67.9 → 71.3 s). Something accumulates that
        // is not this pass's own workload.
        // Read alongside the phase timer, not instead of it: the timings say WHICH write got slower,
        // this says whether the file underneath them is growing. A `-wal` that cannot checkpoint —
        // a dashboard always holds a reader snapshot open — is the standing explanation for a write
        // path that degrades within one session, and it is testable rather than plausible.
        let diagFootprintBefore = await store.databaseFootprintMB()
        var diagPhaseLast = Date()
        var diagPhases: [String] = []
        func diagMark(_ name: String) {
            let now = Date()
            diagPhases.append("\(name)=\(String(format: "%.2f", now.timeIntervalSince(diagPhaseLast)))s")
            diagPhaseLast = now
        }
        // A defer rather than a trailing call: the phases already measured are worth having even when a
        // later step returns early or throws, which is precisely the pass whose cost is unexplained.
        defer {
            if !diagPhases.isEmpty {
                NSLog("[FREEZE-DIAG] post-loop: " + diagPhases.joined(separator: " "))
            }
        }

        // ── Seed the baseline from the UNION of imported nightly history + the values just computed.
        // THIS is the BLE-only recovery fix: the "-noop" nightly avgHrv/restingHr finally feed the
        // baseline so a strap-only user crosses Baselines.minNightsSeed and recovery lights up.
        // IMPORTED values win per day: write them first, then fill ONLY days the import doesn't cover
        // (Swift has no putIfAbsent , `dict[day] == nil` is true only when the KEY is absent, so a day
        // imported with a nil avgHrv stays imported, not overwritten by the computed value).
        var histHrvByDay: [String: Double?] = [:]
        var histRhrByDay: [String: Double?] = [:]
        var histRespByDay: [String: Double?] = [:]
        for d in hist {
            histHrvByDay[d.day] = d.avgHrv
            histRhrByDay[d.day] = d.restingHr.map(Double.init)
            histRespByDay[d.day] = d.respRateBpm
        }
        Self.mergeNightlyIntoHistory(&histHrvByDay, nightlyHrvByDay)
        Self.mergeNightlyIntoHistory(&histRhrByDay, nightlyRhrByDay)
        Self.mergeNightlyIntoHistory(&histRespByDay, nightlyRespByDay)
        // Which SOURCE measured each night's respiration — the input `Baselines.deviceEraEpoch` (#459)
        // needs, and respiration is now a metric that requires it: a WHOOP export reports its OWN measured
        // rate (~16.1 for this history) while an Oura ring reports the rate its firmware measured (~14.6),
        // and NOOP's own RSA estimate is a third method again. Pooling them in one 28-day baseline turns a
        // strap SWITCH into a ~3σ illness-ward step against a ~0.52 bpm spread — a device artifact scored
        // as physiology, which is exactly the failure #459 named for HRV (Oura RMSSD ~120-155 ms vs WHOOP
        // ~72-112 ms).
        //
        // `resolvedScoreOwnerByDay` — THIS PASS's freshly resolved per-day owner (`resolveDayOwner`,
        // straight off `DayOwnerResolver`, BEFORE any re-homing) — must win over `hist`, not just fill its
        // gaps. `hist` is `store.dailyMetrics(deviceId: deviceId, ...)`: every row in it is already stored
        // under THIS device's own id, by construction, because that is where `analyzeRecent` writes every
        // day's result once scored — an Oura-owned day scored on a PRIOR run is filed there exactly the
        // same as a WHOOP-owned one. Filling from `hist` first (the value-priority order, correct for
        // `histRespByDay` because an import legitimately outranks a computed value) would tag that day
        // "whoop" for every re-score after its first, which is precisely the "brand is lost once a
        // wearable day is re-homed under the computed WHOOP id" trap `deviceEraEpoch`'s own contract warns
        // against — it would neuter era-scoping for any day already scored once, i.e. almost all of them in
        // steady state. `hist` still fills the days OUTSIDE this pass's scan window (older than `maxDays`),
        // where no fresher source is available and the pre-existing storage id is the best guess.
        var respSourceByDay: [String: String] = [:]
        for (day, owner) in resolvedScoreOwnerByDay { respSourceByDay[day] = owner }
        for d in hist where respSourceByDay[d.day] == nil { respSourceByDay[d.day] = deviceId }
        // rhr/resp/skin honour the Charge-wide recalibration epoch (noop.recoveryBaselineEpoch); 0 = no-op,
        // so this is byte-identical to the plain fold until the user taps Recalibrate, at which point the
        // whole Charge build-up (HRV + resting HR + resp + skin) re-anchors together.
        let recoveryEpoch = Baselines.recoveryBaselineEpoch()
        let hrvDayKeys = histHrvByDay.keys.sorted()                         // chronological "yyyy-MM-dd"
        let hrvSeq = hrvDayKeys.map { histHrvByDay[$0]! }                   // chronological [Double?]
        let rhrDayKeys = histRhrByDay.keys.sorted()
        let rhrSeq = rhrDayKeys.map { histRhrByDay[$0]! }
        let respDayKeys = histRespByDay.keys.sorted()
        let respSeq = respDayKeys.map { histRespByDay[$0]! }
        // Skin-temp baseline is on-device-only (imported rows carry skinTempDevC, not the raw mean),
        // so fold purely over the pass-1 nightly means in chronological order.
        let skinDayKeys = nightlySkinByDay.keys.sorted()
        let skinSeq = skinDayKeys.map { nightlySkinByDay[$0]! }
        // Resp baseline gated on `usable`: RecoveryScorer includes the resp term whenever a
        // baseline object is present , a CALIBRATING (<4-night) baseline would let one noisy
        // RSA night move recovery (mirrors the skin-temp use-site gate; honest cold-start).
        // The respiration baseline is scoped to the CURRENT device era. `deviceEraEpoch` returns 0.0 for a
        // single-brand history — every WHOOP-origin id (import, strap, the "-noop" computed sibling, the
        // Apple/HC riders) buckets to one brand — so a WHOOP-only user folds byte-identically to before;
        // only a history that actually crosses brands is truncated. `max` with the manual Recalibrate
        // epoch keeps whichever cut is LATER, since both mean "ignore nights before this".
        // KNOWN GAP, and pre-existing: the bucket is per BRAND, so it does not separate an imported WHOOP
        // vendor rate from NOOP's own RSA estimate on WHOOP nights — two methods that were already pooled
        // before this change and still are. #459's primitive is likewise still unwired for the HRV and
        // resting-HR baselines it was written for; that is #459's own scope, not this change's.
        let respEraEpoch = Baselines.deviceEraEpoch(respDayKeys.map { (day: $0, sourceId: respSourceByDay[$0] ?? deviceId) })
        let respFold = Baselines.foldHistory(respSeq, dayKeys: respDayKeys, cfg: respCfg,
                                             baselineEpoch: max(recoveryEpoch, respEraEpoch))
        // Skin-temp gated the same way for consistency: its only use-site re-checks `.usable`
        // (AnalyticsEngine's skinTempDevC guard) so this is belt-and-suspenders, but it stops a
        // future use-site from trusting a CALIBRATING baseline. (PR #97 review.)
        let skinFold = Baselines.foldHistory(skinSeq, dayKeys: skinDayKeys, cfg: skinCfg, baselineEpoch: recoveryEpoch)
        let baselines2 = AnalyticsEngine.ProfileBaselines(
            // HRV honours noop.hrvBaselineEpoch; rhr/resp/skin honour noop.recoveryBaselineEpoch via their
            // parallel day keys, so the manual Recalibrate restarts the whole Charge build-up together.
            hrv: Baselines.foldHistory(hrvSeq, dayKeys: hrvDayKeys, cfg: hrvCfg),
            restingHR: Baselines.foldHistory(rhrSeq, dayKeys: rhrDayKeys, cfg: rhrCfg, baselineEpoch: recoveryEpoch),
            resp: respFold.usable ? respFold : nil,
            skinTemp: skinFold.usable ? skinFold : nil)

        // Real (non-detected) workouts in the scored window, used to de-duplicate detected bouts so a
        // user who BOTH has real sessions AND wears the strap doesn't see the same session twice (the
        // per-day merge precedence does not cover the workout table). This covers BOTH directions of
        // the cross-source duplicate (#107): the strap source carries imported WHOOP rows AND manual /
        // re-labelled rows (both written under `deviceId`), and apple-health carries Health imports ,
        // a detected bout overlapping ANY of them is skipped below. Port of the Android dedup block.
        // (`computedId` is bound once above, before the off-actor scan loop.)
        let windowStart = now - maxDays * 86_400 - 30 * 3_600
        diagMark("baselines")
        var realWorkouts = (try? await store.workouts(deviceId: deviceId, from: windowStart,
                                                       to: now, limit: 100_000)) ?? []
        realWorkouts += (try? await store.workouts(deviceId: "apple-health", from: windowStart,
                                                    to: now, limit: 100_000)) ?? []

        // ── Pass 2: re-score ONLY recovery against the now-seeded baseline (cheap, baseline-dependent);
        // every other field was computed once in pass 1. Recovery stays nil until the HRV baseline is
        // usable (≥ minNightsSeed valid nights) , honest cold-start, via RecoveryScorer's usable gate.
        var out: [Computed] = []
        var dailies: [DailyMetric] = []
        var cachedSleep: [CachedSleepSession] = []
        var workoutRows: [WorkoutRow] = []
        // #510: backfilled fields for a REAL (non-detected) row a dropped bout collided with, grouped by
        // the deviceId it must be upserted under (see the collision branch below) — never mixed into
        // `workoutRows`, which is always written under `computedId`.
        var backfilledByDevice: [String: [WorkoutRow]] = [:]
        // Rest composite (0–100) per computed night, persisted as the `sleep_performance` metric
        // series so the dashboard's Rest score reflects the new composite, not raw efficiency.
        var restPoints: [MetricPoint] = []
        diagMark("workoutRead")
        // User-corrected sleep windows override the detected sleep when scoring a day's sleep aggregates,
        // so Rest + recovery honor the edit , not just the Sleep tab's session view. An edited block
        // substitutes its detected twin (matched by the stable detected startTs) before totals recompute.
        // Scope (#318): this only covers the COMPUTED ("-noop") source , the days noop scores itself. An
        // edit to an IMPORTED (WHOOP-export) night updates the displayed session, but its dashboard
        // recovery/performance come verbatim from the export and are NOT recomputed here (we don't
        // reproduce WHOOP's cloud scoring). That's an accepted limitation, documented on the PR.
        // Self-heal any night edited before its raw streams synced (see `Repository.selfHealEditedStages`):
        // re-derive stages from the now-available raw over the night's locked bounds, then return the
        // refreshed rows so the daily aggregate below scores the corrected breakdown. A no-op for nights
        // already staged from raw (idempotent) and for imported nights (raw never dense). This MUST run
        // before the scoring loop so the healed stages flow into Rest/recovery this same pass.
        let editedRows = await repo.selfHealEditedStages(from: windowStart, to: now)
        // #299: `editsByStart` is now built PER DAY inside the scoring loop (scoped to the day each edit
        // belongs to), NOT window-wide here. sleepEditedDaily folds any edited row that isn't a twin of THIS
        // day's detected sessions in as a "manual" block, so a window-wide edit set let ONE user edit /
        // hand-logged nap substitute its total onto EVERY night in the window (incl. no-sleep nights) —
        // pinning totalSleepMin to a constant. See the loop below.

        // Provenance sets for the honest By-Day badge + the per-day diagnostic source token. `hist` is the
        // imported daily rows under `deviceId` (the WHOLE imported history, read above for the baseline) ,
        // a non-nil row means a WHOOP export covers that day and WINS the dashboard merge over our computed
        // row (Repository.mergeDaily: imports win field-by-field). Apple-Health daily rows are the same for
        // the Apple brand. Both are key-presence sets only (no values leave), so the lookup is O(1) per day
        // and nothing about the imported numbers is exposed. WHOOP wins over Apple, matching the merge's
        // source priority (whoopImport 0 < appleHealth 2 in DailyMetricSource.vitalPriority).
        let importedWhoopDays = Set(hist.map { $0.day })
        diagMark("selfHeal")
        // The WHOLE apple-health daily history, chronological. Used both as a key-presence set for the
        // By-Day badge AND as the SDNN+RHR input for the Apple-Watch recovery fold below (a watch-only user
        // has these daily aggregates but no raw stream, so the raw-HR scoring loop never touched them).
        let appleRows = ((try? await store.dailyMetrics(deviceId: Repository.appleHealthSource,
                                                        from: "0000-01-01", to: "9999-12-31")) ?? [])
            .sorted { $0.day < $1.day }
        let appleHealthDays = Set(appleRows.map { $0.day })

        // Recovery (Charge) test mode (Group G): read the zero-cost gate ONCE here (a single Bool) before
        // the scoring loop. When false (the default), no Charge term-breakdown trace is built and the score
        // path is byte-identical. When true, each scored night emits its Charge breakdown tagged `.recovery`
        // via `recoveryTrace`, which returns the SAME score `recomputeRecovery` computes (it reuses
        // RecoveryScorer.recovery verbatim), so the headline Charge number is unaffected.
        let recoveryTraceActive = TestCentre.active(.recovery)
        // CAPTURE-B (#814/#799): the universal dayOwner line rides every export, so its gate is "ANY mode
        // active" (TestCentre.active(.universal) == anyActive). Read once here, like the other gates.
        let universalTraceActive = TestCentre.active(.universal)
        // Workouts & GPS test mode (#975): read the zero-cost gate ONCE before the scoring loop so the
        // detected-bout persist/drop decision can emit ONE `.workouts` line per derived bout. Without this
        // the auto path produced NO trace at all (the "mode was on but produced NO trace" report), so an
        // "auto workout appeared then vanished" could not be explained from an export. Diagnostic only.
        let workoutsTraceActive = TestCentre.active(.workouts)
        diagMark("appleRead")
        for night in scoredNights {
            // #299: scope the edits to THIS day before folding. A userEdited row / hand-logged nap belongs
            // to exactly ONE day — the day its night ENDS on, matching the daily's end-day bucket. `endTs`
            // is stable under a bedtime edit (only the onset/`startTsAdjusted` moves), so end-day is the
            // right key. Filtering here keeps a single-night edit overriding only its OWN night instead of
            // every night. `effectiveStartTs` (the #318 user-corrected onset) is preserved on the row.
            // A REUSED day (#launch-rescore) must NOT be re-folded. `night.daily` is the row the last scan
            // already persisted, so the edit substitution is baked into it; folding again would apply the
            // same edited block a second time — and because a reused day carries no `detected` sessions,
            // the fold could not even recognise an edit as the twin of its detected session and would add
            // it as a separate "manual" block on top of the total it is already in. Recovery below IS still
            // recomputed for it: that term is baseline-dependent, and the baseline moves whenever any day in
            // the window was re-scored, so every day has to be re-scored against the current one.
            let isReusedDay = reusedDaySet.contains(night.daily.day)
            var dayEditedRows: [CachedSleepSession] = []
            let daily: DailyMetric
            if isReusedDay {
                daily = night.daily
            } else {
                // #299: scope the edits to THIS day before folding. A userEdited row / hand-logged nap belongs
                // to exactly ONE day — the day its night ENDS on, matching the daily's end-day bucket. `endTs`
                // is stable under a bedtime edit (only the onset/`startTsAdjusted` moves), so end-day is the
                // right key. Filtering here keeps a single-night edit overriding only its OWN night instead of
                // every night. `effectiveStartTs` (the #318 user-corrected onset) is preserved on the row.
                dayEditedRows = Self.editedRowsForDay(editedRows, day: night.daily.day, tzOffsetSeconds: tzOffset)
                let editsByStart = Dictionary(dayEditedRows.map { ($0.startTs, $0) }, uniquingKeysWith: { a, _ in a })
                daily = sleepEditedDaily(night.daily, detected: night.cachedSleep, editsByStart: editsByStart,
                                         habitualMidsleepSec: habitualMidsleepSec)
            }
            let recovery = recomputeRecovery(daily, baselines2)
            // Charge term-breakdown trace (Group G): only when the Recovery test mode is on. Emits which
            // term moved Charge and which was nil and forced the renorm, tagged `.recovery`. The trace's
            // score is RecoveryScorer.recovery verbatim, so the `recovery` written above is unchanged.
            if recoveryTraceActive {
                for line in recoveryTraceLines(daily, baselines2) { diagnosticSink?(line, .recovery) }
            }
            let skinDev = recomputeSkinTempDev(night.nightlySkin, baselines2.skinTemp)
            let source = DaySource.classify(day: daily.day, importedWhoopDays: importedWhoopDays,
                                            appleHealthDays: appleHealthDays)
            // SHARED CONTRACT enrichment: the ordered Charge driver list + the relative skin-temp marker,
            // built from the SAME inputs `recomputeRecovery` reads so the rows can never disagree with the
            // headline. Both are empty/nil pre-baseline (cold-start), matching the score's own null-honesty.
            let drivers = recomputeChargeDrivers(daily, baselines2)
            let skinRel = RecoveryScorer.skinTempRelative(deviationC: skinDev)
            // Honest per-day Charge confidence (A3): the strap night reads `.solid`/`.building`/`.calibrating`
            // off the HRV baseline state rather than a blanket `.solid`, so a thin/provisional baseline shows
            // EST. not REL. Pure presentation upstream of the UI; the score itself is unchanged.
            let chargeConf = ScoreConfidence.charge(recovery: recovery, hrvBaseline: baselines2.hrv)
            out.append(Computed(day: daily.day, recovery: recovery, strain: night.strain,
                                sleepMin: daily.totalSleepMin, hrv: daily.avgHrv,
                                rhr: daily.restingHr, source: source, confidence: chargeConf,
                                drivers: drivers, skinTempRel: skinRel))
            // ── Per-day scoring diagnostic (Sleep overhaul §2.5) ─────────────────────────────────────
            // ONE concise, privacy-safe line per scored day into the shareable strap log: the day key, the
            // FINAL computed total-sleep minutes (after any edit substitution), how many sleep blocks the
            // detector matched on the day, and the provenance of the dashboard headline. Counts + a rounded
            // minute only , no HR/HRV/timestamps , so the next report ships PROOF of what was computed per
            // day (the project's log-failures-not-successes blind spot) and lets us settle the "Rest repeats
            // across days" question with data rather than a guess. Gated by the existing strap-log export.
            let tsmLog = daily.totalSleepMin.map { String(Int($0.rounded())) } ?? "nil"
            // #386: the banked stage split + efficiency ride beside the rollup, so a "homepage disagrees
            // with the Sleep tab" report is self-diagnosing from the export alone — totalSleepMin vs the
            // deep+rem+light sum is the identity both screens must agree on, now verifiable per pass, per
            // day, without screenshots. Rounded minutes only (same privacy class as the rest of the line);
            // stages=nil when the day has no banked stage split (an unstaged or imported-total-only day).
            let effLog = daily.efficiency.map { String(format: "%.2f", $0) } ?? "nil"
            diagnosticSink?("sleep day=\(daily.day) totalSleepMin=\(tsmLog) "
                            + "stages=\(Self.sleepStagesLogToken(deep: daily.deepMin, rem: daily.remMin, light: daily.lightMin)) "
                            + "eff=\(effLog) "
                            + "matched=\(night.cachedSleep.count) source=\(source.logToken)", nil)
            // #674/#1244: flag a COMPUTED day carrying a sleep total with NO matched session — the folded
            // edited/hand-logged block on a day the detector staged nothing (see sleepDivergenceLogLine).
            // Scoped to computed days: an imported-total-only day legitimately has a total without our
            // sessions, so it is NOT a divergence.
            // `!isReusedDay`: a reused day carries no `cachedSleep` BY CONSTRUCTION (it was not staged this
            // pass), so this test would fire on every reused night and report a divergence that does not
            // exist. The line is about a day this pass staged nothing FOR — not about a day it never looked at.
            let dayImported = importedWhoopDays.contains(daily.day) || appleHealthDays.contains(daily.day)
            if !isReusedDay, !dayImported, let tsm = daily.totalSleepMin, night.cachedSleep.isEmpty {
                diagnosticSink?(Self.sleepDivergenceLogLine(day: daily.day,
                                                            totalSleepMin: Int(tsm.rounded()),
                                                            editFold: dayEditedRows.count), nil)
            }
            // #195: one always-on line per scored night with the computed HRV value + the window it used,
            // so an "HRV reads high / deep-sleep window not changing" report is self-diagnosing straight
            // from the strap log — the whole-night vs deep-sleep value, and `avgHrv=nil window=deep` when a
            // deep-window night has no detected deep sleep — without needing the HRV & Autonomic test mode.
            // Counts-only (a rounded ms + the window), PII-free; byte-identical to the Kotlin line.
            let hrvLog = daily.avgHrv.map { String(format: "%.1f", $0) } ?? "nil"
            diagnosticSink?("hrv day=\(daily.day) window=\(deepHrvWindow ? "deep" : "whole") avgHrv=\(hrvLog)", nil)
            // #195: the whole-night HRV cleaning summary built in loop 1 (rmssd vs sdnn / cleaning counts).
            // #1008: on an over-count night this carries a second `hrv rrsample …` line, \n-joined at the
            // build site; split it back into one diagnosticSink call per line so each is its own log line.
            if let hrvDiagLine = night.hrvDiag {
                for line in hrvDiagLine.split(separator: "\n", omittingEmptySubsequences: true) {
                    diagnosticSink?(String(line), nil)
                }
            }
            // ── CAPTURE-B: universal dayOwner self-diagnostic (#814/#799) ────────────────────────────────
            // ONE line per scored day, tagged `.universal` so it rides EVERY Test Centre export regardless
            // of which mode is on. It pins down the read/write split #814 is about: `readId` is the owner
            // this day was actually read+scored from, `writeActiveId` is the registry's active id the
            // Collector writes raw under; when they DIVERGE on a day with HR rows, the dashboard and the
            // strap are reading two different namespaces. `hrRows` is the owner's HR-row count for the night
            // window; `provenance` says what backed the day (strap-measured vs a WHOOP/Apple import).
            // Counts + ids only (ids are local "my-whoop"/"whoop-…"/import tokens, no PII; LiveState also
            // scrubs). Verbatim format so the export parser reads it.
            // Gated on `.universal` (== any Test Centre mode active) so it rides every export but stays OFF
            // the strap log in normal use, matching the sleep/recovery/steps emitters' call-site gate. The
            // gate is one UserDefaults bool; the line is only built when it passes.
            if universalTraceActive {
                let owned = readOwnerByDay[daily.day]
                diagnosticSink?(Self.dayOwnerLine(
                    day: daily.day, readId: owned?.owner ?? regActiveId, writeActiveId: regActiveId,
                    hrRows: owned?.hrRows ?? 0, importedWhoop: importedWhoopDays.contains(daily.day),
                    importedApple: appleHealthDays.contains(daily.day)), .universal)
            }
            dailies.append(daily.with(recovery: recovery, skinTempDevC: skinDev,
                                      skinTempC: daily.skinTempC))
            if let rest = AnalyticsEngine.Rest.composite(daily: daily) {
                restPoints.append(MetricPoint(day: daily.day, key: "sleep_performance", value: rest))
            }
            // #103: persist the SpO₂ candidate @82 nightly mean to metricSeries as "spo2_candidate" so the
            // Blood Oxygen tile can surface it as a "strap estimate (unverified)" fallback when the toggle
            // is ON. Written under the "-noop" computed device ID, never to `spo2Pct` — the candidate has
            // split cross-device evidence and stays behind the experimental display toggle.
            if let cand = spo2CandidateByDay[daily.day] {
                restPoints.append(MetricPoint(day: daily.day, key: "spo2_candidate", value: Double(cand)))
            }
            // #1118: persist the HRV over-count flag (1/0) so the HRV card can mark an over-counted 4.0
            // night's reading "unverified" until the two-channel de-dup lands. 0 written on a clean night
            // (not just absent) so a night that flips clean on re-score clears its prior flag.
            if let oc = hrvOverCountByDay[daily.day] {
                restPoints.append(MetricPoint(day: daily.day, key: "hrv_rr_overcount", value: oc ? 1.0 : 0.0))
            }
            // #1169 shadow metric: the primary-session mean RHR, stored beside the shipped floor
            // (daily.restingHr) under the "-noop" computed ID. Instrumentation only — never shown, never
            // scored — so the mean-vs-floor comparison the issue needs can be evaluated from exports later.
            if let v = primarySessionRHRByDay[daily.day] {
                restPoints.append(MetricPoint(day: daily.day, key: "rhr_primary_session", value: v))
            }
            // #1169: its coverage inputs beside the mean — valid-sample count + primary-session duration (s)
            // — so a thin-coverage night can be down-weighted in the later holdout. Raw inputs, not a fraction.
            if let cov = primarySessionRHRCoverageByDay[daily.day] {
                restPoints.append(MetricPoint(day: daily.day, key: "rhr_primary_session_valid_samples", value: Double(cov.validSamples)))
                restPoints.append(MetricPoint(day: daily.day, key: "rhr_primary_session_duration_s", value: cov.durationSec))
            }
            cachedSleep.append(contentsOf: night.cachedSleep)
            // Persist the detected workouts the pipeline already computes (previously discarded).
            // Skip any bout overlapping a real imported/manual workout so import+wear users don't
            // double-count. sport = "detected"; energyKcal is the APPROXIMATE Keytel/BMR total.
            // #1545: where the detector lost every candidate workout on this day, emitted BEFORE the
            // per-bout loop so it is present even when that loop runs zero times — which is exactly the
            // report it exists for. The `effort bout` line below explains a bout that exists; a strap log
            // showing 37 days and no workouts at all previously carried nothing to explain the absence.
            if let f = night.detectionFunnel {
                diagnosticSink?(WorkoutDetector.detectionFunnelLine(day: daily.day, funnel: f), nil)
            }
            for s in night.workouts {
                let durMin = max(0, (s.end - s.start) / 60)
                let avgBpm = Int(s.avgHR)
                // #1545: always-on, one line per detected bout naming what this Effort was SCORED AGAINST.
                // A user reporting "my hard session scored 1.7" cannot currently see the HRmax that set the
                // zone boundaries, where it came from, or whether the strap even saw most of the bout — and
                // those three answers separate the three different causes ("the floor is doing its job",
                // "your HRmax is wrong", "the sensor dropped out"). Reversing the arithmetic out of the
                // displayed score is what diagnosing #1545 actually took. Same privacy class as the sibling
                // `sleep day=` line: a day key, a duration, bpm and percentages.
                diagnosticSink?(WorkoutDetector.boutCalibrationLine(
                    day: daily.day, durMin: durMin, hrmax: s.hrmax, hrmaxSource: s.hrmaxSource,
                    avgHRRPct: s.avgHRRPct, hrCoveragePct: s.hrCoveragePct, strain: s.strain), nil)
                // The overlap test is bare time overlap (any source), so a detected bout collapses against a
                // manual session even though their SPORTS differ ("detected" vs the user's sport) , the
                // #975 "two workouts, one vanished" seam. Find the collider so the trace can name its source.
                if let hit = realWorkouts.first(where: { s.start < $0.endTs && $0.startTs < s.end }) {
                    // #510: the detected bout's own avgHR/calories/maxHR/strain come from the SAME
                    // motion+HR trace the detector used to find this activity's actual boundaries —
                    // often a tighter match than the colliding row's own [startTs,endTs] (e.g. a manual
                    // entry typed in afterward, whose guessed boundaries can clip most of the real
                    // HR-rich period and leave the display-time strap-HR fill's raw window read too
                    // thin, silently showing no HR/calories). Same natural key (deviceId, startTs,
                    // sport), so the upsert below updates the existing row in place rather than
                    // duplicating it.
                    let backfilled = WorkoutDetector.backfillWorkout(
                        hit, avgBpm: avgBpm, peakHR: s.peakHR, caloriesKcal: s.caloriesKcal, strain: s.strain)
                    let didBackfill = backfilled != hit
                    if didBackfill {
                        // realWorkouts merges TWO device groups (see above): the strap's own `deviceId`
                        // (imported WHOOP rows AND manual/re-labelled ones) and "apple-health" — the
                        // Swift WorkoutRow carries no deviceId of its own, so route by that same split.
                        let hitDeviceId = hit.source == "apple-health" ? "apple-health" : deviceId
                        backfilledByDevice[hitDeviceId, default: []].append(backfilled)
                    }
                    if workoutsTraceActive {
                        diagnosticSink?(WorkoutsTrace.detectedBoutLine(
                            verdict: didBackfill ? "droppedOverlapBackfilled" : "droppedOverlap",
                            durMin: durMin, avgBpm: avgBpm,
                            overlapSource: WorkoutSource.sourceLabel(hit)), .workouts)
                    }
                    continue
                }
                workoutRows.append(WorkoutRow(startTs: s.start, endTs: s.end,
                                              sport: "detected", source: computedId,
                                              durationS: s.durationS, energyKcal: s.caloriesKcal,
                                              avgHr: avgBpm, maxHr: s.peakHR,
                                              strain: s.strain, distanceM: nil,
                                              zonesJSON: nil, notes: nil, steps: nil))
                if workoutsTraceActive {
                    diagnosticSink?(WorkoutsTrace.detectedBoutLine(
                        verdict: "persisted", durMin: durMin, avgBpm: avgBpm), .workouts)
                }
            }
        }

        // ── Apple-Watch recovery fold (M1 "Watch as a device") ──────────────────────────────────────
        // A watch-only user has apple-health DAILY aggregates (SDNN HRV + resting HR) but no raw stream, so
        // the raw-HR scoring loop above never touched their days and the import left `recovery: nil`. Fill
        // that one gap from the daily aggregate vs the person's own baseline (the cross-lane `WatchRecovery`
        // engine, which mirrors our Charge recovery shape). WHOOP/computed recovery MUST keep winning where
        // both exist, so we skip any day a strap already OWNS: every day the raw-HR loop scored (in `out`,
        // even a cold-start nil-recovery night , that day belongs to the strap, not the watch) plus every
        // WHOOP-imported day (the export carries its own recovery). The result is written back onto the
        // apple-health rows so the source-aware dashboard reads it, and the watch-only days are appended to
        // `out` so the By-Day list shows them with their honest confidence.
        let strapRecoveryDays = Set(out.map { $0.day }).union(importedWhoopDays)
        let watchScored = Self.watchRecoveries(appleRows: appleRows, strapRecoveryDays: strapRecoveryDays)
        // Persist the recovery onto each apple-health row that gained one (nil-recovery days are left as-is,
        // never fabricated). Rebuild the row with the new recovery; every other field is unchanged.
        var appleRecoveryRows: [DailyMetric] = []
        let appleByDay = Dictionary(appleRows.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
        for w in watchScored {
            guard let recovery = w.recovery, let row = appleByDay[w.day] else { continue }
            appleRecoveryRows.append(row.with(recovery: recovery, skinTempDevC: row.skinTempDevC,
                                               skinTempC: row.skinTempC))
            // Surface the watch-only day in the By-Day list with its watch provenance + confidence.
            out.append(Computed(day: w.day, recovery: recovery, strain: row.strain,
                                sleepMin: row.totalSleepMin, hrv: row.avgHrv, rhr: row.restingHr,
                                source: .appleHealth, confidence: w.confidence))
        }
        if !appleRecoveryRows.isEmpty {
            _ = try? await store.upsertDailyMetrics(appleRecoveryRows, deviceId: Repository.appleHealthSource)
        }

        // #277 migration: the loop now keys days by the LOCAL calendar day. A prior run (before this
        // fix) wrote the SAME period under UTC-day keys, so without a cleanup an off-by-one UTC row and
        // the new local row would coexist as duplicate days. We reconcile the COMPUTED ("-noop") daily
        // rows across the recompute window [oldest enumerated local day, newest]: UPSERT the freshly
        // local-keyed rows FIRST, then delete only the STALE rows the new run no longer produces.
        //
        // #521: the old order was delete-the-whole-window THEN re-upsert , a non-atomic gap where a
        // concurrent refresh could read `repo.days.count` LOWER (post-delete) then HIGHER (post-upsert),
        // which the Today inbox mistook for new history and announced as "New data added" on a loop. By
        // upserting before deleting, the row count is MONOTONIC (it only grows or holds during a
        // recompute), so recompute churn can never masquerade as growth. Scoped to the computed source
        // only , imported "my-whoop" rows are never touched (a BLE-only WHOOP 4.0 user has no import
        // fallback). Rows older than the window keep their old keys (cosmetic off-by-one, acceptable).
        // yyyy-MM-dd sorts chronologically, so the string range IS a date range.
        let oldestDay = AnalyticsEngine.dayString(nowLocalMidnight - (maxDays - 1) * 86_400,
                                                  offsetSec: tzOffset)
        let newestDay = AnalyticsEngine.dayString(nowLocalMidnight, offsetSec: tzOffset)

        // ── Source-only Charge/Rest fold for wearable imports (Oura / Fitbit / Garmin / Health Connect) ──
        // Same honesty gap the watch fold above closes (#823), extended to the other import-only sources: a
        // user who ONLY imports an Oura/Fitbit/Garmin export (or Health Connect) has DAILY aggregates (HRV +
        // resting HR) but no raw HR stream, so the raw-HR loop never scored their days and the import left
        // recovery nil , Today/Recovery show a blank Charge. Score it from the daily aggregate vs the person's
        // own baseline with the SAME `watchRecoveries` engine the apple fold uses (which reuses
        // RecoveryScorer.recovery verbatim), then write the score under the COMPUTED ("-noop") source so it
        // merges onto Today exactly like a live day. The imported daily row keeps its raw values untouched;
        // the computed row carries the NOOP-derived Charge + the Rest composite. HONEST DATA: the engine
        // returns nil + calibrating until the HRV baseline is usable, so an import-only day stays calibrating
        // rather than faking a number. The strap and a real WHOOP/Apple import keep winning , we skip any day
        // already scored this pass (`dailies`) or owned by a WHOOP/Apple import. The window matches the
        // computed reconcile below, so the fold's rows survive the stale-row eviction.
        var importScoredDays = Set(dailies.map { $0.day }).union(importedWhoopDays).union(appleHealthDays)
        for source in Repository.wearableImportSources {
            let rows = ((try? await store.dailyMetrics(deviceId: source, from: oldestDay, to: newestDay)) ?? [])
                .sorted { $0.day < $1.day }
            guard !rows.isEmpty else { continue }
            let byDay = Dictionary(rows.map { ($0.day, $0) }, uniquingKeysWith: { a, _ in a })
            for w in Self.watchRecoveries(appleRows: rows, strapRecoveryDays: importScoredDays) {
                guard let recovery = w.recovery, let row = byDay[w.day] else { continue }
                let scored = row.with(recovery: recovery, skinTempDevC: row.skinTempDevC,
                                      skinTempC: row.skinTempC)
                dailies.append(scored)
                importScoredDays.insert(w.day)
                resolvedScoreOwnerByDay[w.day] = source
                if let rest = AnalyticsEngine.Rest.composite(daily: scored) {
                    restPoints.append(MetricPoint(day: w.day, key: "sleep_performance", value: rest))
                }
                out.append(Computed(day: w.day, recovery: recovery, strain: scored.strain,
                                    sleepMin: scored.totalSleepMin, hrv: scored.avgHrv, rhr: scored.restingHr,
                                    source: .computed, confidence: w.confidence))
            }
        }

        // Persist the computed scores under a dedicated "-noop" source so the WHOLE dashboard
        // (Today / Recovery / Strain / Sleep / Trends), not just this screen, reads them. The
        // Repository merges these UNDER any imported "my-whoop" rows, so a real WHOOP import
        // always wins; this only fills the days the strap collected but no import covered.
        // Snapshot the persisted/merged daily history BEFORE the upsert + stale-evict below , the
        // accumulated view the readiness card + dashboard read (incl. IMPORTED Apple Health / Health Connect
        // resting HR, which the engine's computed-only `dailies` never carries). Captured here so the
        // Fitness Age gate can't be undercut by this pass's own scoring/eviction. Windowed to the range.
        let faPriorDaily = await repo.dailyMetrics(fromDay: oldestDay, toDay: newestDay)

        // Score provenance is metric-specific and lives outside dayOwnership (which remains solely a
        // resolver override). Persist scores + provenance atomically so a failed write can never label an
        // older score with a newer provider. The last row for a duplicate day wins, matching the upsert.
        var provenanceByCell: [String: ScoreInputProvenanceRow] = [:]
        for daily in dailies {
            guard let source = resolvedScoreOwnerByDay[daily.day] else { continue }
            if daily.recovery != nil {
                provenanceByCell["\(daily.day)\u{1F}recovery"] =
                    ScoreInputProvenanceRow(day: daily.day, key: "recovery", sourceId: source)
            }
            if daily.strain != nil {
                provenanceByCell["\(daily.day)\u{1F}strain"] =
                    ScoreInputProvenanceRow(day: daily.day, key: "strain", sourceId: source)
            }
        }
        for point in restPoints {
            guard let source = resolvedScoreOwnerByDay[point.day] else { continue }
            provenanceByCell["\(point.day)\u{1F}\(point.key)"] =
                ScoreInputProvenanceRow(day: point.day, key: point.key, sourceId: source)
        }
        diagMark("score2")
        try? await store.persistComputedScores(
            dailyMetrics: dailies,
            metricPoints: restPoints,
            provenance: Array(provenanceByCell.values),
            deviceId: computedId,
            from: oldestDay,
            to: newestDay
        )

        // Now evict only the STALE computed rows in the window , those a prior (e.g. UTC-keyed) run left
        // behind that the current local-keyed run no longer produces. Read the window, diff against the
        // keys we just upserted, and delete each leftover day individually (from == to == key). This
        // removes #277's UTC/local duplicates WITHOUT the wide delete-then-reinsert dip. No-op in steady
        // state (the new keys cover the window), so it adds nothing once the migration has settled.
        // #1196: skip stale-eviction on an EMPTY pass so a transient/degenerate empty `dailies` (a read
        // over a still-incomplete raw store during a reconnect/offload storm, or the active strap
        // momentarily resolving to an empty id) never evicts the whole window. In steady state `dailies`
        // covers the window, so eviction runs exactly as before; `persistComputedScores` is guarded the
        // same way, so an empty pass leaves the persisted window untouched. Twin of the Android
        // WhoopDao.replaceComputedScoreWindow empty guard.
        if !dailies.isEmpty {
            let freshKeys = Set(dailies.map { $0.day })
            let existingWindow = (try? await store.dailyMetrics(deviceId: computedId, from: oldestDay, to: newestDay)) ?? []
            for stale in existingWindow where !freshKeys.contains(stale.day) {
                _ = try? await store.deleteDailyMetrics(deviceId: computedId, from: stale.day, to: stale.day)
            }
        }
        diagMark("p.scores")
        // ── Fitness Age (Phase 2) , weekly, keyed to the week's Saturday ────────────────────────────
        // Roll the last 7 computed days into the Nes/HUNT inputs and upsert a weekly Fitness Age (+ an
        // optional VO₂max when a waist is set) under the same "-noop" source. Idempotent on the Saturday
        // key, so the number refines through the week and finalises on Saturday. Engine = FitnessAgeEngine
        // (StrandAnalytics), fully unit-tested; the body term cancels so the headline needs no body metric.
        let fa7 = dailies.sorted { $0.day < $1.day }.suffix(7)
        let faRHRs = fa7.compactMap { $0.restingHr }.map(Double.init)
        // The Fitness Age gate + compute read the PERSISTED/MERGED last-7 days , the SAME history the
        // readiness card + dashboard show , NOT this pass's freshly scored `dailies`. A recompute only
        // re-scores nights whose raw HR still lives in the store, so a nightly wearer whose card reads
        // "7 of 7 nights" could still leave the engine seeing <4 RHR nights on `dailies`, and Fitness Age
        // never computed (Vitality did , it needs only 3 of ANY input, which is why Body Age showed but
        // Fitness Age did not). Kept SEPARATE from `fa7` so Vitality (below), which already computes, is
        // untouched. Gate on the UNION of the pre-rewrite persisted history and THIS pass's fresh scores
        // (by day, fresh wins), so an RHR night counts whether it survives in the store, was just scored,
        // or came from an import. The gate + compute live in `fitnessAgeRows`, shared with the manual
        // "refresh Fitness Age" button so the two can never drift.
        var faGateByDay: [String: DailyMetric] = [:]
        for d in faPriorDaily { faGateByDay[d.day] = d }
        for d in dailies { faGateByDay[d.day] = d }
        let faGate7 = Array(faGateByDay.values.sorted { $0.day < $1.day }.suffix(7))
        let faPts = Self.fitnessAgeRows(
            gateDays: faGate7, age: profile.age, sex: profile.sex, waistCm: profile.waistCm,
            heightCm: profile.heightCm, weightKg: profile.weightKg, computedId: computedId,
            satKey: IntelligenceEngine.saturdayKey(onOrBefore: newestDay))
        if !faPts.isEmpty {
            try? await store.persistMetricSeriesWithProvenance(
                points: faPts,
                provenance: Self.vo2MaxProvenance(points: faPts, waistCm: profile.waistCm),
                deviceId: computedId
            )
        }

        // ── Vitality / Body Age (Phase 7) , weekly, keyed to the week's Saturday ────────────────────
        // Roll the last 7 days' wearable signals into the mortality-hazard model and upsert a weekly
        // Vitality (0–100) + Body Age. VitalityEngine gates on ≥3 inputs, so a sparse week writes nothing.
        // (VO₂max is omitted here , fitness is already its own Fitness Age headline; Vitality leans on
        // resting HR, sleep duration + regularity, HRV-vs-age-norm, and steps.)
        let vNights = fa7.compactMap { $0.totalSleepMin }.map { Double($0) / 60.0 }.filter { $0 > 0 }
        let vHRVs = fa7.compactMap { $0.avgHrv }
        let vSteps = fa7.compactMap { $0.steps }.map(Double.init)
        let vInputs = VitalityEngine.Inputs(
            chronoAge: Double(profile.age),
            restingHR: faRHRs.isEmpty ? nil : IntelligenceEngine.medianOf(faRHRs),
            sleepHours: vNights.isEmpty ? nil : vNights.reduce(0, +) / Double(vNights.count),
            sleepConsistency: VitalityEngine.sleepConsistency(nightlyHours: vNights),
            rmssd: vHRVs.isEmpty ? nil : IntelligenceEngine.medianOf(vHRVs),
            rmssdNorm: VitalityEngine.rmssdNorm(forAge: Double(profile.age)),
            steps: vSteps.isEmpty ? nil : vSteps.reduce(0, +) / Double(vSteps.count))
        if let vRes = VitalityEngine.compute(vInputs) {
            let satKey = IntelligenceEngine.saturdayKey(onOrBefore: newestDay)
            _ = try? await store.upsertMetricSeries([
                MetricPoint(day: satKey, key: "vitality", value: vRes.vitality),
                MetricPoint(day: satKey, key: "body_age", value: vRes.bodyAge),
            ], deviceId: computedId)
        }

        // ── Stress proxy (#R-stress-chart), DAILY, gap-filled under the canonical "my-whoop" source ─────
        // Written under `Repository.whoopSource` (NOT the "-noop" computed sibling every other block here
        // uses) because that's the id BOTH readers actually check: `StressView` reads
        // `repo.series(key: "stress", source: "my-whoop")`, and `plot_metric`'s generic fallback reads the
        // same source — neither ever looks at a "-noop" id for this key. Gap-filled, never overwritten: a
        // day that already has a stress value (an import, or a previous pass) keeps it, so a live day's
        // number is stable across passes and an imported day is never silently replaced by a differently-
        // windowed recomputation.
        let daysForStress = Array((faGateByDay.values.sorted { $0.day < $1.day }))
        if !daysForStress.isEmpty {
            let existingStressDays = Set(
                ((try? await store.metricSeries(deviceId: Repository.whoopSource, key: "stress",
                                                 from: oldestDay, to: newestDay)) ?? [])
                    .map(\.day))
            let stressRows = Self.stressProxyRows(days: daysForStress)
                .filter { !existingStressDays.contains($0.day) }
            if !stressRows.isEmpty {
                _ = try? await store.upsertMetricSeries(stressRows, deviceId: Repository.whoopSource)
            }
        }
        diagMark("p.derived")

        // ── Steps ESTIMATE (WHOOP 4.0) , DAILY, keyed to each strap-only day ────────────────────────
        // A WHOOP 4.0 sends no step count over BLE, so for days the phone DIDN'T also count steps we
        // estimate them: calibrate the strap's daily MOTION VOLUME against the phone's real step count
        // on the days both exist, then apply that personal coefficient to the strap-only days. Engine =
        // StepsEstimateEngine (StrandAnalytics), fully unit-tested; this block is pure orchestration ,
        // gather points, fit, store under the same "-noop" source, mirror to ProfileStore for the UI.
        //
        // Idempotent: re-upserts the same (computedId, day, "steps_est") rows. Inert until there's a
        // calibration , a single-source / no-phone user sees no estimate until they set a manual `k`.
        //
        // Calibration window: a generous 60 days (not just the 7 the weekly engines use) so enough
        // both-have days accumulate to fit. Reference steps = the apple-health daily `steps` value
        // (the same source the dashboard's `steps` metric reads, Repository.swift). Motion = the
        // [localMidnight, +24h) gravity volume, the same calendar-day window the daily totals use.
        let stepsCalDays = 60
        let calOldest = AnalyticsEngine.dayString(
            nowLocalMidnight - (stepsCalDays - 1) * 86_400, offsetSec: tzOffset)
        // ── FIX 2 (main-actor jank): hoist the 60-day steps-calibration STORE READS off the main actor ──
        // Same residual stall FIX 1 fixed, smaller scale: this class is `@MainActor`, so each `await store.…`
        // below resumes its continuation ON the main actor , the apple-health read + 60 per-day
        // owner-resolve/gravity reads add 60+ read-resumes of main-actor contention every analyzeRecent.
        // The reads touch NO `@Published`/`profile`/`registry`-isolated state , only the captured immutable
        // inputs (calOldest/newestDay/nowLocalMidnight/tzOffset/regDevices/regActiveId), the `WhoopStore`
        // actor, the nonisolated `registry`, the nonisolated-static `resolveDayOwner`, and the pure static
        // `StepsEstimateEngine.dayMotionIntensity`. So we hoist the whole gather into ONE
        // `Task.detached(priority:.utility)` whose continuations resume OFF the main actor, returning two
        // plain `[String: Double]` value types (fully Sendable , even cleaner than FIX 1's [DayScan]). The
        // pure `StepsEstimateEngine.calibrate/estimate/status` fit + the `profile.*` assignments stay on the
        // main actor below, consuming those dictionaries. Same per-day inputs (same window, same owner
        // resolution, same `m > 0` / `steps > 0` filters), same outputs , only the executor the reads resume
        // on changes. Bind `deviceId` (a MainActor instance `let`) to a local Sendable `String` so the
        // @Sendable detached closure captures the VALUE, never `self`, exactly as FIX 1's `ownerFallbackId`.
        let stepsFallbackId = deviceId
        // The 60 gravity reads below were the single most expensive thing in the whole post-loop phase:
        // 28.93 s of a 31.83 s measured total, every pass, while the ten other phases together cost 2.90 s.
        // On a worn library that is ~9 million rows re-read to re-derive a number that cannot have moved —
        // and it is why the phase did NOT scale with days re-derived: it always reads the same 60 days.
        //
        // `dayMotionIntensity` is a pure fold over ONE day's gravity stream, so its result changes exactly
        // when that day's raw changes — which the database already records, in the same
        // `analysisInputRevision` the per-day scan reuse is built on. So the volume is cached beside the
        // `steps_est` it feeds, under the same computed id and the same MetricPoint mechanism, and a day is
        // re-folded only when its revision moved. Three small indexed reads replace one unbounded one.
        //
        // Both revisions are kept, not just the input one: `deviceRevision` is what a wipe or a re-point
        // moves, and a cache that ignored it would serve a volume folded from a stream that has since been
        // re-homed. A missing or mismatched entry falls through to the full fold, so the slow path stays the
        // fallback rather than the norm.
        let cachedMotion = Dictionary(
            (((try? await store.metricSeries(deviceId: computedId, key: Self.stepsMotionKey,
                                             from: calOldest, to: newestDay)) ?? [])
                .map { ($0.day, $0.value) }), uniquingKeysWith: { _, last in last })
        let cachedMotionInputRev = Dictionary(
            (((try? await store.metricSeries(deviceId: computedId, key: Self.stepsMotionInputRevKey,
                                             from: calOldest, to: newestDay)) ?? [])
                .map { ($0.day, $0.value) }), uniquingKeysWith: { _, last in last })
        let cachedMotionDeviceRev = Dictionary(
            (((try? await store.metricSeries(deviceId: computedId, key: Self.stepsMotionDeviceRevKey,
                                             from: calOldest, to: newestDay)) ?? [])
                .map { ($0.day, $0.value) }), uniquingKeysWith: { _, last in last })
        let (refStepsByDay, motionByDay, freshMotion, motionReused):
            ([String: Double], [String: Double], [(day: String, motion: Double, input: Int, device: Int)], Int) =
            await Task.detached(priority: .utility) {
            // Phone reference steps per day, from the apple-health daily rows (steps > 0 only).
            // #693: read `appleDaily`, NOT `dailyMetrics`. Apple-Health import writes the phone step count into
            // `appleDaily.steps` (Int?), never into a dailyMetric `steps` row , so the old `dailyMetrics` read
            // was always empty and the calibration never advanced past "Need 3 more days" (Android already reads
            // appleDaily here, IntelligenceEngine.kt:676). `store.appleDaily(deviceId:from:to:)` already exists.
            let appleRows = (try? await store.appleDaily(deviceId: Repository.appleHealthSource,
                                                         from: calOldest, to: newestDay)) ?? []
            var refSteps: [String: Double] = [:]
            for r in appleRows { if let s = r.steps, s > 0 { refSteps[r.day] = Double(s) } }
            // Per-day motion volume over the calibration window, read from the owner-resolved strap streams.
            // (Owner resolution mirrors the scoring loop; one device installs resolve to `deviceId`.)
            var motion: [String: Double] = [:]
            var fresh: [(day: String, motion: Double, input: Int, device: Int)] = []
            var reused = 0
            for off in 0..<stepsCalDays {
                let dayMid = Self.midnightLocal(nowLocalMidnight - off * 86_400, offsetSec: tzOffset)
                let dayEnd = dayMid + 86_400 - 1
                let dayKey = AnalyticsEngine.dayString(dayMid, offsetSec: tzOffset)
                let owner = await Self.resolveDayOwner(day: dayKey, from: dayMid, to: dayEnd, store: store,
                                                       devices: regDevices, activeId: regActiveId,
                                                       registry: registry, fallbackDeviceId: stepsFallbackId)
                // One indexed MAX over a handful of revision rows, the same probe the day scan uses. It
                // decides whether the unbounded gravity read below can be skipped.
                let probe = try? await store.analysisInputRevision(deviceId: owner, from: dayMid, to: dayEnd)
                if let probe,
                   let cached = cachedMotion[dayKey],
                   let cachedInput = cachedMotionInputRev[dayKey],
                   let cachedDevice = cachedMotionDeviceRev[dayKey],
                   Int(cachedInput) == probe.inputRevision,
                   Int(cachedDevice) == probe.deviceRevision {
                    if cached > 0 { motion[dayKey] = cached }
                    reused += 1
                    continue
                }
                let grav = (try? await store.gravitySamples(deviceId: owner, from: dayMid, to: dayEnd,
                                                            limit: Int.max)) ?? []
                let m = StepsEstimateEngine.dayMotionIntensity(grav)
                if m > 0 { motion[dayKey] = m }
                // Cached even when the fold produced 0 (an unworn day). Storing only the positive ones
                // would leave every gap re-reading its whole stream forever to rediscover that it is empty.
                if let probe {
                    fresh.append((day: dayKey, motion: m,
                                  input: probe.inputRevision, device: probe.deviceRevision))
                }
            }
            return (refSteps, motion, fresh, reused)
        }.value
        if !freshMotion.isEmpty {
            var points: [MetricPoint] = []
            points.reserveCapacity(freshMotion.count * 3)
            for row in freshMotion {
                points.append(MetricPoint(day: row.day, key: Self.stepsMotionKey, value: row.motion))
                points.append(MetricPoint(day: row.day, key: Self.stepsMotionInputRevKey,
                                          value: Double(row.input)))
                points.append(MetricPoint(day: row.day, key: Self.stepsMotionDeviceRevKey,
                                          value: Double(row.device)))
            }
            _ = try? await store.upsertMetricSeries(points, deviceId: computedId)
        }
        NSLog("[FREEZE-DIAG] steps motion cache: reused=\(motionReused) refolded=\(freshMotion.count) "
            + "of \(stepsCalDays)")
        // Build calibration points only for days with BOTH a motion volume and a real phone step count.
        let calPoints = motionByDay.compactMap { (day, motion) -> StepsEstimateEngine.CalibrationPoint? in
            guard let s = refStepsByDay[day] else { return nil }
            return StepsEstimateEngine.CalibrationPoint(motion: motion, steps: s)
        }
        if let cal = StepsEstimateEngine.calibrate(calPoints, manualOverride: profile.stepsManualOverride) {
            // Estimate + upsert for each recent scored day that has motion but NO real phone step count.
            // (Days the phone DID count keep their real value , surfaced directly by the Today tile, not
            // overwritten by an estimate.) This runs AFTER any timestamp-heal upstream, so the motion it
            // reads is the healed-day motion, never pre-heal.
            var estPts: [MetricPoint] = []
            for dm in dailies where refStepsByDay[dm.day] == nil {
                guard let motion = motionByDay[dm.day],
                      let est = StepsEstimateEngine.estimate(motion: motion, calibration: cal) else { continue }
                estPts.append(MetricPoint(day: dm.day, key: "steps_est", value: Double(est)))
            }
            if !estPts.isEmpty { _ = try? await store.upsertMetricSeries(estPts, deviceId: computedId) }
            // Mirror the fit into ProfileStore so the Settings/Steps screen can show + adjust it.
            profile.stepsCalibrationCoefficient = cal.coefficient
            profile.stepsCalibrationSampleDays = cal.sampleDays
            profile.stepsCalibrationConfidence = cal.confidence
            profile.stepsCalibrationManual = cal.manual
        } else {
            // Not yet calibrated (too few overlapping phone-counted days, no manual override). Classify the
            // STATE (#589) and persist the PROGRESS so the Today tile/Settings can say how many more days are
            // needed rather than going silently blank. `status` uses the SAME usable-day filter the fit does.
            // Coefficient stays 0 (the "not calibrated" gate the UI already keys off); sampleDays carries the
            // usable-day count so the message can compute "need N more".
            let stepsStatus = StepsEstimateEngine.status(calPoints, manualOverride: profile.stepsManualOverride)
            if case let .needsMoreDays(have, _) = stepsStatus {
                profile.stepsCalibrationCoefficient = 0
                profile.stepsCalibrationSampleDays = have
                profile.stepsCalibrationConfidence = 0
                profile.stepsCalibrationManual = false
            }
        }

        // Steps test mode: emit the WHOOP-4 motion-volume calibration trace (per-day points + the fitted /
        // manual / withheld calibration state) and a per-day estimate line, tagged `.steps`. Only when the
        // mode is on (the gate was read once before the scan loop), so the default path emits zero `.steps`
        // lines here. The trace reuses StepsEstimateEngine.calibrate/estimate VERBATIM, so it cannot diverge
        // from the coefficient + steps_est just written above.
        if stepsTraceActive {
            for line in StepsEstimateEngine.calibrationTrace(points: calPoints,
                                                             manualOverride: profile.stepsManualOverride) {
                diagnosticSink?(line, .steps)
            }
            if let cal = StepsEstimateEngine.calibrate(calPoints, manualOverride: profile.stepsManualOverride) {
                for dm in dailies where refStepsByDay[dm.day] == nil {
                    guard let motion = motionByDay[dm.day],
                          let est = StepsEstimateEngine.estimate(motion: motion, calibration: cal) else { continue }
                    diagnosticSink?("stepsEst day=\(dm.day) steps=\(est) "
                        + "motion=\((motion * 100).rounded() / 100) (motion-volume estimate)", .steps)
                }
            }
        }
        diagMark("p.steps")

        // Drop any freshly-detected session that overlaps a night the user has already hand-corrected.
        // A detected onset can drift second-to-second as more raw data arrives, so without this the
        // re-detected night would upsert as a SECOND row beside the edited one (different startTs ⇒ no
        // ON CONFLICT match), and mergeDay would DOUBLE-COUNT both into an inflated time-in-bed. The
        // edited row is already stored (preserved by the upsert guard), so we simply don't re-insert its
        // detected twin. Sleep has no delete-reinsert pass (unlike dailyMetric/workout), so this is the
        // idempotency guard for the edited case. (#318)
        let editedWindows = editedRows.map { (start: $0.effectiveStartTs, end: $0.endTs) }
        // #68: also drop any re-detected night the user has DELETED , a dismissedSleep tombstone keeps it
        // from regenerating, mirroring the dismissed-WORKOUT guard above. Overlap (not exact startTs)
        // because a re-detected onset drifts as more raw data arrives. (Android twin: dismissedWindows.)
        let dismissedWindows = repo.dismissedSleepWindows()
        let skipWindows = editedWindows + dismissedWindows
        let cachedSleepKept = cachedSleep.filter { s in
            !skipWindows.contains { s.startTs < $0.end && $0.start < s.endTs }   // time-overlap test
        }
        if !cachedSleepKept.isEmpty { _ = try? await store.upsertSleepSessions(cachedSleepKept, deviceId: computedId) }
        // ── Persist per-epoch motion (H8) beside each kept session's stagesJSON ──────────────────────────
        // The sleepSession rows exist now (just upserted), so the targeted motion UPDATE lands. Persist ONLY
        // for the sessions actually kept (not edited/dismissed), keyed by the detected start `analyzeDay`
        // returned. A session whose gravity wouldn't grid was omitted from the map and is left as NULL , an
        // absent motion series stays absent, never a fabricated zero array.
        let keptStarts = Set(cachedSleepKept.map { $0.startTs })
        var motionByStart: [Int: [Double]] = [:]
        for night in scoredNights {
            for (start, motion) in night.sessionMotion where keptStarts.contains(start) {
                motionByStart[start] = motion
            }
        }
        for (start, motion) in motionByStart {
            _ = try? await store.persistSessionMotion(deviceId: computedId, sessionStart: start, motionEpochs: motion)
        }
        // ── Persist per-epoch BAND sleep_state (#175) beside each kept session's stagesJSON ──────────────
        // This is the source `sessionSleepStateJSON` lacked (v7.7.0 finding: the write path had no producer
        // because the raw stream was dropped at extraction). Now analyzeDay grids the RAW `sleepStateSample`
        // stream per session; persist it here so the NEXT pass's `bandSleepStateSamples` read (the H7 confirm)
        // and the display can see the strap's OWN scored band. ONLY for kept (not edited/dismissed) sessions;
        // a session with no band samples was omitted (no key) and stays NULL — an absent signal stays absent.
        var sleepStateByStart: [Int: [Int]] = [:]
        for night in scoredNights {
            for (start, states) in night.sessionSleepState where keptStarts.contains(start) {
                sleepStateByStart[start] = states
            }
        }
        for (start, states) in sleepStateByStart {
            _ = try? await store.persistSessionSleepState(deviceId: computedId, sessionStart: start, states: states)
        }
        diagMark("p.sleepWrite")
        // ── Overlap-aware banked-sleep heal (#899) ────────────────────────────────────────────────────
        // An unstable strap clock re-banks the SAME night under a shifted timebase, so successive passes
        // detect it at shifted bounds and the upsert above lands a SECOND row beside the stale one (the
        // (deviceId, startTs) key differs, and sleep has no delete-reinsert reconcile like dailyMetric /
        // workout). Collapse the window's stored sessions with the overlap rule, treating the rows THIS
        // pass just banked as the bank-recency witness (the strap's current timebase), and delete the
        // stale copies. Scoped to sessions whose wake day lies inside the [oldestDay, newestDay] daily
        // reconcile window: exactly the days this pass re-scored/evicted, so a session row is never
        // deleted out from under a daily row the pass did not refresh. Edited rows are never dropped.
        // #1248: heal EVERY device that banks sleep in this window, not just `computedId`. A live source
        // (an Oura ring) banks its OWN hypnogram under its device id; a night re-banked there accumulates
        // overlapping copies the computedId-only heal never saw — and, worse, those un-healed ring rows are
        // re-read as `providedSleep` and re-detected every pass, so one night ballooned to 14 rows / 9
        // "naps". Dedup each device's rows AMONG THEMSELVES and delete stale copies under that SAME id
        // (never across ids, so a survivor is never orphaned under an id the day-owner read skips).
        // `freshStarts` (this pass's computed bank witness) only matches the computedId rows; the others
        // fall back to longest-wins, the read-side dedup's own default. Sorted for a deterministic order.
        let healDeviceIds = Self.healDeviceIds(computedId: computedId, registeredIds: regDevices.map { $0.id })
        // Compact shape of a row for the #1284 heal log — the two measures that adjudicate WHICH copy is
        // fuller (stage-segment count + decoded JSON length), in the SAME format as the dup-gen diagnostic
        // (`dupGenShape`) so the two lines parse identically. Window + shape counts only, never stage content
        // or vitals; the strap log stays local and is shared only when the user exports it (as dup-gen does).
        func sleepShape(_ s: CachedSleepSession) -> String {
            let json = s.stagesJSON ?? ""
            let segs = json.components(separatedBy: "\"stage\"").count - 1
            return "[\(s.startTs) -> \(s.endTs)] min=\((s.endTs - s.effectiveStartTs) / 60) segs=\(segs) json=\(json.utf8.count)"
        }
        var healDropped: [CachedSleepSession] = []
        for healId in healDeviceIds {
            let storedSessions = (try? await store.sleepSessions(deviceId: healId, from: windowStart,
                                                                 to: now, limit: 4000)) ?? []
            // SCOPED TO THE DAYS THIS PASS SCANNED (#launch-rescore), for the same reason as the
            // detected-workout delete below. `freshStarts: keptStarts` is the bank-recency witness, and it
            // only ever contains sessions from days this pass re-derived. A reused day would enter the
            // dedupe WITHOUT a witness, so on a day carrying two legitimate sessions (a nap and the night)
            // the fallback rule could drop the one the witness would have kept. Its rows were healed by the
            // pass that scored them and nothing has touched them since — leaving them alone is correct.
            let healable = storedSessions.filter {
                scannedDays.contains(AnalyticsEngine.dayString($0.endTs, offsetSec: tzOffset))
            }
            let sweep = SleepSessionDedup.dedupe(healable, freshStarts: keptStarts)
            for stale in sweep.dropped {
                _ = try? await store.deleteSleepSession(deviceId: healId, startTs: stale.startTs)
                // #1284: log which copy was dropped and which survived, so the corpus can confirm the heal
                // keeps the fuller / end-correct row (the survivor the collapse resolved this stale into).
                if let survivor = sweep.kept.first(where: { SleepSessionDedup.isDuplicate($0, stale) }) {
                    diagnosticSink?("Dedup(#1284): dropped \(sleepShape(stale)) kept \(sleepShape(survivor)) - heal", nil)
                }
            }
            healDropped.append(contentsOf: sweep.dropped)
        }
        // #1284: log the sweep ALWAYS, even at zero removals — a heal that collapsed rows was previously
        // silent (the line below only fired on a non-empty drop), so from the strap log alone it was
        // indistinguishable from never having run. Counts only, no PII.
        diagnosticSink?("Dedup(#899): swept \(healDeviceIds.count) device id(s), removed "
            + "\(healDropped.count) overlapping duplicate session(s).", nil)
        if !healDropped.isEmpty {
            diagnosticSink?("Dedup(#899): removed \(healDropped.count) overlapping duplicate sleep "
                + "session(s) re-banked under a shifted strap timebase; re-scoring the affected days.", nil)
            // Re-score against the cleaned store via the existing #899-A re-arm: the days scored THIS
            // pass consumed the read-side deduped view, but that view had no bank-recency witness (the
            // fresh detections weren't banked yet), so its survivor can differ from the heal's. One
            // forced re-pass reconciles them. HARD-BOUNDED: if the re-pass's own heal drops rows
            // again (detection oscillating under its own feedback), it does NOT re-arm a second time,
            // matching the Android one-re-pass bound; the budget restores once a pass heals nothing.
            if !healRearmedThisCycle {
                healRearmedThisCycle = true
                enqueueFollowup(maxDays: maxDays, reason: .semanticChange)
            }
        } else {
            healRearmedThisCycle = false
        }
        // Make re-detection idempotent across runs: clear the prior computed detected workouts in the
        // scored window (a bout's startTs can drift as more HR arrives, which would otherwise orphan
        // stale rows under the (deviceId,startTs,sport) key), then re-insert.
        //
        // SCOPED TO THE DAYS THIS PASS SCANNED (#launch-rescore). This delete used to cover the whole
        // window on the assumption that every day in it had just been re-detected. With the per-day skip
        // that assumption is false: a reused day re-inserts nothing, so a window-wide delete would strip
        // its detected workouts PERMANENTLY. Deleting per scanned day is the same operation for a pass
        // that scanned everything (the union of the days IS the window) and a no-op for the days it
        // reused — which is exactly the intent the comment above always described.
        for dayKey in scannedDays.sorted() {
            guard let dayMid = Self.midnightForDayKey(dayKey, offsetSec: tzOffset) else { continue }
            _ = try? await store.deleteWorkouts(deviceId: computedId, sport: "detected",
                                                from: dayMid, to: min(dayMid + 86_400 - 1, now))
        }
        if !workoutRows.isEmpty { _ = try? await store.upsertWorkouts(workoutRows, deviceId: computedId) }
        // #510: write back any real (manual/imported) rows a dropped detected bout backfilled, one
        // upsert per owning deviceId (see the collision branch above for why these can't share the
        // `computedId` batch above).
        for (devId, rows) in backfilledByDevice {
            _ = try? await store.upsertWorkouts(rows, deviceId: devId)
        }

        // #137: a manually-started workout is scored from sparse live HR at save time , near-zero
        // calories/strain on a 5/MG. Now that offloaded HR may cover the window, re-score the
        // under-sampled ones from that denser data.
        // #950: score the workout against the wearer's MEASURED resting HR, not the hardcoded 60 —
        // the day total above already uses the measured value, and the mismatch is what made a workout's
        // Effort incomparable to its own day's. The most recent scored day that has one is the best
        // available estimate; nil (cold start) keeps the old default. Twin of the Kotlin derivation.
        // FIRST, not last: `out` is NEWEST-FIRST, because the scoring loop counts backwards from today
        // (`for offset in 0..<maxDays` with `dayStart = nowLocalMidnight - offset * 86_400`), so out[0] is
        // today and the tail is the oldest day in the window. Taking the last match would have scored
        // today's workout against a resting HR up to `maxDays` old.
        let measuredResting = out.first(where: { $0.rhr != nil })?.rhr.map(Double.init)
        await rescoreManualWorkouts(store: store, profile: up, restingHR: measuredResting,
                                    effortMethod: effortMethodGlobal)

        results = out
        note = out.isEmpty
            ? "No scored nights yet. Wear the strap with NOOP connected overnight and the engine will score your charge, effort and rest itself, no WHOOP cloud required."
            : nil

        diagMark("p.sleepHeal+workouts")
        // Reload the dashboard caches so the freshly computed scores show up immediately. A heal-only
        // pass (#899 dedup deleted stale session rows but no daily changed) must refresh too, so the
        // Sleep tab stops showing the removed duplicates right away.
        if !dailies.isEmpty || !healDropped.isEmpty { await repo.refresh() }

        // Record what each day this pass SCANNED was computed from, so the next pass can skip it
        // (#launch-rescore). Written here, after `persistComputedScores` above has stored the scores these
        // fingerprints describe — a fingerprint written for a day whose result did not land would make the
        // next run skip a day that has no scores, the one direction this table must never fail in.
        //
        // Only scanned days: a reused day's fingerprint is already correct (it is what made it reusable),
        // and rewriting it would be a no-op. The nightly skin MEAN is carried alongside because the stored
        // `dailyMetric` row keeps only the deviation — see `DayScanFingerprint.nightlySkinC`.
        let persistedDays = Set(dailies.map { $0.day })
        let scanFingerprints: [DayScanFingerprint] = scanned.compactMap { scan in
            let day = scan.result.daily.day
            guard persistedDays.contains(day), let probe = scan.inputProbe else { return nil }
            return DayScanFingerprint(day: day, ownerId: scan.readOwner,
                                      hrCount: 0, hrMaxTs: 0,
                                      nightlySkinC: scan.result.nightlySkinTempC,
                                      traits: traitSignature,
                                      inputRevision: probe.inputRevision,
                                      deviceRevision: probe.deviceRevision,
                                      scoringVersion: scoringVersion,
                                      semanticSignature: semanticSignature(day))
        }
        if !scanFingerprints.isEmpty {
            _ = try? await store.upsertDayScanFingerprints(scanFingerprints, deviceId: computedId)
        }

        // #836: record the raw-HR fingerprint this run scored against, so a later NON-forced tick can
        // short-circuit while it's unchanged. Written ONLY here at the end of a completed run (never on an
        // early guard-return), so an interrupted/failed run can't advance the watermark past unscored data.
        if !wmKey.isEmpty { UserDefaults.standard.set(wmKey, forKey: Self.analyzeWatermarkKey) }
        // #1538: clear the started-mark and bank how long a COMPLETED pass costs on this install. The
        // measurement is what lets `RescoreBackgroundPolicy` tell an install that finishes comfortably in a
        // background wake from one that never could, instead of guessing from a constant — the cost varies
        // by more than an order of magnitude with history size.
        let elapsed = Date().timeIntervalSince(reScoreStart)
        let settled = RescoreBackgroundScheduler.markRescoreCompleted(seconds: elapsed,
                                                                       owedToken: owedToken)
        if !settled {
            diagnosticSink?("re-score: completed, but a newer rescore request remains owed (#1681)", nil)
        }
        diagMark("refreshTail")
        if let before = diagFootprintBefore, let after = await store.databaseFootprintMB() {
            let f = { (v: Double) in String(format: "%.1f", v) }
            NSLog("[FREEZE-DIAG] store footprint: db=\(f(before.db))→\(f(after.db)) MB "
                + "wal=\(f(before.wal))→\(f(after.wal)) MB shm=\(f(before.shm))→\(f(after.shm)) MB")
        }
        diagnosticSink?("re-score: done — scored \(scoredNights.count) night(s) in \(Int(elapsed * 1000)) ms (#1005)", nil)
    }

    /// UserDefaults key for the #836 idle-tick gate: the `(count:maxTs)` HR fingerprint the last completed
    /// `analyzeRecent` scored against. A non-forced tick whose current fingerprint equals this skips the
    /// 21-day rescore; cleared implicitly by any HR insert/delete (the fingerprint moves), so it self-heals.
    private static let analyzeWatermarkKey = "noop.analyzeWatermark"

    /// CAPTURE-B (#814/#799): build the universal `dayOwner …` self-diagnostic line VERBATIM (the Test
    /// Centre export parser depends on this exact shape). `readId` is the owner this day was read+scored
    /// from; `writeActiveId` is the registry's active id the Collector writes raw under; a DIVERGENCE on a
    /// day with HR rows is the #814 read/write split. `provenance` is `imported:whoop` / `imported:apple`
    /// when an export covers the day, else `measured` when the owner returned HR rows, else `none`. Pure +
    /// nonisolated so it's unit-tested directly and so the format can never silently drift. No PII (the ids
    /// are local "my-whoop" / "whoop-…" / import tokens; LiveState.append also scrubs).
    nonisolated static func dayOwnerLine(day: String, readId: String, writeActiveId: String,
                                         hrRows: Int, importedWhoop: Bool, importedApple: Bool) -> String {
        let provenance: String
        if importedWhoop { provenance = "imported:whoop" }
        else if importedApple { provenance = "imported:apple" }
        else if hrRows > 0 { provenance = "measured" }
        else { provenance = "none" }
        return "dayOwner day=\(day) readId=\(readId) writeActiveId=\(writeActiveId) "
            + "hrRows=\(hrRows) provenance=\(provenance)"
    }

    /// Resolve the SINGLE device that owns `day` (invariant I2), so the day is scored from exactly one
    /// source , never a mix. Builds one `DayOwnerResolver.Candidate` per non-archived device with a
    /// priority (0 = the active strap, 1 = other live straps, 2 = imports; lower wins) and a CHEAP
    /// per-day presence flag (one `LIMIT 1` HR read per device), then applies any locked override from
    /// the dayOwnership table. Returns `deviceId` when the registry yields no owner (no candidate has
    /// data, or it's empty/unreadable) so the legacy single-source path is preserved.
    ///
    /// Single-device install: the only paired row is the seeded active 'my-whoop' (== `fallbackDeviceId`).
    /// Its candidate is priority 0 with `hasData == true` for any day the strap collected HR, so the
    /// resolver returns `fallbackDeviceId` and the caller's reads are byte-identical to the pre-I2 code.
    /// The presence check is the same `LIMIT 1` over the same window the caller already reads.
    ///
    /// `nonisolated static` (FIX 1): the body touches NO `@Published`/instance-isolated state , only the
    /// passed-in `store` actor, the nonisolated `registry` struct, the value params, and `fallbackDeviceId`
    /// (the former `self.deviceId`). Making it `nonisolated` lets the off-main scan loop call it WITHOUT
    /// hopping back to the main actor each iteration, which is the whole point of FIX 1. Logic identical.
    nonisolated static func resolveDayOwner(day: String, from: Int, to: Int, store: WhoopStore,
                                            devices: [PairedDevice], activeId: String,
                                            registry: DeviceRegistryStore,
                                            fallbackDeviceId: String) async -> String {
        // A locked override wins outright and skips the presence checks entirely.
        if let locked = (try? registry.dayOwner(day))?.deviceId {
            return locked
        }
        // No registry rows (shouldn't happen , v15 seeds one , but be safe): keep the legacy id.
        guard !devices.isEmpty else { return fallbackDeviceId }

        let liveDevices = devices.filter { $0.status != .archived }
        // #970: the default single-WHOOP install has exactly one live device that IS the fallback id, so
        // the owner is a foregone conclusion — the resolver returns that id whether or not it has data in
        // this window (active priority 0 -> its id; or no candidate has data -> nil -> fallbackDeviceId,
        // both == fallbackDeviceId here). Skip the per-day LIMIT-1 HR probe in that case (called once per
        // scanned day, so it saves ~maxDays tiny reads per analyzeRecent). Byte-identical to the loop. The
        // guard is deliberately `== fallbackDeviceId`: a lone IMPORT device whose id differs would NOT be
        // byte-identical (no-data -> fallback, not its own id), so it must still take the probe path.
        if liveDevices.count == 1, liveDevices[0].id == fallbackDeviceId {
            return fallbackDeviceId
        }

        var candidates: [DayOwnerResolver.Candidate] = []
        for d in liveDevices {
            let isImport = d.sourceKind == .cloudImport || d.sourceKind == .fileImport
            // #137: an activity-file ride ranks BELOW whole-day imports (priority 3 vs 2), so a full-day
            // WHOOP CSV/cloud import keeps ownership of a day it has HR for; the ride only wins a day that
            // nothing else covers (a strap-less day). Kotlin RegistryDayOwnerSource mirrors this ordering.
            let priority: Int
            if d.id == activeId { priority = 0 }
            else if d.sourceKind == .activityFile { priority = 3 }
            else if isImport { priority = 2 }
            else { priority = 1 }
            // Cheap presence check: a single HR row for this device in the night window is enough to
            // mark it a candidate. (LIMIT 1 , not the full pull the caller does once an owner is chosen.)
            let hasData = !((try? await store.hrSamples(deviceId: d.id, from: from, to: to, limit: 1)) ?? []).isEmpty
            candidates.append(DayOwnerResolver.Candidate(deviceId: d.id, priority: priority, hasData: hasData))
        }
        return DayOwnerResolver.resolve(day: day, lockedOwner: nil, candidates: candidates) ?? fallbackDeviceId
    }

    /// The strap family that wrote `owner`'s skin-temp rows (#938), so the nightly funnel converts the raw
    /// register on the right scale. The model-label → family mapping (and the `.whoop5` fallback for
    /// unknowns) lives in `DeviceFamily.forRegistryDevice` (#171, #1086).
    nonisolated static func skinTempFamily(forOwner owner: String, devices: [PairedDevice]) -> DeviceFamily {
        let d = devices.first(where: { $0.id == owner })
        // Non-WHOOP owner (nil) shares the non-4.0 temp scale, so coalesce to `.whoop5` — same conversion
        // as before; the brand-aware resolver just no longer mislabels the owner as a WHOOP (#1086).
        return DeviceFamily.forRegistryDevice(model: d?.model, brand: d?.brand) ?? .whoop5
    }

    /// #1467: the skin-temp "worn" gate's timestamp tolerance for `owner` — 0 (exact match) for a WHOOP
    /// strap, whose HR and skin-temp are one co-sampled 1 Hz stream, so this is byte-identical to before
    /// this change for every WHOOP night. An Oura ring streams the two on independent clocks (dense HR,
    /// ~1/min skin-temp), so an exact-second match only ever caught ~40-55% of real worn samples — every
    /// one of 7 straight real nights landed just under `minSkinTempSamples`, ground-truthed against the
    /// Oura app's own reported skin-temp trend (queue 11b, `worklog/BOARD.md`). Same registry lookup
    /// `skinTempFamily` uses; deliberately its own small helper rather than folding into `DeviceFamily`,
    /// which has no Oura case (#1086) and a tolerance-in-seconds isn't a temperature-scale concern.
    nonisolated static func skinTempWornToleranceSec(forOwner owner: String, devices: [PairedDevice]) -> Int {
        devices.first(where: { $0.id == owner })?.brand == "Oura"
            ? AnalyticsEngine.defaultOuraWornToleranceSec : 0
    }

    /// #137: re-score under-sampled manual workouts. A `manual` workout is scored from the live HR
    /// captured during the session; on a 5/MG that stream is sparse, so calories/strain land near zero.
    /// The strap banks its own HR and offloads it on sync , once that denser HR covers the workout's
    /// window, recompute from it. Conservative + idempotent: only `manual` rows that look under-scored
    /// (negligible calories), and only when the recompute is a genuine improvement , so a well-scored
    /// 4.0 workout is never touched and a still-sparse window is a no-op.
    private func rescoreManualWorkouts(store: WhoopStore, profile up: UserProfile,
                                       restingHR: Double? = nil,
                                       // #1545: the recipe THIS PASS scored its days with, threaded in
                                       // rather than re-read. Re-reading would let a toggle flipped
                                       // mid-pass score a manual workout by one recipe and the day it
                                       // sits in by the other — the exact day-vs-bout contradiction the
                                       // threading exists to prevent. Twin of the Kotlin parameter.
                                       effortMethod: StrainScorer.Method = .edwards) async {
        let now = Int(Date().timeIntervalSince1970)
        let since = now - 14 * 86_400
        guard let rows = try? await store.workouts(deviceId: deviceId, from: since, to: now, limit: 200)
        else { return }
        let hrMax = Double(profile.hrMax)
        var updated: [WorkoutRow] = []
        // A manual row is eligible when it looks under-scored (negligible kcal, #137) OR it's missing
        // strain (the merged-workout case, where kcal is the SUM of inputs so it never looks under-scored
        // yet Effort stays blank forever). `improves` then accepts a strain-only gain for the latter.
        for row in rows where row.source == "manual"
            && (ManualWorkoutRescore.looksUnderScored(currentKcal: row.energyKcal) || row.strain == nil) {
            guard let samples = try? await store.hrSamples(deviceId: deviceId, from: row.startTs,
                                                           to: row.endTs, limit: 20_000),
                  let s = ManualWorkoutRescore.scored(windowSamples: samples, profile: up, hrMax: hrMax,
                                                      restingHR: restingHR,
                                                      effortMethod: effortMethod),
                  ManualWorkoutRescore.improves(s, over: row.energyKcal, currentStrain: row.strain,
                                                allowStrainOnlyFill: true)
            else { continue }
            // Never lower a summed kcal: only take the recomputed kcal when it genuinely beats the stored
            // value; a strain-only fill (merged row) keeps the existing summed energyKcal.
            let kcalBeatsStored = (s.kcal ?? 0) > (row.energyKcal ?? 0) + ManualWorkoutRescore.improvementMarginKcal
            let energyKcal = kcalBeatsStored ? s.kcal : row.energyKcal
            updated.append(WorkoutRow(
                startTs: row.startTs, endTs: row.endTs, sport: row.sport, source: row.source,
                durationS: row.durationS, energyKcal: energyKcal, avgHr: s.avgHr, maxHr: s.maxHr,
                strain: s.strain, distanceM: row.distanceM, zonesJSON: row.zonesJSON, notes: row.notes,
                steps: row.steps))
        }
        if !updated.isEmpty { _ = try? await store.upsertWorkouts(updated, deviceId: deviceId) }
    }

    /// Re-score ONLY the recovery composite for a day against a (re-seeded) baseline. Every other field
    /// in `daily` is baseline-independent and already final from pass 1. Returns nil until the HRV
    /// baseline is usable (RecoveryScorer gates on `hrvBaseline.usable`, i.e. ≥ minNightsSeed valid
    /// nights) , so the honest null-until-4-nights cold-start is free. Mirrors AnalyticsEngine's own
    /// recovery call + Android IntelligenceEngine.recomputeRecovery. (#78)
    private func recomputeRecovery(_ daily: DailyMetric, _ baselines: AnalyticsEngine.ProfileBaselines) -> Double? {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else { return nil }
        // Charge enrichment: feed the Rest COMPOSITE (÷100) as the sleep-quality term instead of raw
        // efficiency, and fold in the night's skin-temp deviation. Both come from the persisted daily
        // fields (the raw streams are gone in pass 2). (Charge/Effort/Rest scoring redesign.)
        let restQuality = AnalyticsEngine.Rest.composite(daily: daily).map { $0 / 100.0 } ?? daily.efficiency
        return RecoveryScorer.recovery(hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
                                       hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
                                       respBaseline: baselines.resp, sleepPerf: restQuality,
                                       skinTempDev: daily.skinTempDevC)
    }

    /// The ordered "what shaped it" Charge driver list for one day (SHARED CONTRACT). Pure: it feeds the
    /// SAME inputs `recomputeRecovery` reads (the SAME `restQuality` derivation) into
    /// `RecoveryScorer.chargeDrivers`, whose per-term deltas come from `RecoveryScorer.recovery` verbatim, so
    /// the rows can never diverge from the Charge number written for the day. Empty when a hard input
    /// (HRV / RHR / HRV-baseline) is missing or the baseline isn't usable yet, mirroring `recomputeRecovery`'s
    /// own early-nil so a cold-start night shows the calibrating state rather than fabricated rows.
    private func recomputeChargeDrivers(_ daily: DailyMetric,
                                        _ baselines: AnalyticsEngine.ProfileBaselines) -> [ChargeDriver] {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else {
            return []
        }
        let restQuality = AnalyticsEngine.Rest.composite(daily: daily).map { $0 / 100.0 } ?? daily.efficiency
        return RecoveryScorer.chargeDrivers(hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
                                            hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
                                            respBaseline: baselines.resp, sleepPerf: restQuality,
                                            skinTempDev: daily.skinTempDevC)
    }

    /// The Charge term-breakdown trace lines for one day (Recovery test mode, Group G). Pure: it feeds the
    /// SAME inputs `recomputeRecovery` does (the SAME `restQuality` derivation) into RecoveryScorer's
    /// side-effect-free `recoveryTrace`, whose returned score IS `RecoveryScorer.recovery` verbatim, so the
    /// trace can never diverge from the Charge number written for the day. Empty when a hard input
    /// (HRV / RHR / HRV-baseline) is missing, mirroring `recomputeRecovery`'s own early-nil. Only CALLED
    /// when `TestCentre.active(.recovery)` is true, so it costs nothing when the mode is off.
    private func recoveryTraceLines(_ daily: DailyMetric, _ baselines: AnalyticsEngine.ProfileBaselines) -> [String] {
        guard let hrvVal = daily.avgHrv, let rhrVal = daily.restingHr, let hrvBase = baselines.hrv else {
            return ["charge day=\(daily.day) nilScore reason=missingInput "
                + "(hrv/rhr/hrvBaseline required)"]
        }
        let restQuality = AnalyticsEngine.Rest.composite(daily: daily).map { $0 / 100.0 } ?? daily.efficiency
        let (_, trace) = RecoveryScorer.recoveryTrace(
            hrv: hrvVal, rhr: Double(rhrVal), resp: daily.respRateBpm,
            hrvBaseline: hrvBase, rhrBaseline: baselines.restingHR,
            respBaseline: baselines.resp, sleepPerf: restQuality,
            skinTempDev: daily.skinTempDevC)
        // Prefix each line with the day key so a multi-night export stays parseable, matching the sleep
        // trace's per-day shape. Strip ONLY the leading "charge " token the trace builder writes (every
        // line starts with it), then re-emit as "charge day=<day> ...".
        return trace.map { line in
            let body = line.hasPrefix("charge ") ? String(line.dropFirst("charge ".count)) : line
            return "charge day=\(daily.day) " + body
        }
    }

    /// One day's watch-derived recovery output, keyed by day.
    struct WatchScoredDay: Equatable {
        let day: String
        let recovery: Double?
        let confidence: ScoreConfidence
    }

    /// Compute Apple-Watch recovery (Charge) for the apple-health days that lack a strap recovery.
    ///
    /// The Apple Watch gives DAILY aggregates (an SDNN HRV reading + a resting HR), not a WHOOP-density raw
    /// stream, so the normal `analyzeRecent` raw-HR path (`hr.count >= 200`) never scores these days and the
    /// import leaves `recovery: nil`. This fills that one gap: for each apple-health day it folds the TRAILING
    /// SDNN + RHR history (every earlier apple-health day's `avgHrv` / `restingHr`) into the cross-lane
    /// `WatchRecovery` engine, which mirrors our Charge recovery shape but reads Apple's daily values. It stays
    /// nil + `.calibrating` until there are enough usable nights of HRV baseline, so we never fabricate a number.
    ///
    /// `strapRecoveryDays` are the days a strap (WHOOP / computed) already scored a recovery , those are SKIPPED
    /// so the strap keeps winning (matching the source precedence; we never overwrite a strap recovery with a
    /// lower-density watch one). Pure (no store) so it's unit-tested directly and is the SAME logic
    /// `analyzeRecent` ships. `appleRows` must be chronological (oldest first).
    nonisolated static func watchRecoveries(appleRows: [DailyMetric],
                                strapRecoveryDays: Set<String> = []) -> [WatchScoredDay] {
        let rows = appleRows.sorted { $0.day < $1.day }
        var out: [WatchScoredDay] = []
        for (i, row) in rows.enumerated() where !strapRecoveryDays.contains(row.day) {
            // Trailing baseline history = every earlier apple-health day with a usable value. Today is the
            // current row; the baseline is built from the days BEFORE it so it can't see its own value.
            let prior = rows[..<i]
            let sdnnHistory = prior.compactMap { $0.avgHrv }
            let rhrHistory = prior.compactMap { $0.restingHr.map(Double.init) }
            let res = WatchRecovery.compute(todaySDNN: row.avgHrv,
                                            todayRHR: row.restingHr,
                                            sdnnHistory: sdnnHistory,
                                            rhrHistory: rhrHistory)
            out.append(WatchScoredDay(day: row.day, recovery: res.recovery, confidence: res.confidence))
        }
        return out
    }

    /// Override a day's detected sleep aggregates with the user's hand-corrected window when one of the
    /// night's blocks was edited. Substitutes each edited block (matched by its stable startTs) for its
    /// detected twin and recomputes totalSleep / efficiency / stage minutes from the reshaped stages, so
    /// the Rest composite and recovery score the corrected sleep , not the auto-detected window. No edit
    /// touching the night → the detected daily is returned unchanged. (#318)
    /// #299: the edited / hand-logged sleep rows that belong to `day` — the ones whose edits may be folded
    /// into THAT day's sleep total. An edit belongs to the day its night ENDS on (`dayString(endTs)`),
    /// matching AnalyticsEngine's end-day session bucket; `endTs` is stable under a bedtime edit (only the
    /// onset moves). Scoping this per day is the fix: the edit set was built window-wide and
    /// `sleepEditedDaily` folds any row that isn't a twin of a day's detected sessions in as a "manual"
    /// block, so one edit / nap leaked its total onto EVERY night. Byte-identical twin of Android
    /// `IntelligenceEngine.editedRowsForDay`.
    static func editedRowsForDay(_ editedRows: [CachedSleepSession], day: String,
                                 tzOffsetSeconds: Int) -> [CachedSleepSession] {
        editedRows.filter { AnalyticsEngine.dayString($0.endTs, offsetSec: tzOffsetSeconds) == day }
    }

    private func sleepEditedDaily(_ daily: DailyMetric, detected: [CachedSleepSession],
                                 editsByStart: [Int: CachedSleepSession],
                                 habitualMidsleepSec: Int?) -> DailyMetric {
        guard !editsByStart.isEmpty else { return daily }
        let detectedTuples = detected.map { (startTs: $0.startTs, stagesJSON: $0.stagesJSON) }
        let editedStages = editsByStart.mapValues { $0.stagesJSON }
        // A hand-logged nap is a userEdited row with NO detected twin , it would never be
        // visited by the substitution pass, so its minutes were dropped from the day's Rest
        // total. Pass those twinless rows through the union channel so they fold in. (#518/#508)
        let detectedStarts = Set(detected.map { $0.startTs })
        let manualTuples = editsByStart
            .filter { !detectedStarts.contains($0.key) }
            .map { (startTs: $0.key, stagesJSON: $0.value.stagesJSON) }
        // #525/#547: supply each block's EFFECTIVE onset (audit finding C / #8) keyed by its stable
        // detected startTs, plus the device tz offset + learned habitual midsleep, so the edited recompute
        // picks the SAME MAIN NIGHT the Sleep tab shows. The onset must be the user-CORRECTED bedtime
        // (`startTsAdjusted ?? startTs`) when a block was edited, NOT the immutable detected start , a
        // bedtime edit crossing the overnight boundary would otherwise let the seam and the Sleep tab pick
        // different blocks. For a detected block the effective onset is its edited twin's effectiveStartTs
        // (an edit moves the onset) when edited, else the detected block's own effectiveStartTs; for a
        // twinless manual block it's that row's effectiveStartTs. Without these the seam falls back to the
        // legacy SUM and an overnight+nap day would re-include the nap in the headline total.
        var onsetByStart: [Int: Int] = [:]
        for d in detected {
            onsetByStart[d.startTs] = editsByStart[d.startTs]?.effectiveStartTs ?? d.effectiveStartTs
        }
        for (start, edit) in editsByStart where !detectedStarts.contains(start) {
            onsetByStart[start] = edit.effectiveStartTs
        }
        guard let r = SleepStageTotals.dailyAggregateHonoringEdits(detected: detectedTuples,
                                                                   edited: editedStages,
                                                                   manual: manualTuples,
                                                                   onsetByStart: onsetByStart,
                                                                   offsetSec: TimeZone.current.secondsFromGMT(),
                                                                   habitualMidsleepSec: habitualMidsleepSec),
              r.editApplied else { return daily }
        let agg = r.sleep
        return daily.with(totalSleepMin: agg.totalSleepMin, efficiency: agg.efficiency,
                          deepMin: agg.deepMin, remMin: agg.remMin, lightMin: agg.lightMin)
    }

    /// Re-derive the skin-temperature deviation (°C) for a night against the freshly-seeded personal
    /// baseline, mirroring the avgHrv→recovery re-score. Nil when the night had no wear-gated mean or
    /// the skin-temp baseline isn't usable yet (< minNightsSeed) , honest cold-start. Rounded to 2 dp
    /// to match the imported/demo precision. APPROXIMATE.
    private func recomputeSkinTempDev(_ nightly: Double?, _ base: BaselineState?) -> Double? {
        guard let v = nightly, let b = base, b.usable else { return nil }
        return (Baselines.deviation(v, state: b).delta * 100.0).rounded() / 100.0
    }

    /// The user's habitual midsleep (local time-of-day seconds), or nil under `habitualMinDays` of
    /// history (cold-start). Reads the stored sleep sessions (imported + computed) over the window, makes
    /// one `HistoryBlock` per session , start/end are the EFFECTIVE (edited) bounds so a corrected bedtime
    /// is learned, dayKey is the LOCAL calendar day of the midpoint , and defers to
    /// `SleepStageTotals.habitualMidsleepSec`, which keeps the longest block per day (naps drop out). The
    /// imported + computed sets can overlap; both are unioned and the learner de-dupes per day by length.
    /// (#547) Mirrors the Android `computeHabitualSleep`.
    /// CONSUME (#531 / H8): the prior pass's persisted v18 BAND sleep_state for sessions overlapping
    /// `[from, to]`, expanded to timestamped `(ts, state)` samples on the 30 s epoch grid, for the H7
    /// morning-stillness guard's re-onset confirmation. Reads the computed sessions in the window, then each
    /// one's persisted per-epoch sleep_state (NULL when never banded , first pass / imported night), and maps
    /// epoch `i` to `startTs + i*30`. Empty when nothing is banded yet, so the guard simply falls back to the
    /// HR bar. Honest: only real banded states are surfaced, never a fabricated reading. The grid here mirrors
    /// `SleepStager`'s 30 s epoch grid, so an epoch's timestamp lands inside the candidate run it scores.
    /// `nonisolated static` (FIX 1): touches only the `store` actor + value params, so the off-main scan
    /// loop calls it without hopping back to the main actor each iteration. Logic identical.
    nonisolated static func bandSleepStateSamples(computedId: String, from: Int, to: Int,
                                                  store: WhoopStore) async -> [(ts: Int, state: Int)] {
        let epochS = 30
        // #899: collapse overlapping timebase-shifted duplicates BEFORE consuming band state. A stale
        // re-banked copy of the night would otherwise feed "asleep" epochs at the OLD times into the H7
        // re-onset guard, letting the stale block keep confirming itself. Read-side only (no bank-recency
        // witness here); the store itself is healed post-upsert in analyzeRecent.
        let sessions = SleepSessionDedup.dedupe(
            (try? await store.sleepSessions(deviceId: computedId, from: from, to: to,
                                            limit: 4000)) ?? []).kept
        // One range read of the window's banked band state, keyed by startTs, instead of a single-row SELECT
        // per kept session. We still expand ONLY the kept (deduped) sessions, in order, so the output is
        // identical to the old per-session loop — just without the N round-trips.
        let stateByStart = (try? await store.sessionSleepStates(deviceId: computedId,
                                                                from: from, to: to)) ?? [:]
        var samples: [(ts: Int, state: Int)] = []
        for s in sessions {
            guard let states = stateByStart[s.startTs], !states.isEmpty else { continue }
            for (i, st) in states.enumerated() {
                samples.append((ts: s.startTs + i * epochS, state: st))
            }
        }
        return samples
    }

    /// Habitual midsleep (local seconds) AND the trailing per-night sleep DURATIONS (hours,
    /// chronological) from the stored sessions over the window — the longest block per LOCAL day, so
    /// naps drop out. One read serves both the main-night midsleep learner (#547) and the personal
    /// sleep-need + regularity that thread into `analyzeDay` (Wave 0 · SL1/T1). The midsleep result is
    /// byte-identical to before; the nightly-hours output is the Swift-side extension.
    private static func computeHabitualSleep(
        store: WhoopStore, importedId: String, computedId: String,
        windowStart: Int, windowEnd: Int, offsetSec: Int
    ) async -> (midsleepSec: Int?, nightlyHours: [Double]) {
        let imported = (try? await store.sleepSessions(deviceId: importedId, from: windowStart,
                                                       to: windowEnd, limit: 4000)) ?? []
        let computed = (try? await store.sleepSessions(deviceId: computedId, from: windowStart,
                                                       to: windowEnd, limit: 4000)) ?? []
        // #899: collapse overlapping timebase-shifted duplicates BEFORE the learner sees the history.
        // A stale re-banked copy of a night lands on a DIFFERENT day key, so the per-day longest-block
        // de-dup below never caught it and the learned midsleep drifted toward the stale timing, which
        // then steered the main-night pick (day assignment) to the stale block. The same collapse also
        // covers an imported night and its computed twin (the longest capture wins, exactly what the
        // per-day length rule chose anyway).
        let merged = SleepSessionDedup.dedupe(imported + computed).kept
        // Longest block per LOCAL day (naps drop out), chosen by in-bed SPAN — reused for BOTH the
        // midsleep learner and the per-night durations (Wave 0 · SL1/T1), so the two can never read a
        // different history. For the DURATIONS we keep TST (span × efficiency), NOT the in-bed span:
        // the need/regularity estimate must be in the same asleep-time units as the `tstSeconds` Rest
        // scores against, or need reads systematically high (validated on real data — an in-bed span
        // over-counts ~0.85 h vs TST). Efficiency is 0..1 (post the v26 unit-heal); a rare nil main
        // night falls back to a typical 0.9.
        var longestByDay: [String: (span: Int, tstHours: Double)] = [:]
        let blocks = merged.compactMap { s -> SleepStageTotals.HistoryBlock? in
            let start = s.effectiveStartTs, end = s.endTs
            guard end > start else { return nil }
            let mid = start + (end - start) / 2
            let dayKey = AnalyticsEngine.dayString(mid, offsetSec: offsetSec)
            let span = end - start
            if span > (longestByDay[dayKey]?.span ?? 0) {
                let eff = s.efficiency.flatMap { (0.0 < $0 && $0 <= 1.0) ? $0 : nil } ?? 0.9
                longestByDay[dayKey] = (span, Double(span) / 3600.0 * eff)
            }
            return SleepStageTotals.HistoryBlock(start: start, end: end, dayKey: dayKey)
        }
        let midsleep = SleepStageTotals.habitualMidsleepSec(blocks, offsetSec: offsetSec)
        // Chronological (day-key string sort == date order) so a recent-window suffix is well-defined.
        let nightlyHours = longestByDay.keys.sorted().compactMap { longestByDay[$0]?.tstHours }
        return (midsleep, nightlyHours)
    }

    /// Floor a unix-seconds timestamp to 00:00:00 of its UTC calendar day. Mirrors the Android
    /// IntelligenceEngine.midnightUtc; the floorMod form is correct for any sign.
    nonisolated static func midnightUtc(_ ts: Int) -> Int { ts - floorMod(ts, 86_400) }

    /// Floor a unix-seconds timestamp to 00:00:00 of its LOCAL calendar day (#277). `offsetSec` is
    /// seconds EAST of UTC. Shift into local time, floor to the local day, shift back:
    /// `ts - floorMod(ts + offsetSec, 86400)`. floorMod keeps the floor correct for negative offsets
    /// and negative timestamps. `offsetSec == 0` reduces exactly to `midnightUtc`. Mirrors the
    /// Android IntelligenceEngine.midnightLocal byte-for-byte.
    /// Fixed-UTC `yyyy-MM-dd` parser — the inverse direction of `AnalyticsEngine.dayString`. Cached
    /// because a `DateFormatter` is expensive to build and this is called per scanned day.
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// LOCAL midnight (unix seconds) of a `yyyy-MM-dd` key, the exact inverse of
    /// `AnalyticsEngine.dayString(_:offsetSec:)`: that one formats `ts + offsetSec` with a fixed-UTC
    /// formatter, so the local midnight of a key is its UTC midnight minus the offset. nil for a
    /// malformed key, so a caller skips that day rather than deleting an unintended window — the same
    /// nil-tolerant-over-fail-fast rule `dayStartUtcSeconds` follows.
    nonisolated static func midnightForDayKey(_ day: String, offsetSec: Int) -> Int? {
        guard let d = dayKeyParser.date(from: day) else { return nil }
        return Int(d.timeIntervalSince1970) - offsetSec
    }

    /// The OLDEST day key a `maxDays` scan window covers, as the store's `yyyy-MM-dd` text key. The scan
    /// walks `offset in 0..<maxDays` back from `nowLocalMidnight`, so the oldest day is `maxDays - 1` days
    /// back — the same arithmetic the loop itself does, named once so the per-day-skip preloads read
    /// exactly the window the loop will visit.
    nonisolated static func dayKeyBound(_ nowLocalMidnight: Int, maxDays: Int, tzOffset: Int) -> String {
        AnalyticsEngine.dayString(nowLocalMidnight - (maxDays - 1) * 86_400, offsetSec: tzOffset)
    }

    nonisolated static func midnightLocal(_ ts: Int, offsetSec: Int) -> Int {
        ts - floorMod(ts + offsetSec, 86_400)
    }

    /// Euclidean modulo (result has the sign of the divisor) , matches Kotlin/Java Math.floorMod, so
    /// the LOCAL-midnight floor is identical across platforms for any sign of ts/offset. Swift's `%`
    /// is a remainder (sign of the dividend), which would mis-floor negative inputs.
    nonisolated private static func floorMod(_ a: Int, _ b: Int) -> Int {
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? r + b : r
    }
}

extension DailyMetric {
    /// Rebuild the immutable DailyMetric with a substituted recovery + skin-temp deviation
    /// (the struct has no `copy()`). (#78)
    func with(recovery r: Double?, skinTempDevC sd: Double?, skinTempC sa: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: totalSleepMin, efficiency: efficiency, deepMin: deepMin,
                    remMin: remMin, lightMin: lightMin, disturbances: disturbances, restingHr: restingHr,
                    avgHrv: avgHrv, recovery: r, strain: strain, exerciseCount: exerciseCount,
                    spo2Pct: spo2Pct, skinTempDevC: sd, respRateBpm: respRateBpm,
                    steps: steps, activeKcalEst: activeKcalEst,
                    spo2Red: spo2Red, spo2Ir: spo2Ir, avgSdnn: avgSdnn,
                    energyCoverageSeconds: energyCoverageSeconds, skinTempC: sa)
    }

    /// Rebuild with substituted sleep-derived fields (a user-corrected wake window), leaving every
    /// non-sleep field untouched. Used by `sleepEditedDaily` so Rest/recovery score the edited sleep. (#318)
    func with(totalSleepMin tsm: Double?, efficiency eff: Double?,
              deepMin dm: Double?, remMin rm: Double?, lightMin lm: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: tsm, efficiency: eff, deepMin: dm, remMin: rm, lightMin: lm,
                    disturbances: disturbances, restingHr: restingHr, avgHrv: avgHrv, recovery: recovery,
                    strain: strain, exerciseCount: exerciseCount, spo2Pct: spo2Pct,
                    skinTempDevC: skinTempDevC, respRateBpm: respRateBpm, steps: steps,
                    activeKcalEst: activeKcalEst, spo2Red: spo2Red, spo2Ir: spo2Ir, avgSdnn: avgSdnn,
                    energyCoverageSeconds: energyCoverageSeconds, skinTempC: skinTempC)
    }
}

extension IntelligenceEngine {
    /// Merge one metric's on-device pass-1 nightly values into the imported-history map.
    /// Imported (cloud) values WIN per day; the computed estimate only fills days the import
    /// does not cover at all (key absent). Twin of the Kotlin `mergeNightlyIntoHistory`.
    nonisolated static func mergeNightlyIntoHistory(
        _ hist: inout [String: Double?], _ nightly: [String: Double?]
    ) {
        // `hist` values are themselves Optional, so `hist[day] == nil` is only
        // true when the KEY is absent — an imported row with a nil value is
        // `.some(.none)` and would shadow the real computed night forever,
        // starving the baseline (the "Needs the strap" bug). Imported non-nil
        // wins; a nil (or absent) slot is backfilled by the computed value.
        for (day, v) in nightly {
            if let existing = hist[day], existing != nil { continue }  // imported non-nil wins
            hist[day] = v
        }
    }
}
