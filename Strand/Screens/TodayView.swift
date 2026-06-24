import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import Foundation

// MARK: - Control Center (the home dashboard) — HomeDensity rewrite
//
// The owner's complaint was "cards then random space". This rebuild is a tight,
// GAPLESS dashboard grid: one column of uniform sections, every gap == NoopMetrics.gap,
// every section break == NoopMetrics.sectionGap, equal margins from ScreenScaffold.
//
// Composition (top → bottom):
//   (a) HERO  — full-width HStack that fills the width EQUALLY: RecoveryRing (left card)
//               + InsightCard "Today's Synthesis" (right card). No lone card, no gap.
//   (b) METRICS — one adaptive LazyVGrid of fixed-104pt StatTiles (Recovery, Strain,
//               Sleep, HRV, RHR, SpO2, Respiratory, Steps, Weight, Calories) each with
//               a 14-day sparkline so the grid tiles perfectly with no empty cells.
//   (c) LAST WORKOUTS — the SAME adaptive grid of fixed-104pt workout StatTiles.
//   (d) DATA SOURCES — one full-width NoopCard footer of SourceBadges + counts.
//
// Sparse series (weight) fall back to ALL history so a tile never shows an empty
// state when data exists. Only locked StrandDesign components are used.

struct TodayView: View {
    @EnvironmentObject var repo: Repository
    // PERF (scroll stutter): TodayView deliberately does NOT observe `LiveState` directly. A connected
    // strap publishes `LiveState` ~1 Hz (heart rate + each R-R packet), and an `@EnvironmentObject live`
    // here would invalidate the ENTIRE Today `body` on every tick — re-evaluating the scene backdrop, the
    // three rings, every sparkline tile, the HR chart and the cards while the user is mid-scroll, which is
    // the reported jank. Instead the handful of regions that actually show live values (the top-bar
    // recording light, the "syncing history" note, the strap battery + sync rows) are extracted into small
    // leaf subviews that each own their OWN `@EnvironmentObject live`, so a 1 Hz tick only re-renders those
    // dots/rows, never the rest of the dashboard. The memoized derivations below already absorbed the
    // EXPENSIVE recomputes; this removes the cheap-but-constant view-tree re-evaluation flood on top.
    @EnvironmentObject var profile: ProfileStore
    @EnvironmentObject var router: NavRouter
    /// The "update ringer" — the bell in the top bar opens this inbox; dismissed Today cards post into it.
    @EnvironmentObject var updateStore: UpdateStore

    // Imperial/Metric display preference (D#103). Only the Weight tile carries a convertible unit here.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    // Day-cycle scene backdrop (#698). Default ON. When the user turns it off in Settings → Appearance,
    // Today drops the SceneScreenBackground and falls back to the plain dark surfaceBase canvas. The
    // cards already sit on an opaque canvas, so readability is unchanged either way.
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true
    // Effort display scale (#268) — drives the Effort tile's value + caption. Display-only.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    // Editable Key-Metrics layout (#251) — an ordered list of the enabled tiles, persisted display-only.
    // Empty/unset shows the full default order. The "Edit" affordance on the section opens a local sheet.
    @AppStorage(KeyMetricPrefs.layoutKey) private var keyMetricsRaw = ""
    @State private var showingMetricsEditor = false
    private var enabledKeyMetrics: [KeyMetric] { KeyMetricPrefs.decodeEnabled(keyMetricsRaw) }

    // "Your cards" customisable dashboard (WHOOP "My Dashboard") — a persisted, reorderable selection of
    // metric cards. Empty/unset shows the sensible default set (Stress / Fitness age / Vitality + HRV +
    // Resting HR). The "CUSTOMISE" link on the section header opens a local sheet (no new nav destination).
    // Persistence is display-only — these cards read the SAME values the rest of Today already loads.
    @AppStorage(DashboardCardPrefs.selectionKey) private var dashboardCardsRaw = ""
    @State private var showingDashboardEditor = false
    // Hydration tracker (opt-in, default OFF). When off the hydration dashboard card is hidden even if a
    // user had it in their saved selection — the feature owns its own gate.
    @AppStorage(HydrationStore.enabledKey) private var hydrationEnabled = false
    /// Today's hydration total + goal (ml), loaded in loadAll when the feature is on. nil hides the value.
    @State private var hydrationTotalML: Double?
    @State private var hydrationGoalML: Int?
    private var enabledDashboardCards: [DashboardCard] {
        // Opt-in gate (mirrors the Android TodayScreen filter `it != HYDRATION || hydrationEnabled`):
        // the hydration card only renders when the feature is on AND the user has added it via CUSTOMISE.
        // It's not in the default selection, so a fresh install never shows it until both are true.
        DashboardCardPrefs.decodeEnabled(dashboardCardsRaw)
            .filter { hydrationEnabled || $0 != .hydration }
    }

    // 14-day sparkline series, keyed by metric key. Loaded once in .task.
    @State private var sparks: [String: [Double]] = [:]
    @State private var workouts: [WorkoutRow] = []
    @State private var appleDays: [AppleDaily] = []
    // Design Reset / #582 — the pinned "Your cards" values (Stress / Fitness age / Vitality), surfaced
    // on Today so the buried Explore features sit on the home screen. Loaded in loadAll; nil hides the row.
    @State private var stressToday: Double?
    @State private var fitnessAgeToday: Double?
    @State private var vitalityToday: Double?
    /// Distinct days + sleep sessions imported from a Mi Band (Mi Fitness), for the Data Sources row.
    @State private var xiaomiDays = 0
    @State private var xiaomiSleeps = 0

    // The Rest SCORE (0–100) for the logical day — IntelligenceEngine's Rest composite, written to the
    // `sleep_performance` metric series (imported export wins, computed strap fills). The Key-Metrics
    // "Rest" tile shows THIS, formatted like Charge/Effort, with hours-in-bed kept as the caption — the
    // tile previously showed hours where the score belonged (#248). nil until loaded / no night yet.
    @State private var restScore: Double?

    // Component 4 — the REAL per-day merge winner (provenance) for the selected day's derived scores,
    // keyed by metric key ("recovery" / "sleep_performance"); the value is the raw source id the resolver
    // returned (e.g. "my-whoop", "my-whoop-noop", "apple-health"). Resolved once per load via
    // `resolvedSeries` (the same imported-WHOOP > NOOP-computed > Apple-Health precedence the dashboard
    // merge uses), so a provenance badge reflects which source actually supplied that day's number rather
    // than a blanket "on-device" claim. Absent until loaded / when a day has no value. (spec 2026-06-20)
    @State private var provenanceByMetric: [String: String] = [:]

    // On-device steps ESTIMATE per day (key "steps_est", computed "-noop" source). The Steps tile
    // prefers a REAL step count (strap @57 counter / Apple Health); only when a day has neither does it
    // fall back to this estimate, shown with an "est." caption so it's never read as a measured count.
    // Loaded once via exploreSeries (same merged read fitness_age/vitality use), keyed by day. (#150)
    @State private var stepsEstByDay: [String: Int] = [:]

    // Today's heart rate as 5-minute bucket means (midnight → now), for the 24h trend chart.
    @State private var hrPoints: [TrendPoint] = []

    // The night's sleep session overlapping the HR window — shaded as a band on the HR chart and
    // used to anchor the recovery marker at wake time (WHOOP-style Overview HR annotations).
    @State private var sleepToday: CachedSleepSession?

    // TODAY's in-progress Effort (NOOP 0–100 axis), recomputed over the day's HR (local-midnight→now)
    // each load so the gauge tracks today as it accumulates rather than waiting on the heavy daily pass
    // to persist — which early in the day would otherwise surface yesterday's completed Effort or a stale
    // 0.0 (#402). nil below StrainScorer.minReadings (we then fall back to the stored daily row) and on
    // any navigated past day (those use the stored value).
    @State private var liveTodayStrain: Double?

    // The HR chart's x-axis window. Today → midnight…now; a navigated PAST day → the full calendar
    // day (midnight…next midnight) so a morning with no banked data reads as empty space rather than
    // the axis silently starting at the first sample (#overview-hr gap clarity).
    @State private var hrAxis: ClosedRange<Date>?

    // Day navigation — 0 = today (the logical day), 1 = yesterday, … The DayNavBar chevrons and date
    // jump drive this, and every day-scoped read-out (hero synthesis, the Key-Metrics tiles, the HR
    // trend and Rest score) resolves to the selected day instead of always showing today. Mirrors the
    // Android TodayScreen.selectedDayOffset. Loads re-run when this changes (see .task(id:)).
    @State private var selectedDayOffset = 0
    // #605: one-shot guard so the dashboard auto-lands on the most recent day WITH data the first time it
    // opens to an empty today (fresh install, or a strap mid-backfill whose newest banked day is older than
    // today). After the single auto-land the user can chevron freely without it snapping forward again.
    @State private var didAutoLandLatest = false
    // iOS top-bar state: the date-jump popover and the profile/settings sheet.
    @State private var showDayPicker = false
    @State private var showSettings = false
    /// The Updates inbox sheet (opened by the header bell). Shared across both platforms.
    @State private var showUpdatesInbox = false

    /// The NEWEST day-key (max yyyy-MM-dd in `repo.days`) announced to the inbox. Persisted (not @State)
    /// so a relaunch over the same history never re-announces (#521). We trigger on a strictly-newer KEY,
    /// not a count: a recompute that deletes-then-reinserts the window dips/recovers the count but keeps
    /// the same max key, so churn can't masquerade as new history. Empty = no baseline yet (first load
    /// just records the key silently — we only announce genuine forward growth).
    @AppStorage("today.lastAnnouncedDayKey") private var lastAnnouncedDayKey = ""

    // Per-card "dismissed into the inbox" flags for the two Today info-cards. A small × on each card
    // sets these (and posts a `.dismissedCard` update); "Restore to Today" in the inbox flips them back
    // (via the shared `TodayCardDismissal.flagKey`). @AppStorage matches the file's existing prefs style.
    @AppStorage(TodayCardDismissal.flagKey("scoresBuilding")) private var scoresBuildingDismissed = false
    @AppStorage(TodayCardDismissal.flagKey("newHere")) private var newHereDismissed = false

    // Memoized repo-derived values that are expensive (a full-history sort + per-call
    // `repo.days.map`) yet INDEPENDENT of the ~1 Hz live-HR ticks that re-evaluate `body`
    // while a strap streams. `LiveState` publishes R-R every second, so `body` (and every
    // section it renders) re-runs ~1 Hz; recomputing Readiness and the recovery calibration
    // over the whole history on each of those passes is pure waste. Cache them keyed on a
    // cheap repo fingerprint and rebuild only when that changes — the same memoization
    // SleepView and StressView already use to absorb the live-HR re-render flood.
    @State private var derived: TodayDerived?
    @State private var derivedKey: TodayInputKey?

    // Support sheet (donate + contact) — opened from the home toolbar on macOS, and from an
    // in-content control on iOS (a primary tab has no NavigationStack, so a `.toolbar` item never
    // renders on iPhone — the affordance was dead there before this in-flow button + sheet, #185-class).
    @State private var showingSupport = false

    // "How your scores work" guide — presented at a specific score's section when the ⓘ on that
    // score (or the first-run card) is tapped. nil = not shown. ScoreSection is Identifiable, so
    // .sheet(item:) drives both presentation and the deep-link target in one binding.
    @State private var guideSection: ScoreSection?
    /// `nil` means the user tapped the generic first-run card / a non-section entry: open at the top.
    @State private var showGuideTop = false

    // One-time, dismissible first-run card pointing at the guide. Set true by either the primary tap
    // or the ✕, so it never shows again. @AppStorage matches the file's existing prefs style (#103).
    @AppStorage(Self.guideCardSeenKey) private var scoringGuideCardSeen = false
    static let guideCardSeenKey = "scoringGuideCardSeen"

    // H6 — the steps-calibration sheet, opened from the Steps tile when it's showing an ESTIMATE (a WHOOP
    // 4.0 user, whose strap doesn't transmit steps). Presents the SAME StepsCalibrationSheet Settings uses,
    // so a 4.0 user can reach calibration from where they actually notice the "est." caption.
    @State private var showStepsCalibration = false

    // THE single grid definition — every tile group reuses it so margins line up. minimum 150 (not
    // 168) so two tiles reliably fit a phone's ~345pt content width; at 168 the grid sat on the
    // single-vs-two-column boundary and could collapse to one full-width column on a narrow phone.
    private let grid = [GridItem(.adaptive(minimum: 150), spacing: NoopMetrics.gap)]

    /// The logical day the selector resolves to: offset 0 is today's logical day (rolls at 04:00 like
    /// `repo.today`), past offsets count back from it. Presentation-only — used to pick which stored row
    /// is on screen and to anchor the HR-trend window. Mirrors Android TodayScreen.selectedDay.
    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }
    /// The day key the day-scoped read-outs (Rest score, HR window, sleep band) key on. At offset 0 it
    /// follows `repo.today?.day` so it tracks the row the resolver actually surfaces — including the
    /// non-UTC pre-04:00 case (#304) where Today is the LOCAL-calendar-day row, not the logical-day one.
    /// Falls back to the logical key when no row is banked yet. Past offsets use the logical key directly.
    private var selectedDayKey: String {
        if selectedDayOffset == 0, let todayKey = repo.today?.day { return todayKey }
        return Repository.localDayKey(selectedLogicalDay)
    }

    /// The DailyMetric shown for the selected day. Offset 0 prefers the live `repo.today` (so the small
    /// hours after midnight still show the logical day's banked row), past offsets look the stored row up
    /// by key. nil when no row exists for that day — every read-out then renders its honest empty state.
    private var displayDay: DailyMetric? {
        if selectedDayOffset == 0 {
            return repo.today ?? repo.days.last(where: { $0.day == selectedDayKey })
        }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }

    /// Recovery cold-start: recovery is nil until the HRV baseline crosses the seed gate
    /// (Baselines.minNightsSeed valid nights). While calibrating, this is the count of nights
    /// banked so far — it drives an honest "Calibrating, N of 4 nights" on the recovery ring,
    /// the synthesis card and the Key Metrics tile instead of a bare empty state. It self-clears
    /// the moment recovery populates, and never claims "calibrating" at/above the seed gate.
    /// Mirrors Android TodayScreen.recoveryCalibrationNights (7b5f212). Only meaningful for today —
    /// a past day with no recovery is missing data, not mid-calibration, so navigated days return nil.
    private var recoveryCalibration: Int? {
        guard selectedDayOffset == 0 else { return nil }
        if derivedKey == todayInputKey, let d = derived { return d.calibration }
        return computeCalibration()
    }

    /// The most recent fully-SCORED recovery day to carry over on TODAY while tonight's recovery hasn't
    /// been computed yet (#543). Right after the logical-day rollover the new day has no recovery (the new
    /// night isn't scored until you wear it tonight), so a baseline-established user — past calibration,
    /// so `recoveryCalibration` is nil — saw the whole recovery side blank ("No Data" Charge AND blank
    /// HRV / resting-HR / respiratory / SpO₂ tiles + Synthesis) while live HR kept ticking, which reads
    /// as broken. This is the ONE prior row every recovery-derived read-out carries over from, the way
    /// WHOOP keeps showing last recovery until the new one lands. It NEVER fabricates a number for the new
    /// day — each carried tile shows the REAL prior value, labelled as prior, and any metric the prior row
    /// genuinely lacks still falls through to "—". Non-nil only when: it's today, today itself has no
    /// recovery, and we're not mid-calibration (calibration owns its own copy). Past offsets / scored
    /// today / mid-calibration all return nil so live behaviour is unchanged.
    private var lastScoredRecoveryDay: DailyMetric? {
        Self.lastScoredRecoveryDay(
            days: repo.days,
            selectedDayKey: selectedDayKey,
            isToday: selectedDayOffset == 0,
            todayScored: displayDay?.recovery != nil,
            isCalibrating: recoveryCalibration != nil)
    }

    /// Pure carry-over selector behind `lastScoredRecoveryDay` — extracted so the gate + selection can be
    /// unit-tested without a live view (mirrors `buildingHintCopy` / the Android `lastScoredRecoveryDay`).
    /// Returns the freshest scored prior row to carry over, or nil. `days` is oldest→newest; the chosen
    /// row is the last with a non-nil recovery that ISN'T today's (still-nil) key. nil unless: it's today,
    /// today itself isn't scored, and we're not mid-calibration (calibration owns its own copy) — so past
    /// days / a scored today / a calibrating today all carry nothing and live behaviour is unchanged.
    static func lastScoredRecoveryDay(days: [DailyMetric], selectedDayKey: String,
                                      isToday: Bool, todayScored: Bool, isCalibrating: Bool) -> DailyMetric? {
        guard isToday, !todayScored, !isCalibrating else { return nil }
        // Defensive future-day guard (#547): the carry-over must NEVER select a day after today's key, or a
        // stray future-dated row (a bad-clock strap that slipped past the ingest gate / pre-heal DB) would
        // surface as "last night · 12 Jul". `selectedDayKey` is today's logical-day key here (isToday), and
        // yyyy-MM-dd compares lexicographically, so `$0.day < selectedDayKey` keeps only genuine prior days.
        // Belt-and-suspenders on top of the gate + one-time heal — cheap and never wrong.
        return days.last(where: { $0.recovery != nil && $0.day < selectedDayKey })
    }

    /// "Last night · <date>" stamp for the carried-over recovery row, keyed on that scored day's own
    /// date. Shared by every carried recovery read-out so the prior-day provenance reads identically.
    private func carriedCaption(_ prior: DailyMetric) -> String {
        "Last night · \(Self.lastChargeDateFmt(prior.day))"
    }

    /// The most recent SCORED Charge to carry over on TODAY (#543) — the prior row's recovery value plus
    /// its "Last night · <date>" caption. Derived from `lastScoredRecoveryDay` so Charge and every other
    /// recovery tile carry the SAME prior day; recovery is always present on that row by construction.
    private var lastScoredCharge: (value: Double, caption: String)? {
        guard let prior = lastScoredRecoveryDay, let rec = prior.recovery else { return nil }
        return (rec, carriedCaption(prior))
    }

    // MARK: Component 2 — explained score states (calibrating / carriedLastNight / needsStrap)

    /// The Charge (recovery) score's explained state for the selected day. Built ENTIRELY from the
    /// bindings the rings/tiles already drive — today's recovery, the running calibration count, the
    /// #543 carry-over — re-expressed through the honest `MetricTileState` precedence so the hero/tile show
    /// a clear state, detail and next step rather than a bare blank when there's no number. `calibrating`
    /// reports the nights REMAINING (seed gate minus banked), never a fabricated value.
    private var chargeScoreState: MetricTileState {
        MetricTileState.resolve(
            hasTodayValue: displayDay?.recovery != nil,
            calibratingNightsRemaining: recoveryCalibration.map { max(1, Baselines.minNightsSeed - $0) },
            carriedDate: lastScoredRecoveryDay.map { Self.lastChargeDateFmt($0.day) })
    }

    // MARK: Component 3 — recording status

    /// The strap's live recording state, mapped from the connection, the live heart-rate sample, and the
    /// last-sync timestamp. Only TODAY carries a recording chip (a navigated past day isn't "recording
    /// now"), so this returns the honest state at offset 0 and `nil` otherwise (the chip then isn't
    /// rendered). "Recording" requires BOTH a live connection AND a current live HR sample, so a connected
    /// strap that isn't yet streaming HR reads as a last-sync / not-recording state, not a false "Recording".
    /// Resolves the recording state for the selected day from a `LiveState` snapshot. Takes `live` as a
    /// parameter rather than reading `self.live` so TodayView itself doesn't observe `LiveState` (see the
    /// PERF note on the missing `@EnvironmentObject live`); the small `RecordingStatusLight` subview that
    /// DOES observe `live` calls this. Past days aren't "recording", so it's nil off offset 0.
    static func recordingState(live: LiveState, selectedDayOffset: Int) -> RecordingState? {
        guard selectedDayOffset == 0 else { return nil }
        // #580 — a connected WHOOP 5/MG streaming live HR but offloading no history reads "Connected —
        // history sync is experimental on 5.0" rather than a WHOOP-4-style "not recording"/sync-error.
        // BLEManager only flips this true while connected + streaming, so it overrides the honest mapper.
        if live.connected && live.historySyncExperimental { return .historyExperimental }
        return RecordingState.resolve(connected: live.connected,
                                      heartRate: live.heartRate,
                                      lastSyncedAt: live.lastSyncedAt)
    }

    // MARK: Component 4 — provenance badge (the real per-day merge winner)

    /// The display name for a derived score's per-day merge winner ("On-device" / "Whoop" / "Apple
    /// Health"), or nil when no source supplied that metric for the selected day (the badge is then
    /// hidden rather than guessing). Delegates to the PURE `provenanceDisplayLabel` mapper so the
    /// raw-source-id → spec-label mapping unit-tests without the live view.
    private func provenanceLabel(_ metricKey: String) -> String? {
        guard let raw = provenanceByMetric[metricKey] else { return nil }
        return Self.provenanceDisplayLabel(rawSource: raw, deviceId: repo.deviceId)
    }

    /// PURE mapper (unit-testable) — a raw resolver source id onto the spec's provenance labels, given
    /// the strap's real `deviceId`. The NOOP-computed strap sibling (`deviceId + "-noop"`) reads
    /// "On-device" (scored on THIS device from the raw strap stream); the imported strap source
    /// (`deviceId`, normally "my-whoop") reads "Whoop"; the Apple-Health source reads "Apple Health".
    /// Any other real source (Mi Band, Health Connect, nutrition) keeps its `FusionSource.displayName`
    /// — still the genuine merge winner, never a blanket claim. Mirror EXACTLY in Kotlin.
    static func provenanceDisplayLabel(rawSource: String, deviceId: String) -> String {
        if rawSource == deviceId + "-noop" { return "On-device" }
        if rawSource == deviceId || rawSource == Repository.whoopSource { return "Whoop" }
        if rawSource == Repository.appleHealthSource { return "Apple Health" }
        // Fall back to the FusionSource display name for any other known source; else the raw id.
        return FusionSource(rawValue: rawSource)?.displayName ?? rawSource
    }

    /// The tint for a provenance badge — gold for Whoop, cyan for Apple Health, the positive status hue
    /// for on-device, matching the Data Sources footer so the same source reads the same colour on Today.
    private func provenanceTint(_ metricKey: String) -> Color {
        switch provenanceLabel(metricKey) {
        case "Whoop":       return StrandPalette.accent
        case "Apple Health": return StrandPalette.metricCyan
        default:            return StrandPalette.statusPositive
        }
    }

    /// Parses a stored `yyyy-MM-dd` day key in the device-local zone (matching how DailyMetric.day
    /// is written) — local so a key never shifts a day under timezone conversion.
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    /// "d MMM" for a stored `yyyy-MM-dd` day key, used by the carried-over Charge caption (#543). Falls
    /// back to the raw key if it can't be parsed so the caption is never empty.
    private static func lastChargeDateFmt(_ dayKey: String) -> String {
        guard let date = dayKeyParser.date(from: dayKey) else { return dayKey }
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("dMMM")
        return f.string(from: date)
    }

    /// On-device training-readiness synthesis (HRV / resting-HR / load). Read through the
    /// memoized cache so the full-history sort inside `evaluate` runs once per data change,
    /// not once per ~1 Hz `body` pass while HR streams.
    private var readiness: ReadinessEngine.Readiness {
        if derivedKey == todayInputKey, let d = derived { return d.readiness }
        return computeReadiness()
    }

    // MARK: Memoization plumbing (absorbs the 1 Hz live-HR body flood)

    /// Cached expensive derivations and the inputs they were built from.
    private struct TodayDerived { let readiness: ReadinessEngine.Readiness; let calibration: Int? }

    /// A cheap, O(1) fingerprint of the inputs `derived` depends on. Recomputed every render
    /// (and per accessor call), but it only holds counts + the identity of the first/last and
    /// today rows + the selected offset, so equality is fast and never walks the history.
    private struct TodayInputKey: Equatable {
        let loaded: Bool
        let daysCount: Int
        let firstDay: String?
        let lastDay: DailyMetric?
        let today: DailyMetric?   // covers repo.today?.recovery (calibration) and day rollover
        let offset: Int
        let refreshSeq: Int
    }

    private var todayInputKey: TodayInputKey {
        TodayInputKey(
            loaded: repo.loaded,
            daysCount: repo.days.count,
            firstDay: repo.days.first?.day,
            lastDay: repo.days.last,
            today: repo.today,
            offset: selectedDayOffset,
            refreshSeq: repo.refreshSeq)
    }

    private func computeReadiness() -> ReadinessEngine.Readiness {
        // Carry-over (#543): Readiness anchors on the day whose row carries today's vitals. Normally that's
        // today's logical day; right after the rollover today has no scored row, so `evaluate` would read
        // `.insufficient` and the whole Readiness card would VANISH while live HR ticks — the same blank
        // the carried Charge/Synthesis avoid. So when carrying, anchor Readiness on the last scored day's
        // key instead (the section header then stamps "Last night · <date>"). Honest: it's the real prior
        // read, not a fabricated today's, and today's own readiness wins the instant tonight is scored.
        let anchor = lastScoredRecoveryDay?.day ?? Repository.logicalDayKey(Date())
        return ReadinessEngine.evaluate(days: repo.days, today: anchor)
    }

    private func computeCalibration() -> Int? {
        guard selectedDayOffset == 0 else { return nil }
        return RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                                hasRecovery: repo.today?.recovery != nil)
    }

    private func buildDerived() -> TodayDerived {
        TodayDerived(readiness: computeReadiness(), calibration: computeCalibration())
    }

    /// Synthesis-card copy while the recovery baseline calibrates; nil otherwise. Built as
    /// LocalizedStringKey literals so the String Catalog picks up the %lld patterns.
    private var calibrationStatus: LocalizedStringKey? {
        recoveryCalibration == nil ? nil : "Calibrating"
    }
    private var calibrationDetail: LocalizedStringKey? {
        guard let n = recoveryCalibration else { return nil }
        return "Learning your baseline, \(n) of \(Baselines.minNightsSeed) nights."
    }

    /// The iOS tab is already labelled "Today", and "Control Center" collides with the OS feature of
    /// that name (on both platforms). Match the tab on iOS; keep the established name on macOS.
    private var screenTitle: LocalizedStringKey {
        #if os(iOS)
        "Today"
        #else
        "Control Center"
        #endif
    }

    /// The big scaffold title — suppressed on iOS, where `todayTopBar` replaces it; macOS keeps its
    /// "Control Center" header.
    private var scaffoldTitle: LocalizedStringKey? {
        #if os(iOS)
        nil
        #else
        screenTitle
        #endif
    }

    #if os(iOS)
    /// The day-nav label: relative for today/yesterday, else a short date.
    private var dayNavLabel: String {
        switch selectedDayOffset {
        case 0:  return "Today"
        case 1:  return "Yesterday"
        default:
            let d = Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: Date()) ?? Date()
            return Self.navDayFmt.string(from: d)
        }
    }

    private static let navDayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    /// Picker binding that converts a chosen date back to a whole-day offset (capped at today).
    private var dayPickerBinding: Binding<Date> {
        Binding(
            get: { Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: Date()) ?? Date() },
            set: { newValue in
                let cal = Calendar.current
                let days = cal.dateComponents([.day], from: cal.startOfDay(for: newValue),
                                              to: cal.startOfDay(for: Date())).day ?? 0
                selectedDayOffset = max(0, days)
                showDayPicker = false
            }
        )
    }

    /// Compact WHOOP-style top bar: a profile/settings button (left), the centred ‹ Today › day-nav
    /// (bold, tappable to jump to a date), and the strap-battery badge (right).
    /// Apple-style large-title header: a tappable "Today ⌄" + full date on the left (taps to change day),
    /// then updates / quick-add / and an OBVIOUS menu avatar (opens Settings) on the right.
    @ViewBuilder private var todayTopBar: some View {
        HStack(alignment: .center, spacing: 10) {
            Button { showDayPicker = true } label: {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(dayNavLabel)
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Text(selectedLogicalDay.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(dayNavLabel). Change day")
            .popover(isPresented: $showDayPicker) {
                DatePicker("", selection: dayPickerBinding, in: ...Date(), displayedComponents: [.date])
                    .datePickerStyle(.graphical).labelsHidden().padding(12)
            }

            Spacer(minLength: 8)

            // Uniform 36pt circular icon set: recording-status light, updates bell, quick-add (+), menu.
            HStack(spacing: 8) {
                // Recording status — a colour-coded light (green recording / amber synced / red not
                // recording), replacing the old full-width banner. Taps to Devices to connect. Its OWN
                // subview observes LiveState so a ~1 Hz HR tick re-renders just this 36pt dot, not all of
                // Today (the scroll-stutter fix — see the @EnvironmentObject note at the top of the type).
                RecordingStatusLight(selectedDayOffset: selectedDayOffset) {
                    StrandHaptic.selection.play(); router.openDevices()
                }
                // Updates bell.
                Button { showUpdatesInbox = true } label: {
                    Image(systemName: updateStore.unreadCount > 0 ? "bell.badge" : "bell")
                        .font(.system(size: 15, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(StrandPalette.surfaceInset))
                        .overlay(alignment: .topTrailing) {
                            if updateStore.unreadCount > 0 {
                                Text("\(min(updateStore.unreadCount, 99))")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(StrandPalette.goldDeepText)
                                    .padding(.horizontal, 3.5).padding(.vertical, 1)
                                    .frame(minWidth: 14)
                                    .background(Capsule().fill(StrandPalette.statusCritical))
                                    .offset(x: 2, y: -1)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Updates")
                // Quick-action + (the accented primary — gold, same 36 size as the rest).
                Button { router.requestQuickActions() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(StrandPalette.goldDeepText)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(StrandPalette.accent))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quick actions")
                .accessibilityHint("Start a workout, log your journal, or breathe")
                // Menu (Settings) — the avatar, same 36 size.
                Button { showSettings = true } label: {
                    ProfileAvatarView(imageData: profile.avatarImageData, size: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Menu and settings")
            }
        }
        .frame(height: 46)
    }

    private func topNavChevron(_ name: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? StrandPalette.accent : StrandPalette.textTertiary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    /// Settings presented as a sheet from the top-bar profile button (sheets inherit the app
    /// environment on iOS, so SettingsView gets the same objects it has under the More tab).
    private var settingsSheet: some View {
        NavigationStack {
            SettingsView()
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showSettings = false }.foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }
    #endif

    /// The Updates "ringer": a bell button (~30pt) with a small gold unread-count badge. Tapping opens
    /// the Updates inbox sheet. Shared by the iOS top bar and the macOS toolbar.
    private var updateBell: some View {
        Button { showUpdatesInbox = true } label: {
            Image(systemName: updateStore.unreadCount > 0 ? "bell.badge" : "bell")
                .font(.system(size: 18))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 34, height: 34)
                .overlay(alignment: .topTrailing) {
                    if updateStore.unreadCount > 0 {
                        Text("\(min(updateStore.unreadCount, 99))")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(StrandPalette.goldDeepText)
                            // Fixed 14pt square + Circle() = a true CIRCLE on both platforms, kept INSIDE
                            // the 34pt bell frame (offset -1,1) so the macOS toolbar (at the window's top
                            // edge) no longer clips the badge's top (Aaron 2026-06-23).
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(StrandPalette.statusCritical))
                            .offset(x: -1, y: 1)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(updateStore.unreadCount > 0
                            ? "Updates, \(updateStore.unreadCount) unread"
                            : "Updates")
    }

    /// The local hour driving the day-cycle scene. DEBUG promo harness: a pinned `--demo-hour` frame
    /// overrides it; otherwise (and always in Release) the live clock hour. Byte-identical in Release.
    private var demoSceneHour: Int {
        #if DEBUG
        return DemoDayHarness.hour ?? Calendar.current.component(.hour, from: Date())
        #else
        return Calendar.current.component(.hour, from: Date())
        #endif
    }

    var body: some View {
        ScreenScaffold(title: scaffoldTitle, onRefresh: { await repo.refresh() },
                       // PERF (scroll): lazy column so the scaffold materialises Today's content on demand.
                       // Today supplies its own inner eager VStack (below), so the staggered section reveal is
                       // unchanged — this only defers building the single inner stack until it scrolls in.
                       // Byte-identical layout (LazyVStack == eager VStack alignment/spacing/header).
                       lazy: true,
                       // PERF (scroll stutter): the day-cycle scene is a static masked Image. CoreAnimation
                       // already caches it as a stable image layer, so it does NOT re-rasterize on body
                       // re-evals or scroll. NO .drawingGroup() — wrapping this 600pt masked image in a
                       // second offscreen pass DOUBLED its cost and re-rasterised it on every TodayView
                       // body re-eval (the masked image is itself one offscreen pass). That was a v7.0.2
                       // lag regression; removing the flatten restores native layer caching.
                       topBackground: showDayCycleBackground
                           ? AnyView(SceneScreenBackground(hour: demoSceneHour)) : nil) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                #if os(iOS)
                // Compact top bar: profile/settings (left) · ‹ Today › day-nav (centre, bold) · strap
                // battery (right). Replaces the big title + the full-width day-nav pill (WHOOP-style).
                todayTopBar
                HealthAlertBanner()
                #else
                HealthAlertBanner()
                // Browse past days — chevrons + a date jump capped at today (no future days).
                DayNavBar(selectedOffset: selectedDayOffset) { selectedDayOffset = $0 }
                #endif
                // The "still building" and "new here?" prompts are about getting today's scores going,
                // so they stay anchored to today rather than reappearing on every navigated past day.
                if selectedDayOffset == 0 && repo.today?.recovery == nil {
                    // While the strap is mid-offload, say so — empty tiles read as final otherwise (#77).
                    // Its own subview observes LiveState (backfilling + chunk count tick during an offload)
                    // so it refreshes without re-rendering the rest of Today (scroll-stutter fix).
                    SyncingHistoryNoteIfBackfilling()
                    if !scoresBuildingDismissed {
                        DataPendingNote(
                            title: "Live now. Your scores are building.",
                            message: "Your live heart rate is working from the strap, and charge, effort and rest build from it over your next few nights of wear, sharpening as it learns your baseline. Want your full history instantly? Import your WHOOP export in Data Sources and it backfills in about a minute."
                        )
                        // A small × dismisses the card INTO the Updates inbox (restorable from there).
                        .overlay(alignment: .topTrailing) {
                            todayCardDismissButton {
                                dismissTodayCard(
                                    id: "scoresBuilding",
                                    title: "Live now. Your scores are building.",
                                    message: "Charge, Effort and Rest build over your next few nights of wear."
                                )
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
                // Design Reset: the "New here?" first-run card is off the dashboard for the clean WHOOP
                // look. The scoring guide stays reachable from the i on each score and in Settings.
                // The hero rings sit over a WHISPER of time-of-day atmosphere (dawn/day/dusk/night) — the
                // backdrop is confined to the ring region via `.background`, so it lifts the identity rings
                // without tinting the rest of the dashboard. The day-cycle scene wash caps at ~0.42 opacity
                // and fades top-down with a bottom dark scrim, no glow, so the white ring numbers + labels
                // stay crisp and high-contrast.
                #if os(iOS)
                // Pull the rings up under the compact top bar — the full section gap left too much air
                // above them now the big "Today's Synthesis" header is gone. The hero now sits over the
                // day-cycle SCENE wash (picked by the local hour), which fades top-down behind the rings;
                // the scene IS the atmosphere here, replacing the procedural time-of-day backdrop. It caps
                // at ~0.42 opacity with a bottom dark scrim so the white ring numbers + labels stay crisp.
                heroSection
                    .padding(.vertical, NoopMetrics.space4)
                    .frame(maxWidth: .infinity)
                    // The dark hero CARD floats over the vivid day-scene so the rings + white numbers stay
                    // crisp — the card does the contrast work, not a muted scene (Aaron 2026-06-23).
                    .background(
                        RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                            .fill(StrandPalette.surfaceBase.opacity(0.72))
                    )
                    .staggeredAppear(index: 0)
                #else
                heroSection
                    .padding(.vertical, NoopMetrics.space4)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                            .fill(StrandPalette.surfaceBase.opacity(0.72))
                    )
                    .staggeredAppear(index: 0)
                #endif
                heartRateTrendSection.staggeredAppear(index: 1)
                // Design Reset: rings -> Heart rate -> Your cards (the flat mockup order); the greeting +
                // Synthesis read-out + vitals now sit below the pinned cards instead of crowding the hero.
                yourCardsSection.staggeredAppear(index: 2)
                synthesisSection.staggeredAppear(index: 3)
                readinessSection.staggeredAppear(index: 4)
                metricsSection.staggeredAppear(index: 5)
                workoutsSection.staggeredAppear(index: 6)
                // Opt-in "looks like a workout?" suggestion (default OFF). Renders only when the
                // Settings toggle is on AND the detector finds a recent unsaved, un-dismissed window.
                AutoWorkoutCard()
                // Honest, dismissible 12-hourly donation ask — a card in the flow, never a modal.
                DonationNudgeCard()
                #if os(iOS)
                // iOS entry point to Support (donate + contact). macOS opens the same sheet from the
                // toolbar heart, but a primary tab on iPhone has no nav bar to host a `.toolbar` item,
                // so the affordance lives in-content here and presents SupportView as an auto-sized sheet.
                supportRow
                #endif
                sourcesSection
            }
        }
        // Reload when the data refreshes OR the selected day changes — the HR trend and Rest score are
        // day-scoped, so navigating must re-fetch them for the newly selected window.
        .task(id: TodayLoadKey(seq: repo.refreshSeq, offset: selectedDayOffset)) { await loadAll() }
        // Persist the freshly-built derivations so subsequent (1 Hz) renders with the same
        // inputs hit the cache instead of recomputing. Writing @State during `body` is not
        // allowed, so commit it after layout — the memoized accessors already return the
        // correct value for the change frame, so there is no flash and no missed update.
        // macOS-13-safe single-param onChange.
        .onChangeCompat(of: todayInputKey) { newKey in
            derived = buildDerived()
            derivedKey = newKey
        }
        .onAppear {
            if derivedKey != todayInputKey {
                derived = buildDerived()
                derivedKey = todayInputKey
            }
        }
        #if os(macOS)
        // macOS hosts the Support affordance in the window toolbar (RootView's NavigationSplitView
        // supplies the toolbar) and presents it as the fixed-width SupportModalOverlay panel. On iOS
        // this path is unavailable (no nav bar on a primary tab) and the 560pt panel would overflow
        // iPhone, so the in-content `supportRow` + auto-sized `.sheet` below take over instead.
        .toolbar {
            // Support heart on the LEADING (left) edge of the window toolbar.
            ToolbarItem(placement: .navigation) {
                Button { showingSupport = true } label: {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(StrandPalette.metricRose)
                        .attentionWiggle(period: 4)
                }
                .help("Support NOOP — donate or get in touch")
                .accessibilityLabel("Support NOOP — donate or get in touch")
            }
            // The Updates "ringer" on the TRAILING (top-right) edge, separated from the heart (iOS hosts
            // it in the compact top bar instead).
            ToolbarItem(placement: .primaryAction) {
                updateBell.help("Updates")
            }
        }
        .overlay {
            if showingSupport {
                SupportModalOverlay(isPresented: $showingSupport)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showingSupport)
        #else
        // iOS: present Support as an auto-sized sheet (sizes to the device, unlike the 560pt overlay).
        .sheet(isPresented: $showingSupport) { SupportView() }
        // Profile/settings from the top-bar button.
        .sheet(isPresented: $showSettings) { settingsSheet }
        #endif
        // The scoring guide, opened at a specific score from its ⓘ.
        .sheet(item: $guideSection) { section in
            ScoringGuideView(initialSection: section, onClose: { guideSection = nil })
        }
        // The scoring guide opened at the top (the first-run card's primary action).
        .sheet(isPresented: $showGuideTop) {
            ScoringGuideView(onClose: { showGuideTop = false })
        }
        // The Updates inbox (the header bell). Both platforms.
        .sheet(isPresented: $showUpdatesInbox) {
            UpdatesInboxView(onClose: { showUpdatesInbox = false })
        }
        // H6 — the steps-calibration sheet, opened from an estimated Steps tile (the same sheet Settings
        // hosts). Presented from Today so a WHOOP 4.0 user can calibrate from where the "est." caption shows.
        .sheet(isPresented: $showStepsCalibration) {
            StepsCalibrationSheet(repo: repo, onClose: { showStepsCalibration = false })
        }
        // Honour a "Restore to Today" tap from the inbox: flip the matching dismissed flag back so the
        // card reappears (the inbox also clears the @AppStorage key directly, but this covers an
        // already-mounted Today). Cleared once handled.
        .onChangeCompat(of: updateStore.restoreRequest) { payload in
            guard let payload else { return }
            withAnimation(StrandMotion.interactive) { restoreTodayCard(payload) }
            updateStore.restoreRequest = nil
        }
    }

    /// Flip a Today info-card's dismissed flag back to false so it reappears (driven by the inbox's
    /// "Restore to Today"). Keyed on the card id stored in the update's `restorePayload`.
    private func restoreTodayCard(_ cardID: String) {
        switch cardID {
        case "scoresBuilding": scoresBuildingDismissed = false
        case "newHere":        newHereDismissed = false
        default:               break
        }
    }

    /// Dismiss a Today info-card INTO the inbox: set its @AppStorage flag (so it stays gone) and post a
    /// `.dismissedCard` update carrying the card id so it can be restored.
    private func dismissTodayCard(id: String, title: String, message: String) {
        StrandHaptic.selection.play()
        switch id {
        case "scoresBuilding": scoresBuildingDismissed = true
        case "newHere":        newHereDismissed = true
        default:               break
        }
        updateStore.post(UpdateItem(
            kind: .dismissedCard,
            title: title,
            message: message,
            restorePayload: id
        ))
    }

    /// A small top-trailing × for a Today info-card that has no built-in dismiss control (the shared
    /// `DataPendingNote`). Matches the "New here?" card's × styling.
    private func todayCardDismissButton(_ action: @escaping () -> Void) -> some View {
        Button { withAnimation(StrandMotion.interactive) { action() } } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss to Updates")
    }

    // MARK: First-run scoring-guide card (one-time, dismissible)

    /// "New here?" — a single, dismissible card that points first-time users at the guide. Tapping the
    /// card opens the guide; the ✕ closes it. Either action sets `scoringGuideCardSeen`, so it shows
    /// once and never again. Mirrors the DonationNudgeCard's in-flow, never-modal pattern.
    private var scoringGuideFirstRunCard: some View {
        NoopCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18))
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("New here?")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("See how Charge, Effort and Rest are calculated — and how they differ from WHOOP.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        scoringGuideCardSeen = true
                        showGuideTop = true
                    } label: {
                        Label("How your scores work", systemImage: "arrow.right")
                            .font(StrandFont.subhead)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
                Button {
                    // Dismiss INTO the Updates inbox (restorable), rather than permanently hiding.
                    withAnimation(StrandMotion.interactive) {
                        dismissTodayCard(
                            id: "newHere",
                            title: "New here?",
                            message: "How Charge, Effort and Rest are calculated — and how they differ from WHOOP."
                        )
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            // The whole card is tappable as the primary action; the ✕ stops the tap from also firing.
            .contentShape(Rectangle())
            .onTapGesture {
                #if os(iOS)
                StrandHaptic.selection.play()
                #endif
                scoringGuideCardSeen = true
                showGuideTop = true
            }
        }
        // Press-down feedback for the tappable card surface.
        .strandPressable()
    }

    #if os(iOS)
    // MARK: Support entry point (iOS) — the in-content stand-in for the macOS toolbar heart.

    /// An in-flow card that opens the Support sheet (donate + contact). The whole card is the tap
    /// target; reuses the heart.fill + metricRose styling and the accessibility copy of the macOS
    /// toolbar button so both platforms read identically. iOS-only — macOS keeps the toolbar item.
    private var supportRow: some View {
        Button {
            StrandHaptic.selection.play()
            showingSupport = true
        } label: {
            NoopCard {
                HStack(spacing: 14) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(StrandPalette.metricRose)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Support NOOP")
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Donate or get in touch — totally optional.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
        }
        // Press-down feedback for the full-card button surface.
        .buttonStyle(StrandPressableButtonStyle())
        .accessibilityLabel("Support NOOP — donate or get in touch")
    }
    #endif

    // MARK: Readiness — on-device training-readiness synthesis (HRV / resting-HR / load).

    @ViewBuilder
    private var readinessSection: some View {
        let r = readiness
        if r.level != .insufficient {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                // When Readiness is anchored on the carried last-scored day (#543), the overline stamps
                // its date so the prior read isn't passed off as today's; otherwise the usual prompt.
                SectionHeader("Readiness",
                              overline: lastScoredRecoveryDay.map { "\(carriedCaption($0))" } ?? "Should you push today?")
                NoopCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            Circle().fill(readinessColor(r.level)).frame(width: 10, height: 10)
                                .accessibilityHidden(true)
                            Text(r.headline).font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .accessibilityLabel("Readiness: \(levelWord(r.level)). \(r.headline)")
                            Spacer()
                            if let acwr = r.acwr {
                                Text("load \(String(format: "%.2f", acwr))")
                                    .font(StrandFont.captionNumber)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                    .help("Acute (7-day) vs chronic (28-day) training load. 0.8–1.3 is the sweet spot.")
                            }
                        }
                        Text(r.summary).font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !r.signals.isEmpty {
                            Divider().overlay(StrandPalette.hairline)
                            ForEach(r.signals, id: \.key) { s in
                                HStack(alignment: .top, spacing: 8) {
                                    // Glyph + colour (not colour alone) so the flag reads
                                    // for colour-blind users; hidden from VoiceOver since the
                                    // flag word is folded into the row's combined label below.
                                    Image(systemName: flagSymbol(s.flag))
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(flagColor(s.flag))
                                        .padding(.top, 4)
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(s.label).font(StrandFont.caption)
                                            .foregroundStyle(StrandPalette.textSecondary)
                                        if let evidence = s.evidence {
                                            Text(evidence).font(StrandFont.captionNumber)
                                                .foregroundStyle(StrandPalette.textTertiary)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.8)
                                        }
                                    }
                                        .frame(width: 104, alignment: .leading)
                                    Text(s.detail).font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("\(s.label), \(flagWord(s.flag)): \(s.detail)")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // Word + glyph equivalents so the colour-coded severity isn't carried by hue
    // alone — read by VoiceOver and visible to colour-blind users.
    private func levelWord(_ l: ReadinessEngine.Level) -> String {
        switch l {
        case .primed:       return "Primed"
        case .balanced:     return "Balanced"
        case .strained:     return "Strained"
        case .rundown:      return "Run down"
        case .insufficient: return "Not enough data"
        }
    }

    private func flagWord(_ f: ReadinessEngine.Flag) -> String {
        switch f {
        case .good:    return "Good"
        case .neutral: return "Neutral"
        case .watch:   return "Watch"
        case .bad:     return "Alert"
        }
    }

    /// Colour-independent glyph so severity isn't conveyed by hue alone.
    private func flagSymbol(_ f: ReadinessEngine.Flag) -> String {
        switch f {
        case .good:    return "checkmark.circle.fill"
        case .neutral: return "minus.circle.fill"
        case .watch:   return "exclamationmark.circle.fill"
        case .bad:     return "exclamationmark.triangle.fill"
        }
    }

    private func readinessColor(_ l: ReadinessEngine.Level) -> Color {
        switch l {
        case .primed:       return StrandPalette.accent
        case .balanced:     return StrandPalette.statusPositive
        case .strained:     return StrandPalette.statusWarning
        case .rundown:      return StrandPalette.metricRose
        case .insufficient: return StrandPalette.textTertiary
        }
    }

    private func flagColor(_ f: ReadinessEngine.Flag) -> Color {
        switch f {
        case .good:    return StrandPalette.accent
        case .neutral: return StrandPalette.textTertiary
        case .watch:   return StrandPalette.statusWarning
        case .bad:     return StrandPalette.metricRose
        }
    }

    // MARK: (a) HERO — three ring scores (Charge / Effort / Rest) over a scenic backdrop,
    // then the green-tinted Synthesis coaching card. Bevel layout.

    @ViewBuilder
    private var heroSection: some View {
        let d = displayDay
        let score = d?.recovery
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // Recording status now lives as a colour-coded light in the header icon row, not a full-width
            // banner sandwiched above the rings. The three clean rings lead the screen directly.
            scoreHeroRow(d: d, score: score)

            // Component 2 — when Charge has no real today value, an explained state with its detail +
            // next step replaces a bare blank, sitting directly under the rings. The CALIBRATING case is
            // already richly explained by the data-confidence pill + calibration Synthesis card + the ring
            // overlay below, so the note shows for the two states the existing UI doesn't spell out a next
            // step for — "Last night · <date>" (carry-over) and "Needs the strap" — keeping the hero from
            // saying "calibrating" twice in two phrasings. `.scored` renders nothing (the ring has the
            // value). TODAY-only: the "No data for today" copy would be wrong on a navigated past day, and
            // a past day with no score is missing data the user can't act on now, so it keeps a bare ring.
            if selectedDayOffset == 0 && !chargeScoreState.isCalibrating {
                explainedScoreNote(chargeScoreState)
            }

        }
    }

    /// Design Reset: the greeting + gold Synthesis read-out + vitals, lifted OUT of the hero so Today
    /// reads rings -> Heart rate -> Your cards (the flat mockup order). Same content + behaviour, it just
    /// sits below the HR card and the pinned cards now instead of crowding directly under the rings.
    @ViewBuilder
    private var synthesisSection: some View {
        let d = displayDay
        let score = d?.recovery
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(greetingWord)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 8)
                recoveryStatePill(score: score)
                    .layoutPriority(1)
            }
            .accessibilityElement(children: .combine)

            #if DEBUG
            // DEBUG promo harness: override the Synthesis headline + body with the active frame's copy.
            if let f = DemoDayHarness.active {
                InsightCard(
                    category: "Synthesis",
                    status: "\(f.synthHeadline)",
                    detail: "\(f.synthBody)",
                    statusColor: StrandPalette.textPrimary,
                    tint: StrandPalette.chargeColor
                )
            } else {
                InsightCard(
                    category: "Synthesis",
                    status: calibrationStatus ?? "\(synthesisCardStatus(d, score: score))",
                    detail: calibrationDetail ?? "\(synthesisCardDetail(d, score: score))",
                    statusColor: StrandPalette.textPrimary,
                    tint: StrandPalette.chargeColor
                )
            }
            #else
            InsightCard(
                category: "Synthesis",
                status: calibrationStatus ?? "\(synthesisCardStatus(d, score: score))",
                detail: calibrationDetail ?? "\(synthesisCardDetail(d, score: score))",
                statusColor: StrandPalette.textPrimary,
                tint: StrandPalette.chargeColor
            )
            #endif

            if let note = effortZeroNote {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.effortColor)
                    Text(note)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 2)
                .accessibilityElement(children: .combine)
            }

            // HRV / Resting HR / Respiratory — the vitals that drive recovery.
            recoveryVitalsCard(d)
        }
    }

    // MARK: - Your cards (#582 / Design Reset)

    /// The user-customisable "Your cards" dashboard (WHOOP "My Dashboard"). Surfaces a persisted, reorderable
    /// selection of metric cards on the home screen as flat WHOOP metric rows — each opens its detail screen,
    /// the original three (Stress / Fitness age / Vitality) keep their destinations. A blue "CUSTOMISE" link on
    /// the header opens a local toggle/reorder sheet. TODAY only. A card with no value yet renders "—" rather
    /// than vanishing, so the section is stable; it's hidden only when the user has no cards selected at all.
    @ViewBuilder
    private var yourCardsSection: some View {
        if selectedDayOffset == 0 && !enabledDashboardCards.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                // Section header: the "Your cards" label + a right-aligned BLUE "CUSTOMISE" action link (the
                // WHOOP "My Dashboard" ✎ affordance). Opens a local sheet — no new nav destination.
                HStack(alignment: .firstTextBaseline) {
                    Text("Your cards").strandOverline()
                    Spacer(minLength: 8)
                    Button {
                        showingDashboardEditor = true
                    } label: {
                        Label("CUSTOMISE", systemImage: "slider.horizontal.3")
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                    .accessibilityLabel("Customise your cards")
                    .help("Choose which cards show and reorder them")
                }
                ForEach(enabledDashboardCards) { card in
                    dashboardCardRow(card)
                }
            }
            .sheet(isPresented: $showingDashboardEditor) {
                DashboardCardsEditorSheet(selectionRaw: $dashboardCardsRaw)
            }
        }
    }

    /// One "Your cards" dashboard row: resolves the card's CURRENT value from the values Today already loads
    /// (a card with no value yet shows "—"), then renders it as a WHOOP metric row that navigates to the
    /// card's detail screen. Branching keeps the destination type concrete (no AnyView) so navigation is
    /// exact and the original three cards reach the SAME screens as before.
    @ViewBuilder
    private func dashboardCardRow(_ card: DashboardCard) -> some View {
        let tint = dashboardTint(card)
        switch card {
        case .stress:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card)) { StressView() }
        case .fitnessAge:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card)) { HealthView() }
        case .vitality:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card)) { HealthView() }
        case .hrv, .restingHr, .respiratory, .bloodOxygen, .skinTemp:
            // The overnight vitals share the Health detail screen (the vital-signs surface).
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card)) { HealthView() }
        case .sleep:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card)) { SleepView() }
        case .steps:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card)) { HealthView() }
        case .calories:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card)) { HealthView() }
        case .hydration:
            pinnedCardRow(icon: card.icon, tint: tint, title: card.title, subtitle: card.subtitle,
                          value: dashboardValue(card)) { HydrationView() }
        }
    }

    /// A dashboard card's WHOOP-token tint (icon + accent). Score cards take their domain colour; vitals
    /// take their biometric hue; everything else takes the blue accent. No gold (WHOOP), tokens only.
    private func dashboardTint(_ card: DashboardCard) -> Color {
        switch card {
        case .stress:      return StrandPalette.effortColor
        case .fitnessAge:  return StrandPalette.chargeColor
        case .vitality:    return StrandPalette.restColor
        case .hrv:         return StrandPalette.metricPurple
        case .restingHr:   return StrandPalette.metricRose
        case .respiratory: return StrandPalette.accent
        case .bloodOxygen: return StrandPalette.metricCyan
        case .skinTemp:    return StrandPalette.metricAmber
        case .sleep:       return StrandPalette.restColor
        case .steps:       return StrandPalette.metricCyan
        case .calories:    return StrandPalette.metricAmber
        case .hydration:   return StrandPalette.metricCyan
        }
    }

    /// Resolve a dashboard card's CURRENT display value from the values Today already loads, with its unit
    /// suffix appended. Returns "—" when the value isn't available yet — never a fabricated number. Reuses
    /// the same reads the Key-Metrics tiles use (displayDay vitals, restScore / sleep duration, the pinned
    /// Stress / Fitness age / Vitality, steps, calories).
    private func dashboardValue(_ card: DashboardCard) -> String {
        let d = displayDay
        func withUnit(_ s: String) -> String {
            guard s != "—" else { return "—" }
            return card.unit.isEmpty ? s : "\(s) \(card.unit)"
        }
        switch card {
        case .hrv:
            #if DEBUG
            if let f = DemoDayHarness.active { return withUnit("\(f.hrvMs)") }
            #endif
            return withUnit(d?.avgHrv.map { "\(Int($0.rounded()))" } ?? "—")
        case .restingHr:
            #if DEBUG
            if let f = DemoDayHarness.active { return withUnit("\(f.rhrBpm)") }
            #endif
            return withUnit(d?.restingHr.map { "\($0)" } ?? "—")
        case .respiratory:
            return withUnit(d?.respRateBpm.map { String(format: "%.1f", $0) }
                            ?? sparks["resp_rate"]?.last.map { String(format: "%.1f", $0) } ?? "—")
        case .bloodOxygen:
            return d?.spo2Pct.map { String(format: "%.0f%%", $0) } ?? "—"
        case .skinTemp:
            // Stored as a deviation from baseline (°C); show it signed so +/- reads honestly.
            return d?.skinTempDevC.map { String(format: "%+.1f°", $0) } ?? "—"
        case .sleep:
            return sleepValue(d)
        case .steps:
            let appleStepsForDay = appleDays.last(where: { $0.day == selectedDayKey })?.steps
                ?? (selectedDayOffset == 0 ? appleDays.last?.steps : nil)
            let real = (d?.steps).map { intString(Double($0)) }
                ?? appleStepsForDay.map { intString(Double($0)) }
                ?? sparks["steps"]?.last.map { intString($0) }
            let est = stepsEstByDay[selectedDayKey].map { intString(Double($0)) }
            return real ?? est ?? "—"
        case .calories:
            return withUnit(caloriesValue(appleDays.last))
        case .stress:
            #if DEBUG
            // DEBUG promo harness: pin the Stress card (0–3) to the active frame's value. No-op otherwise.
            if let f = DemoDayHarness.active { return "\(f.stress0to3)" }
            #endif
            return stressToday.map { "\(Int($0.rounded()))" } ?? "—"
        case .fitnessAge:
            return withUnit(fitnessAgeToday.map { "\(Int($0.rounded()))" } ?? "—")
        case .vitality:
            return vitalityToday.map { "\(Int($0.rounded()))" } ?? "—"
        case .hydration:
            // "<total> / <goal> L" in litres to 1 dp (the string bakes in the " L" itself). Always shows a
            // value (a fresh day reads "0.0 / 3.2 L"); the goal is always derivable from the profile.
            guard let goal = hydrationGoalML else { return "—" }
            return HydrationGoal.cardValueString(totalML: hydrationTotalML ?? 0, goalML: goal)
        }
    }

    /// One WHOOP "My Dashboard" metric row: a thin-line tinted icon, an UPPERCASE tracked label over a grey
    /// baseline caption, the big white value, and a chevron — the whole row navigates to `destination`. Flat
    /// WHOOP styling (FrostedCardSurface, no glow), tokens only.
    @ViewBuilder
    private func pinnedCardRow<Dest: View>(icon: String, tint: Color, title: String, subtitle: String,
                                           value: String, @ViewBuilder destination: @escaping () -> Dest) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(value).font(StrandFont.rounded(18, weight: .semibold)).foregroundStyle(StrandPalette.textPrimary)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FrostedCardSurface(cornerRadius: NoopMetrics.cardRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Component 2 — explained score note (calibrating / carried / needs-strap)

    /// A small explained-state note for a score whose value isn't a real today number: the state title
    /// (Calibrating / Last night · <date> / Needs the strap), its detail line, and the implicit next step
    /// the detail copy carries. Renders NOTHING for `.scored` (the ring/tile shows the number itself), so
    /// a score never shows a bare blank without a state, a reason and a next step. (spec 2026-06-20)
    @ViewBuilder
    private func explainedScoreNote(_ state: MetricTileState) -> some View {
        if let title = state.title, let detail = state.detail {
            let symbol: String = {
                switch state {
                case .calibrating:      return "gauge.with.dots.needle.bottom.50percent"
                case .carriedLastNight: return "clock.arrow.circlepath"
                case .needsStrap:       return "exclamationmark.circle"
                case .scored:           return "info.circle"
                }
            }()
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: symbol)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text(detail)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            // Inset to the card's content margin so the "Last night · <date>" clock-icon footnote sits a
            // proper distance from the hero's left edge rather than hugging it (it previously used a bare
            // 2pt). Matches NoopMetrics.cardPadding, the standard card content inset.
            .padding(.horizontal, NoopMetrics.cardPadding)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.accessibilityText ?? "")
        }
    }

    // MARK: Screen-4 — data-confidence pill, vitals metric card, HRV-baseline insight

    /// The SOLID / CALIBRATING data-confidence chip beside the hero title (README screen 4).
    /// SOLID (gold) once today carries a settled recovery score; CALIBRATING (slate) while the
    /// HRV baseline is still forming (it shows the running "N of 4" count); for a navigated past
    /// day with no score it falls back to CALIBRATING without a count. Drives off the SAME
    /// recovery / calibration bindings the rings use — presentation only.
    @ViewBuilder
    private func recoveryStatePill(score: Double?) -> some View {
        #if DEBUG
        // DEBUG promo harness: pin the readiness badge to the active frame's word. "Solid" reads green
        // (.solid); anything else (e.g. "Moderate") uses the slate state so it's visibly distinct without
        // inventing a new hue. No-op when no `--demo-hour` frame is active.
        if let f = DemoDayHarness.active {
            ScoreStatePill(f.readiness == "Solid" ? .solid : .calibrating, text: "\(f.readiness)")
        } else if score != nil {
            ScoreStatePill(.solid)
        } else if let n = recoveryCalibration {
            ScoreStatePill(.calibrating, text: "Calibrating, \(n) of \(Baselines.minNightsSeed)")
        } else {
            ScoreStatePill(.calibrating)
        }
        #else
        if score != nil {
            ScoreStatePill(.solid)
        } else if let n = recoveryCalibration {
            ScoreStatePill(.calibrating, text: "Calibrating, \(n) of \(Baselines.minNightsSeed)")
        } else {
            ScoreStatePill(.calibrating)
        }
        #endif
    }

    /// Screen-4 "metric card": HRV / Resting HR / Respiratory as a stack of labelled metric rows
    /// inside one frosted card — the three vitals that feed recovery. HRV reads teal (its biometric
    /// hue), Resting HR burnt-orange, Respiratory gold. Values come straight from the selected day's
    /// `DailyMetric` (respiratory falls back to the loaded sparkline tail, as the tile does).
    ///
    /// When today isn't scored yet (the post-rollover state, #543), the recovery side carries over the
    /// last scored day's vitals — labelled with ONE card-level "Last night · <date>" footnote so the
    /// whole recovery side reads consistently with the carried Charge ring, never blanking to "—" while
    /// live HR ticks. Each row still falls through to "—" for a metric the carried row genuinely lacks
    /// (e.g. a BLE-only night with no SpO₂), and today's own value always wins the instant it lands.
    @ViewBuilder
    private func recoveryVitalsCard(_ d: DailyMetric?) -> some View {
        // The row the vitals read from: today's own row when it carries recovery, else the carried-over
        // prior scored day (only when we're carrying — `lastScoredRecoveryDay` is gated to that case).
        let carried = lastScoredRecoveryDay
        let vd = carried ?? d
        NoopCard(tint: StrandPalette.chargeColor) {
            VStack(spacing: 0) {
                // DEBUG promo harness: pin HRV / Resting HR to the active frame's values. No-op otherwise.
                #if DEBUG
                let demoHrv = DemoDayHarness.active.map { "\($0.hrvMs)" }
                let demoRhr = DemoDayHarness.active.map { "\($0.rhrBpm)" }
                #else
                let demoHrv: String? = nil
                let demoRhr: String? = nil
                #endif
                metricRow(icon: "waveform.path.ecg", label: "HRV",
                          value: demoHrv ?? (vd?.avgHrv.map { "\(Int($0.rounded()))" } ?? "—"), unit: "ms",
                          tint: StrandPalette.metricCyan)
                Divider().overlay(StrandPalette.hairline)
                metricRow(icon: "heart.fill", label: "Resting HR",
                          value: demoRhr ?? (vd?.restingHr.map { "\($0)" } ?? "—"), unit: "bpm",
                          tint: StrandPalette.metricRose)
                Divider().overlay(StrandPalette.hairline)
                metricRow(icon: "lungs.fill", label: "Respiratory",
                          // Carried day uses its OWN respiratory; a non-carrying today keeps the
                          // sparkline-tail fallback the tile uses so a sparse-but-recent value still reads.
                          value: vd?.respRateBpm.map { String(format: "%.1f", $0) }
                              ?? (carried == nil ? latestString("resp_rate", decimals: 1) : "—"),
                          unit: "rpm",
                          tint: StrandPalette.accent)
                // ONE provenance footnote when these are carried prior-day vitals (not today's), matching
                // the carried Charge ring's "Last night · <date>" stamp — so the whole recovery side is
                // consistently labelled as a prior read rather than silently passing yesterday off as today.
                if let prior = carried {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                        Text(carriedCaption(prior))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 10)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("These vitals are from \(carriedCaption(prior))")
                }
            }
        }
    }

    /// One README "metric row": a metric-hue line icon, a secondary label, and a right-aligned bold
    /// value with a small unit. Rows are divided by a hairline. Shared by the Today vitals card.
    @ViewBuilder
    private func metricRow(icon: String, label: String, value: String, unit: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(label)
                .font(StrandFont.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(StrandFont.number(24))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(unit)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value) \(unit)")
    }

    // MARK: Synthesis card — today's read, or the carried last-scored read (#543)

    /// The Synthesis status word, carrying the LAST scored day's read when today isn't scored yet (the
    /// post-rollover state) — so the card mirrors the carried Charge ring instead of reading "No Data".
    /// When today IS scored (or there's nothing to carry) it's today's own `hrvInsightStatus`.
    private func synthesisCardStatus(_ d: DailyMetric?, score: Double?) -> String {
        if let prior = lastScoredRecoveryDay {
            return hrvInsightStatus(prior, score: prior.recovery)
        }
        return hrvInsightStatus(d, score: score)
    }

    /// The Synthesis detail line. When carrying a prior scored day it summarises THAT day and appends a
    /// "Last night · <date>" provenance, so the prior read is never silently passed off as today's.
    private func synthesisCardDetail(_ d: DailyMetric?, score: Double?) -> String {
        if let prior = lastScoredRecoveryDay {
            return hrvInsightDetail(prior, score: prior.recovery) + " " + carriedCaption(prior) + "."
        }
        return hrvInsightDetail(d, score: score)
    }

    /// The Synthesis status colour — keyed on the carried prior recovery when carrying, else today's.
    private func synthesisCardColor(score: Double?) -> Color {
        if let rec = lastScoredRecoveryDay?.recovery {
            return StrandPalette.recoveryColor(rec)
        }
        return score.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textTertiary
    }

    /// Screen-4 insight headline — when the HRV baseline is established, the gold "primed" read
    /// keyed on how far today's HRV sits above/below the learned baseline ("HRV 12% over baseline");
    /// otherwise the recovery-state word. Purely a re-presentation of the existing recovery + HRV
    /// bindings (no new computation beyond the baseline mean already available on `repo.days`).
    private func hrvInsightStatus(_ d: DailyMetric?, score: Double?) -> String {
        guard let pct = hrvBaselineDeltaPct(d) else { return synthesisWord(score) }
        let sign = pct >= 0 ? "over" : "under"
        return "HRV \(abs(pct))% \(sign) baseline"
    }

    /// The supporting line for the screen-4 insight: the primed/steady read tied to the HRV delta,
    /// folding in the recovery-state synthesis so the card still reads as a coaching summary.
    private func hrvInsightDetail(_ d: DailyMetric?, score: Double?) -> String {
        guard let pct = hrvBaselineDeltaPct(d) else { return synthesisDetail(d) }
        let lead: String
        if pct >= 8 { lead = "Your nervous system is well-recovered — you're primed to push" }
        else if pct >= -8 { lead = "You're in balance with your baseline — moderate strain is well-judged" }
        else { lead = "HRV is below your baseline — ease into the day" }
        return lead + ". " + synthesisDetail(d)
    }

    /// Today's HRV as a percentage above/below the learned baseline (mean of prior nights' avgHrv),
    /// rounded to a whole percent. nil until there are enough banked HRV nights to form a stable
    /// baseline (mirrors the recovery seed gate) — the insight then falls back to the state word.
    private func hrvBaselineDeltaPct(_ d: DailyMetric?) -> Int? {
        guard let today = d?.avgHrv, today > 0 else { return nil }
        // Baseline = mean of the prior nights' HRV, excluding the row being read so "vs baseline"
        // compares it against the rest of history. Excludes the row's OWN day (not always the selected
        // day) so a carried prior-day synthesis (#543) isn't compared against a baseline that includes
        // itself. Needs the same seed depth recovery uses to be honest.
        let excludeDay = d?.day ?? selectedDayKey
        let prior = repo.days
            .filter { $0.day != excludeDay }
            .compactMap(\.avgHrv)
            .filter { $0 > 0 }
        return Self.hrvBaselineDeltaPct(today: today, priorHrvs: prior)
    }

    /// Pure core of the HRV-vs-baseline delta: today's HRV against the mean of the prior nights' HRV,
    /// rounded to a whole percent. nil until there are enough banked HRV nights to form a stable
    /// baseline (mirrors the recovery seed gate) — the insight then falls back to the state word.
    ///
    /// STOPGAP (#696): NOOP mixes HRV measurement methods on the shared `avgHrv` field —
    /// strap/WHOOP-CSV HRV is RMSSD (~20-100 ms) while Apple-Health-imported HRV is SDNN
    /// (~100-200 ms). With no method awareness, an SDNN reading (e.g. an Oura ring's 176 ms)
    /// compared against an RMSSD baseline (~57 ms) yields a physiologically-impossible delta
    /// (+209%) and renders the alarming "210% over baseline" headline. Genuine night-to-night
    /// HRV variation essentially never exceeds ~±80-100%, so a magnitude beyond that is almost
    /// always a units/method artifact rather than a real swing. We suppress the misleading
    /// percentage comparison (return nil → callers fall back to the qualitative recovery-state
    /// word) when the delta is implausibly large. The raw HRV tile value stays honest; only the
    /// "X% over baseline" comparison is hidden. Proper fix = tag HRV provenance/method per row
    /// and isolate baselines (separate follow-up).
    static func hrvBaselineDeltaPct(today: Double, priorHrvs prior: [Double]) -> Int? {
        guard today > 0 else { return nil }
        guard prior.count >= Baselines.minNightsSeed else { return nil }
        let baseline = prior.reduce(0, +) / Double(prior.count)
        guard baseline > 0 else { return nil }
        let pct = ((today - baseline) / baseline * 100).rounded()
        // Stopgap method-mismatch guard (#696): a real night-to-night HRV move never doubles or halves
        // the value, so a reading outside [0.5x, 2x] of the baseline is almost always a units/method
        // artifact (SDNN reads ~2-3x RMSSD) rather than a genuine swing. Drop the comparison in that case
        // so the alarming "X% over/under baseline" headline never renders (the insight falls back to the
        // qualitative recovery word). Gated on the RATIO, not abs(pct): the percentage is bounded at -100%
        // on the low side but unbounded high, so a symmetric abs() threshold can't catch a near-zero
        // reading. Proper fix tags HRV provenance/method per row and isolates baselines (follow-up).
        guard today <= 2.0 * baseline, today >= 0.5 * baseline else { return nil }
        return Int(pct)
    }

    /// The three score rings over a scenic hero background — WHOOP-style, with the Charge (recovery)
    /// ring centred and enlarged as the hero and smaller Rest / Effort rings flanking it. Each ring
    /// floats cleanly on the scenic field (no per-ring card); a tappable label + chevron sits beneath
    /// each and opens that score's section in the scoring guide. Rings are sized off the available
    /// width so the trio never crushes on a narrow phone nor bloats on iPad.
    @ViewBuilder
    private func scoreHeroRow(d: DailyMetric?, score: Double?) -> some View {
        GeometryReader { geo in
            // Design Reset: three EQUAL clean rings (no glow, faint track) in Charge / Effort / Rest order
            // with generous spacing — mirrors the flat mockup. Sized off width so they stay equal on any phone.
            let ring = min(98, max(82, (geo.size.width - 56) / 3.4))
            HStack(alignment: .top, spacing: 22) {
                // Component 4 — Charge/Rest badge their real per-day merge winner; Effort has no badge.
                heroRingColumn(section: .charge, domain: .charge, provenanceKey: "recovery") { chargeRing(score: score, d: d, diameter: ring) }
                heroRingColumn(section: .effort, domain: .effort) { effortRing(d: d, diameter: ring) }
                heroRingColumn(section: .rest, domain: .rest, provenanceKey: "sleep_performance") { restRing(diameter: ring) }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
        }
        .frame(height: 150)
    }

    /// One hero ring column: the ring centred, with a tappable UPPERCASE domain label + chevron
    /// beneath it (the WHOOP affordance) that opens the matching scoring-guide section. The ring is
    /// intrinsically diameter×diameter, so the column just centres it and stretches to an equal share
    /// of the row width.
    @ViewBuilder
    private func heroRingColumn<RingBody: View>(
        section: ScoreSection, domain: DomainTheme, provenanceKey: String? = nil,
        @ViewBuilder ring: () -> RingBody
    ) -> some View {
        VStack(spacing: 8) {
            ring()
            Button { guideSection = section } label: {
                HStack(spacing: 3) {
                    Text(domain.rawValue.uppercased())
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .opacity(0.6)
                }
                .foregroundStyle(StrandPalette.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("How \(domain.rawValue.capitalized) is calculated")
            // Component 4 — the real per-day source under the ring (only when this score has a value for
            // the day AND we resolved its winner; a calibrating / empty ring shows no provenance badge).
            if let key = provenanceKey, ringHasValue(key), let label = provenanceLabel(key) {
                SourceBadge("\(label)", tint: provenanceTint(key))
                    .accessibilityLabel("Source: \(label)")
            }
        }
    }

    /// Whether the score behind a provenance key has a real value for the selected day — gates the ring's
    /// provenance badge so it only appears alongside an actual number (Charge = recovery, Rest = restScore).
    private func ringHasValue(_ metricKey: String) -> Bool {
        switch metricKey {
        case "recovery":          return displayDay?.recovery != nil
        case "sleep_performance": return restScore != nil
        default:                  return false
        }
    }

    /// Charge (recovery 0–100) hero ring — the premium animated GlowRing, with a calibrating / no-data
    /// track when nil.
    @ViewBuilder
    private func chargeRing(score: Double?, d: DailyMetric?, diameter: CGFloat) -> some View {
        if let s = score {
            GlowRing(fraction: s / 100, value: s, format: { "\(Int($0.rounded()))" },
                     color: StrandPalette.chargeColor, diameter: diameter, lineWidth: diameter * 0.10)
        } else {
            emptyHeroRing(diameter: diameter) { ringEmptyOverlay(d: d, diameter: diameter) }
        }
    }

    /// Effort (strain) hero ring, honouring the 0–100 / WHOOP-0–21 toggle (#313). Integer on the 0–100
    /// axis so it matches Charge/Rest; one decimal on the WHOOP 0–21 axis where the tenth matters.
    @ViewBuilder
    private func effortRing(d: DailyMetric?, diameter: CGFloat) -> some View {
        if effortStrain(d) != nil, let gv = effortGaugeValue(d) {
            GlowRing(fraction: gv / effortGaugeMax, value: gv,
                     format: { effortScale == .whoop ? String(format: "%.1f", $0) : "\(Int($0.rounded()))" },
                     color: StrandPalette.effortColor, diameter: diameter, lineWidth: diameter * 0.10)
        } else {
            emptyHeroRing(diameter: diameter) { ringNoData(diameter: diameter) }
        }
    }

    /// Rest (sleep composite 0–100) hero ring.
    @ViewBuilder
    private func restRing(diameter: CGFloat) -> some View {
        if let s = restScore {
            GlowRing(fraction: s / 100, value: s, format: { "\(Int($0.rounded()))" },
                     color: StrandPalette.restColor, diameter: diameter, lineWidth: diameter * 0.10)
        } else {
            emptyHeroRing(diameter: diameter) { ringNoData(diameter: diameter) }
        }
    }

    /// The faint full-circle track with a centred overlay, shown when a score is still calibrating/absent.
    @ViewBuilder
    private func emptyHeroRing<Overlay: View>(diameter: CGFloat, @ViewBuilder overlay: () -> Overlay) -> some View {
        ZStack {
            Circle().stroke(StrandPalette.textPrimary.opacity(0.10),
                            style: StrokeStyle(lineWidth: diameter * 0.10, lineCap: .round))
            overlay()
        }
        .frame(width: diameter, height: diameter)
    }

    /// The effective Effort strain (NOOP 0–100 axis) the gauge shows. For TODAY this prefers the live
    /// in-progress value computed over the day's HR (midnight→now) in `loadAll`, so the gauge reflects
    /// the accumulating day rather than the last persisted daily row — which only refreshes when the
    /// heavy daily pass runs, so early in the day the stored row is yesterday's Effort or a stale 0.0
    /// (#402). Falls back to the stored `strain` when there isn't yet enough of today's HR to score
    /// (StrainScorer.minReadings). Navigated past days always use the stored row.
    private func effortStrain(_ d: DailyMetric?) -> Double? {
        #if DEBUG
        // DEBUG promo harness: pin Effort (NOOP 0–100 axis) to the active frame's value. This single
        // point feeds the hero ring AND every Effort read-out, so they stay consistent. No-op when no
        // `--demo-hour` frame is active. Charge/Rest are intentionally left at their seeded values.
        if let f = DemoDayHarness.active { return f.effort }
        #endif
        if selectedDayOffset == 0, let live = liveTodayStrain {
            // Effort accrues over a day and must never visibly DROP. The in-progress recompute (raw day
            // HR, midnight→now) can UNDER-read when today's HR is sparse or a logged workout's load isn't
            // in the raw stream — e.g. a 5/MG user who trained this morning saw today's real 38.3 get
            // replaced by a live 0 (#489/#506). Floor at the day's already-earned Effort. `d` (displayDay)
            // for today is ALWAYS today's row or nil — never a prior day — so this can't resurrect a stale
            // day; it only stops the gauge dropping below what's already been counted today.
            if let stored = d?.strain { return Swift.max(live, stored) }
            return live
        }
        return d?.strain
    }

    /// When TODAY's Effort scores a genuine near-zero — there's enough HR to score, but it never
    /// crossed the cardiovascular "effort zone" (~50% of heart-rate reserve) — explain the 0 instead
    /// of leaving a bare number that reads as a fault (#482/#480). A low-HR day honestly earns ~0, the
    /// same as a WHOOP low-strain day; the 5/MG just hits it more often (sparser HR, lower daytime
    /// peaks). Only for today, only when the score is ~0 and a score exists (a no-data ring shows its
    /// own overlay, a past day isn't annotated).
    private var effortZeroNote: String? {
        guard selectedDayOffset == 0, let s = effortStrain(displayDay), s < 1.0 else { return nil }
        return "No cardio load yet — Effort builds once your heart rate climbs into your effort zone (around 50% of your heart-rate reserve). A calm day honestly reads near zero."
    }

    /// Strain value to feed the Effort gauge, on the SELECTED display scale (#313). The effective
    /// `strain` is on NOOP's 0–100 Effort axis; `UnitFormatter.effortValue` converts it to the
    /// user's chosen scale (0–100 native, or ×21/100 down to WHOOP's 0–21) so the arc + number
    /// match the rest of the app's Effort read-outs. Pairs with `effortGaugeMax` for the "of N".
    private func effortGaugeValue(_ d: DailyMetric?) -> Double? {
        effortStrain(d).map { UnitFormatter.effortValue($0, scale: effortScale) }
    }

    /// The Effort gauge's scale maximum — 100 on NOOP's native axis, 21 on the WHOOP axis. Drives
    /// the arc fraction and the gauge's "of N" caption so both follow the toggle (#313).
    private var effortGaugeMax: Double { effortScale == .whoop ? 21 : 100 }

    /// Honest overlay shown over the Charge ring when today's recovery is nil: calibrating count, the
    /// last scored Charge carried over, or No data. After the logical-day rollover the new day has no
    /// recovery until tonight is scored; rather than a bare "No data" on the hero ring while live HR
    /// ticks (which reads as broken, #543), show the most recent scored Charge as a centred read-out
    /// clearly stamped "Last night · <date>". The ring TRACK stays empty (today genuinely isn't scored,
    /// so we never fill the GlowRing as if it were today's number) — the carried value sits inside it as
    /// a labelled prior reading, the way WHOOP keeps last recovery visible until the new one lands.
    @ViewBuilder
    private func ringEmptyOverlay(d: DailyMetric?, diameter: CGFloat) -> some View {
        VStack(spacing: 3) {
            if let n = recoveryCalibration {
                // "Calibrating" is a long word for the ring's interior — it reads as the centre label, with
                // the same lineLimit/scaleFactor guard so it never wraps, then its "N of 4" subtitle below.
                Text("Calibrating").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7).fixedSize()
                Text("\(n) of \(Baselines.minNightsSeed)").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            } else if let carried = lastScoredCharge {
                // Ring text consistency (#hero): the carried "49%" centre number renders in the SAME size +
                // weight as a filled ring's number (GlowRing.centerFont), so a carried Charge, a clean "93"
                // and a "No data" ring all share one centre-number style. Its "Last night" subtitle stays a
                // footnote, matching the calibrating subtitle.
                Text("\(Int(carried.value.rounded()))%")
                    .font(GlowRing.centerFont(diameter: diameter))
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.recoveryColor(carried.value))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text(carried.caption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                ringNoData(diameter: diameter)
            }
        }
    }

    @ViewBuilder
    private func ringNoData(diameter: CGFloat) -> some View {
        // "No data" reads as the centre label at the same weight family as the ring numbers. lineLimit +
        // fixedSize so a small flanking ring (Rest/Effort) never wraps it mid-word inside the ring's narrow
        // interior (#495/#549).
        Text("No data").font(StrandFont.headline).foregroundStyle(StrandPalette.textSecondary)
            .lineLimit(1).minimumScaleFactor(0.7).fixedSize()
    }

    // MARK: HEART RATE — today's continuous HR, off the strap's own ~1Hz history.

    /// A full-width 24-hour heart-rate trend, plotted from 5-minute bucket means of the strap's
    /// `hrSample` history (offloaded even while the app was closed, so the day reads continuously).
    /// Hidden until there are at least two buckets — a strap-only user with no wear today sees nothing
    /// rather than an empty axis. Mirrored on Android (TodayScreen.kt HeartRateTrendCard).
    @ViewBuilder
    private var heartRateTrendSection: some View {
        if hrPoints.count > 1 {
            let v = hrPoints.map(\.value)
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Heart Rate", overline: "\(selectedDayOverline)")
                ChartCard(
                    title: "Beats per minute",
                    subtitle: selectedDayOffset == 0 ? "5-minute average · since midnight" : "5-minute average · selected day",
                    trailing: v.last.map { "\(Int($0.rounded())) bpm" },
                    tint: StrandPalette.metricRose
                ) {
                    OverviewHRChart(
                        points: hrPoints,
                        sleep: sleepSpan,
                        workouts: workoutSpans,
                        recovery: recoveryMarker,
                        effort: effortMarker,
                        gradient: Gradient(colors: [StrandPalette.metricRose.opacity(0.55), StrandPalette.metricRose]),
                        valueRange: hrRange(v),
                        xRange: hrAxis,
                        height: NoopMetrics.chartHeight,
                        valueFormat: { "\(Int($0.rounded())) bpm" },
                        dateFormat: { Self.hrTimeFmt.string(from: $0) }
                    )
                } footer: {
                    ChartFooter([
                        ("Min", "\(Int((v.min() ?? 0).rounded()))"),
                        ("Avg", "\(Int((v.reduce(0, +) / Double(v.count)).rounded()))"),
                        ("Max", "\(Int((v.max() ?? 0).rounded()))"),
                    ])
                }
            }
        }
    }

    /// Padded HR axis range so the line never sits flush against an edge (mirrors MetricExplorer.valueRange).
    private func hrRange(_ v: [Double]) -> ClosedRange<Double> {
        guard let lo = v.min(), let hi = v.max() else { return 40...120 }
        if hi <= lo { return (lo - 5)...(hi + 5) }
        let span = hi - lo
        return (lo - span * 0.12)...(hi + span * 0.12)
    }

    // MARK: Overview HR markers (sleep band · workout glyphs · Charge / Effort)

    /// The HR chart's x-window, derived from the loaded points (used to scope workout glyphs).
    private var hrWindow: ClosedRange<Date>? {
        guard let lo = hrPoints.first?.date, let hi = hrPoints.last?.date, lo < hi else { return nil }
        return lo...hi
    }

    /// "H:MM" for a duration in seconds (e.g. a 6h06m night → "6:06").
    private func hoursMinutes(_ seconds: Int) -> String {
        let h = max(0, seconds) / 3600, m = (max(0, seconds) % 3600) / 60
        return "\(h):\(String(format: "%02d", m))"
    }

    /// Last night's sleep as a shaded band, labelled with its duration.
    private var sleepSpan: OverviewHRChart.SleepSpan? {
        guard let s = sleepToday else { return nil }
        // Use the EFFECTIVE onset so a hand-corrected bedtime shows the same band/duration here as on
        // the Sleep tab (not the detected onset). (#318)
        return .init(
            start: Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs)),
            end: Date(timeIntervalSince1970: TimeInterval(s.endTs)),
            label: hoursMinutes(s.endTs - s.effectiveStartTs)
        )
    }

    /// Each workout overlapping the HR window, as a sport glyph anchored at its HR peak.
    private var workoutSpans: [OverviewHRChart.WorkoutSpan] {
        guard let win = hrWindow else { return [] }
        return workouts.compactMap { w in
            let start = Date(timeIntervalSince1970: TimeInterval(w.startTs))
            let end = Date(timeIntervalSince1970: TimeInterval(w.endTs))
            guard end >= win.lowerBound, start <= win.upperBound else { return nil }
            return .init(start: start, end: end, symbol: sportSymbol(w.sport))
        }
    }

    /// "Charge" marker (NOOP's name for recovery) at wake time (sleep end), else at the window start.
    /// Hidden while calibrating.
    private var recoveryMarker: OverviewHRChart.EdgeMarker? {
        guard let rec = displayDay?.recovery else { return nil }
        let at = sleepToday.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) }
            ?? hrPoints.first?.date
        guard let date = at else { return nil }
        return .init(date: date, label: "\(Int(rec.rounded()))% Charge",
                     color: StrandPalette.recoveryColor(rec), alignment: .leading)
    }

    /// "Effort" marker pinned to the right edge (latest HR sample). Routed through the SAME formatter
    /// as the Effort tile (`UnitFormatter.effortDisplay`) so it honours the 0–100 / WHOOP-0–21 scale
    /// preference (#268) and reads identically — the stored strain is on the 0–100 axis, so a morning
    /// "21.2" is 21.2-of-100, not WHOOP's near-max 21-of-21.
    private var effortMarker: OverviewHRChart.EdgeMarker? {
        guard let strain = displayDay?.strain, let date = hrPoints.last?.date else { return nil }
        return .init(date: date,
                     label: "\(UnitFormatter.effortDisplay(strain, scale: effortScale)) Effort",
                     color: StrandPalette.effortTint(fraction: strain / StrainScorer.maxStrain), alignment: .trailing)
    }

    // MARK: (b) METRICS — one uniform grid of 104pt StatTiles, every cell filled.

    @ViewBuilder
    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // The section header keeps its "14-day trend" trailing label; an Edit control sits beside it
            // to open the local layout editor (#251). No new nav destination — a sheet over Today.
            HStack(alignment: .firstTextBaseline) {
                SectionHeader("Key Metrics", overline: "\(selectedDayOverline)", trailing: "14-day trend")
                Button {
                    showingMetricsEditor = true
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                        .font(StrandFont.footnote)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
                .accessibilityLabel("Edit Key Metrics")
                .help("Choose which Key Metrics show and reorder them")
            }
            // Render the enabled tiles in the saved order; an empty layout still shows the default set.
            LazyVGrid(columns: grid, alignment: .leading, spacing: NoopMetrics.gap) {
                ForEach(enabledKeyMetrics) { metric in
                    keyMetricTile(metric)
                }
            }
        }
        .sheet(isPresented: $showingMetricsEditor) {
            KeyMetricsEditorSheet(layoutRaw: $keyMetricsRaw)
        }
    }

    /// A carried recovery-vital tile's (value, caption): today's own value wins (with the metric's
    /// static unit caption); otherwise, when we're carrying the last scored day (#543), the PRIOR row's
    /// value with a "Last night · <date>" caption so the whole recovery side stays consistent rather than
    /// blanking to "—" at the rollover. A metric the carried row genuinely lacks (e.g. SpO₂ on a BLE-only
    /// night) still falls through to "—" with its unit caption — we never fabricate the new day's value.
    /// `format` renders the stored Double; `today`/`prior` pull the metric off a row (Int metrics map up).
    private func carriedVital(
        unit: String,
        today: Double?,
        prior: (DailyMetric) -> Double?,
        format: (Double) -> String
    ) -> (value: String, caption: String?) {
        if let v = today { return (format(v), unit) }
        if let p = lastScoredRecoveryDay, let v = prior(p) {
            return (format(v), carriedCaption(p))
        }
        // H10 — an empty vital on TODAY reads honestly ("After tonight's sleep") instead of a lone unit
        // beside a bare "—", which looked like a fault; a navigated PAST day keeps the plain unit (it's
        // genuinely missing data the user can't act on now). Pure copy via `emptyVitalCaption`.
        if let honest = Self.emptyVitalCaption(unit: unit, isToday: selectedDayOffset == 0) {
            return ("—", honest)
        }
        return ("—", unit)
    }

    /// One Key-Metric tile, keyed so the grid can be filtered + reordered per the saved layout (#251).
    /// Each case is byte-for-byte the tile that used to be hard-coded in the grid — the refactor only
    /// changes WHICH tiles render and in WHAT order, never how an individual tile looks.
    @ViewBuilder
    private func keyMetricTile(_ metric: KeyMetric) -> some View {
        let d = displayDay
        let aLatest = appleDays.last
        switch metric {
        case .charge:
            // Order of precedence: today's own scored recovery → mid-calibration "N of 4" → the last
            // scored day carried over ("Last night · <date>", #543) so a post-rollover today that
            // isn't scored yet keeps a real Charge instead of a bare "No Data" while live HR ticks →
            // "—" only when there is genuinely nothing banked anywhere. The carry-over shows the PRIOR
            // value labelled as prior — it never fabricates a number for the new day.
            let carried = lastScoredCharge
            StatTile(
                label: "Charge",
                value: d?.recovery.map { "\(Int($0.rounded()))%" }
                    ?? recoveryCalibration.map { "\($0)/\(Baselines.minNightsSeed)" }
                    ?? carried.map { "\(Int($0.value.rounded()))%" } ?? "—",
                // Component 2: never a bare blank — when there's no number, no calibration count and
                // nothing to carry, the caption states the honest "Needs the strap" rather than nothing.
                caption: d?.recovery.map { StrandPalette.recoveryState($0).capitalized }
                    ?? recoveryCalibration.map { _ in "Calibrating" }
                    ?? carried.map { $0.caption }
                    ?? Self.needsStrapCaption,
                accent: d?.recovery.map { StrandPalette.recoveryColor($0) }
                    ?? carried.map { StrandPalette.recoveryColor($0.value) } ?? StrandPalette.textPrimary,
                sparkline: sparks["recovery"],
                sparkColor: StrandPalette.accent
            )
        case .effort:
            // Unscored TODAY → a short "building" hint instead of the "of N" axis caption, so a
            // fresh user reads "coming" not "broken" (#527); a scored day keeps "of N".
            StatTile(
                label: "Effort",
                value: d?.strain.map { UnitFormatter.effortDisplay($0, scale: effortScale) } ?? "—",
                caption: d?.strain != nil ? "of \(UnitFormatter.effortScaleMax(effortScale))"
                                          : (buildingHint(.effort) ?? "of \(UnitFormatter.effortScaleMax(effortScale))"),
                accent: d?.strain.map { StrandPalette.effortTint(fraction: $0 / StrainScorer.maxStrain) } ?? StrandPalette.textPrimary,
                sparkline: sparks["strain"],
                sparkColor: StrandPalette.strain066,
                // Inline ⓘ in the tile header (not a corner overlay) so it never sits over the value (#495).
                accessory: { scoreInfoButton(.effort) }
            )
        case .rest:
            // Unscored TODAY → "building, wear it tonight" instead of a lone "—" caption (#527);
            // a scored day keeps its sleep-duration / efficiency caption.
            StatTile(
                label: "Rest",
                value: restScore.map { "\(Int($0.rounded()))%" } ?? "—",
                // Component 2: a scored day shows its duration/efficiency caption; an unscored TODAY shows
                // the "building" hint; a past day with no Rest falls to the honest "Needs the strap" rather
                // than a bare blank, so the tile always carries a state.
                caption: restScore != nil ? restCaption(d)
                    : (buildingHint(.rest) ?? restCaption(d) ?? Self.needsStrapCaption),
                accent: restScore.map { StrandPalette.recoveryColor($0) } ?? StrandPalette.textPrimary,
                // The Rest composite (0–100) trend, not raw sleep minutes — tracks the score above (#614).
                sparkline: sparks["sleep_performance"],
                sparkColor: StrandPalette.metricPurple,
                // Inline ⓘ in the tile header (not a corner overlay) so it never sits over the value (#495).
                accessory: { scoreInfoButton(.rest) }
            )
        case .hrv:
            // Carry the last scored night's HRV at the rollover (#543) — today's wins, the carried value
            // is stamped "Last night · <date>", and a never-scored metric still shows "—".
            let hrv = carriedVital(unit: "ms", today: d?.avgHrv,
                                   prior: { $0.avgHrv }, format: { "\(Int($0.rounded()))" })
            StatTile(
                label: "HRV",
                value: hrv.value,
                caption: hrv.caption,
                accent: hrv.value == "—" ? StrandPalette.textPrimary : StrandPalette.metricPurple,
                sparkline: sparks["hrv"],
                sparkColor: StrandPalette.metricPurple
            )
        case .restingHr:
            let rhr = carriedVital(unit: "bpm", today: d?.restingHr.map(Double.init),
                                   prior: { $0.restingHr.map(Double.init) }, format: { "\(Int($0.rounded()))" })
            StatTile(
                label: "Resting HR",
                value: rhr.value,
                caption: rhr.caption,
                accent: rhr.value == "—" ? StrandPalette.textPrimary : StrandPalette.metricRose,
                sparkline: sparks["rhr"],
                sparkColor: StrandPalette.metricRose
            )
        case .bloodOxygen:
            let spo2 = carriedVital(unit: "SpO₂", today: d?.spo2Pct,
                                    prior: { $0.spo2Pct }, format: { String(format: "%.0f%%", $0) })
            StatTile(
                label: "Blood Oxygen",
                value: spo2.value,
                caption: spo2.caption,
                accent: spo2.value == "—" ? StrandPalette.textPrimary : StrandPalette.metricCyan,
                sparkline: sparks["spo2"],
                sparkColor: StrandPalette.metricCyan
            )
        case .respiratory:
            // Respiratory keeps its sparkline-tail fallback for a NON-carrying today (a sparse-but-recent
            // value still reads); when carrying, the prior scored night's respiratory is shown + stamped.
            let respCarry = carriedVital(unit: "rpm", today: d?.respRateBpm,
                                         prior: { $0.respRateBpm }, format: { String(format: "%.1f", $0) })
            let respValue = respCarry.value == "—" && lastScoredRecoveryDay == nil
                ? latestString("resp_rate", decimals: 1) : respCarry.value
            StatTile(
                label: "Respiratory",
                value: respValue,
                // When the sparkline-tail fallback surfaces a real value (respValue ≠ "—" while respCarry
                // was empty), use the plain "rpm" caption — not carriedVital's empty "After tonight's sleep"
                // state — so the caption matches the shown number (H10 mustn't mislabel a real value).
                caption: (respValue != "—" && respCarry.value == "—") ? "rpm" : respCarry.caption,
                accent: respValue == "—" ? StrandPalette.textPrimary : StrandPalette.accent,
                sparkline: sparks["resp_rate"],
                sparkColor: StrandPalette.accent
            )
        case .steps:
            // Prefer a REAL step count: the strap's own @57 counter (DailyMetric.steps, WHOOP 5/MG),
            // then Apple Health FOR THE SELECTED DAY (#589 — when the user imported phone steps for this
            // day, show THAT number directly, not the strap estimate), then the loaded Apple-Health steps
            // sparkline tail as a last-resort recent value. Only when a day has NONE of those real sources
            // do we fall back to the on-device ESTIMATE (steps_est) a WHOOP 4.0 user gets — flagged "est."
            // so it's never mistaken for a measured count. Mirrors Android (#276/#150).
            let appleStepsForDay = appleDays.last(where: { $0.day == selectedDayKey })?.steps
                ?? (selectedDayOffset == 0 ? aLatest?.steps : nil)
            let realSteps: String? = (d?.steps).map { intString(Double($0)) }
                ?? appleStepsForDay.map { intString(Double($0)) }
                ?? (sparks["steps"]?.last).map { intString($0) }
            let estSteps = stepsEstByDay[selectedDayKey]
            // H6 — only an ESTIMATED day (no real strap/phone count, so the on-device estimate filled in)
            // gets the calibration entry; a real measured count needs no calibration.
            let isEstimated = realSteps == nil && estSteps != nil
            // #589 — when the tile would be BLANK on a strap that estimates steps (WHOOP 4.0: the steps
            // pipeline has run, so there's calibration state recorded) explain WHY rather than a bare "—",
            // and still expose the ⚙︎ so the user can reach the sheet to set a manual coefficient.
            let needsCalibration = realSteps == nil && estSteps == nil && stepsPipelineActive
            StatTile(
                label: "Steps",
                value: realSteps ?? estSteps.map { intString(Double($0)) } ?? "—",
                // An estimated day reads "est."; a not-yet-calibrated day says how many more phone-counted
                // days are needed (so a blank tile is never silently unexplained).
                caption: realSteps != nil ? "today"
                    : (estSteps != nil ? "est."
                       : (needsCalibration ? stepsCalibrationCaption : "today")),
                accent: (realSteps != nil || estSteps != nil) ? StrandPalette.metricCyan : StrandPalette.textPrimary,
                sparkline: sparks["steps"],
                sparkColor: StrandPalette.metricCyan,
                // H6 — an estimated (or awaiting-calibration) steps tile carries a small ⚙︎ that opens the
                // steps-calibration sheet (the SAME one Settings hosts), so a WHOOP 4.0 user can tune or
                // hand-set the estimate from here even before enough auto-fit days exist (#589).
                accessory: { if isEstimated || needsCalibration { stepsCalibrationButton } }
            )
        case .weight:
            StatTile(
                label: "Weight",
                value: weightTile(aLatest?.weightKg).value,
                caption: weightTile(aLatest?.weightKg).caption,
                accent: StrandPalette.accent,
                sparkline: sparks["weight"],
                sparkColor: StrandPalette.accent
            )
        case .calories:
            StatTile(
                label: "Calories",
                value: caloriesValue(aLatest),
                caption: "active",
                accent: StrandPalette.metricAmber,
                sparkline: sparks["active_kcal"],
                sparkColor: StrandPalette.metricAmber
            )
        }
    }

    // MARK: (c) LAST WORKOUTS — SAME grid, uniform 104pt workout tiles.

    @ViewBuilder
    private var workoutsSection: some View {
        if !workouts.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Last Workouts", overline: "Activity",
                              trailing: "\(workouts.count) total")
                LazyVGrid(columns: grid, alignment: .leading, spacing: NoopMetrics.gap) {
                    ForEach(Array(workouts.prefix(6).enumerated()), id: \.offset) { _, w in
                        StatTile(
                            label: "\(WorkoutSource.displaySport(w.sport))",
                            value: workoutDuration(w),
                            caption: workoutCaption(w),
                            accent: StrandPalette.effortTint(fraction: (w.strain ?? 0) / StrainScorer.maxStrain),
                            delta: w.energyKcal.map { "\(Int($0.rounded())) kcal" },
                            deltaColor: StrandPalette.metricAmber
                        )
                    }
                }
            }
        }
    }

    // MARK: (d) DATA SOURCES — one full-width footer card.

    @ViewBuilder
    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Data Sources", overline: "Provenance")
            NoopCard {
                VStack(alignment: .leading, spacing: 12) {
                    sourceRow(
                        badge: "Whoop",
                        tint: StrandPalette.accent,
                        present: !repo.days.isEmpty,
                        detail: "\(repo.days.count) days · \(repo.sleeps.count) sleeps"
                    )
                    Divider().overlay(StrandPalette.hairline)
                    sourceRow(
                        badge: "Apple Health",
                        tint: StrandPalette.metricCyan,
                        present: !appleDays.isEmpty,
                        detail: "\(appleDays.count) days · \(workouts.filter { WorkoutSource.isAppleHealth($0.source) }.count) workouts"
                    )
                    if xiaomiDays > 0 {
                        Divider().overlay(StrandPalette.hairline)
                        sourceRow(
                            badge: "Mi Band",
                            tint: StrandPalette.metricAmber,
                            present: true,
                            detail: "\(xiaomiDays) days · \(xiaomiSleeps) sleeps"
                        )
                    }
                    strapBatteryRow
                    Divider().overlay(StrandPalette.hairline)
                    strapSyncRow
                }
            }
        }
    }

    @ViewBuilder
    private func sourceRow(badge: String, tint: Color, present: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            SourceBadge("\(badge)", tint: present ? tint : StrandPalette.textTertiary)
            Spacer()
            Text(present ? detail : "Not connected")
                .font(StrandFont.captionNumber)
                .foregroundStyle(present ? StrandPalette.textSecondary : StrandPalette.textTertiary)
        }
    }

    /// Honest strap-sync outcome — the live-observing subview (StrapSyncRow) renders it. Kept as a
    /// property so `sourcesSection`'s call site is unchanged; the subview owns the `LiveState` observation
    /// so a 1 Hz HR tick refreshes only this row, not the whole dashboard (scroll-stutter fix).
    private var strapSyncRow: some View { StrapSyncRow() }

    /// Strap battery on the dashboard (#159) — the live-observing subview (StrapBatteryRow) renders it,
    /// including its own leading divider when shown. Property wrapper keeps the call site unchanged.
    private var strapBatteryRow: some View { StrapBatteryRow() }

    // MARK: - Scoring-guide info affordance

    /// A small ⓘ that opens the scoring guide at the given score's section. Sized + tinted as
    /// unobtrusive chrome so it sits in a tile/card corner without competing with the value.
    private func scoreInfoButton(_ section: ScoreSection) -> some View {
        Button {
            guideSection = section
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("How \(section.rawValue.capitalized) is calculated")
        .help("How this score is calculated")
    }

    /// H6 — the small ⚙︎ on an ESTIMATED Steps tile that opens the steps-calibration sheet. A WHOOP 4.0
    /// strap doesn't transmit steps, so NOOP estimates them from motion calibrated to the phone's count;
    /// this puts the "tune that estimate" entry right where the user reads the "est." caption.
    private var stepsCalibrationButton: some View {
        Button {
            showStepsCalibration = true
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Calibrate steps estimate")
        .help("Calibrate the steps estimate")
    }

    /// #589 — true once the WHOOP-4.0 steps-ESTIMATE pipeline has run for this user, i.e. the
    /// IntelligenceEngine has mirrored some calibration state into the profile (a fitted/manual
    /// coefficient, OR a recorded count of overlapping phone-counted days while still gathering).
    /// Gates the "needs calibration" affordance so a user whose strap reports real steps (5/MG) or who
    /// has no strap at all never sees a steps-calibration prompt on a blank tile.
    private var stepsPipelineActive: Bool {
        profile.stepsCalibrationCoefficient > 0
            || profile.stepsManualCoefficient > 0
            || profile.stepsCalibrationSampleDays > 0
    }

    /// #589 — the honest one-liner for a blank, not-yet-calibrated Steps tile: how many more days the
    /// phone also has to count steps before an estimate appears. Built from the SAME engine descriptor
    /// Settings uses (`StepsEstimateEngine.CalibrationStatus`) so the wording matches across surfaces.
    private var stepsCalibrationCaption: String {
        let status = StepsEstimateEngine.CalibrationStatus.needsMoreDays(
            have: profile.stepsCalibrationSampleDays,
            need: StepsEstimateEngine.minCalibrationDays)
        return status.headline
    }

    // MARK: - Loading

    private func loadAll() async {
        // 14-day sparklines — Whoop + Apple Health. These reads are mutually independent (distinct
        // metric keys/sources), so kick them all off concurrently with `async let` and await the
        // results below. Each hits the @MainActor Repository, fires its `await store.*` on the
        // WhoopStore actor and suspends — releasing the main actor so the next read can start —
        // instead of fully round-tripping one at a time. The assignments below stay on the main
        // actor and the final values are byte-identical to the sequential version.
        async let recoverySpark      = sparkValues("recovery", source: "my-whoop", window: 14)
        async let strainSpark        = sparkValues("strain", source: "my-whoop", window: 14)
        async let sleepTotalSpark    = sparkValues("sleep_total_min", source: "my-whoop", window: 14)
        async let hrvSpark           = sparkValues("hrv", source: "my-whoop", window: 14)
        async let rhrSpark           = sparkValues("rhr", source: "my-whoop", window: 14)
        async let spo2Spark          = sparkValues("spo2", source: "my-whoop", window: 14)
        async let respRateSpark      = sparkValues("resp_rate", source: "apple-health", window: 14)
        async let stepsAppleSpark    = sparkValues("steps", source: "apple-health", window: 14)
        async let weightSpark        = sparkValues("weight", source: "apple-health", window: 90)
        async let activeKcalSpark    = sparkValues("active_kcal", source: "apple-health", window: 14)

        sparks["recovery"]        = await recoverySpark
        sparks["strain"]          = await strainSpark
        sparks["sleep_total_min"] = await sleepTotalSpark
        sparks["hrv"]             = await hrvSpark
        sparks["rhr"]             = await rhrSpark
        sparks["spo2"]            = await spo2Spark
        sparks["resp_rate"]   = await respRateSpark
        sparks["steps"]       = await stepsAppleSpark
        // Steps prefer the strap's own @57 daily total (no metricSeries — it lives on the daily row),
        // so a strap-only WHOOP 5/MG user gets a steps trend without Apple Health. Falls back to the
        // Apple Health series above when the strap supplied no steps (#276). This synchronous overwrite
        // must run AFTER sparks["steps"] is assigned from the Apple-Health read above (unchanged order).
        let strapSteps = repo.days.suffix(14).compactMap { $0.steps.map(Double.init) }
        if !strapSteps.isEmpty { sparks["steps"] = strapSteps }
        sparks["weight"]      = await weightSpark
        sparks["active_kcal"] = await activeKcalSpark

        // The next block of reads are all mutually independent (distinct keys/sources, none consumes
        // another's result): the Rest + steps-estimate series, the two provenance resolves, workout +
        // Apple-daily rows, the two Mi-Band series, and the three "your cards" series. Fire them all
        // off concurrently with `async let`, then await each where its result is first used — same
        // data, same derivations, same assignment order as the sequential version, all on the main actor.
        async let restSeriesA       = repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        async let stepsEstSeriesA    = repo.exploreSeries(key: "steps_est", source: "my-whoop")
        async let recoveryResolvedA  = repo.resolvedSeries(key: "recovery", source: Repository.whoopSource)
        async let restResolvedA      = repo.resolvedSeries(key: "sleep_performance", source: Repository.whoopSource)
        async let workoutsA          = repo.workoutRows()
        async let appleDaysA         = repo.appleDailyRows()
        async let xStepsA            = repo.series(key: "steps", source: "xiaomi-band")
        async let xSleepA            = repo.series(key: "sleep_total_min", source: "xiaomi-band")
        async let stressSeriesA      = repo.exploreSeries(key: "stress", source: "my-whoop")
        async let fitnessAgeSeriesA  = repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        async let vitalitySeriesA    = repo.exploreSeries(key: "vitality", source: "my-whoop")

        // Rest SCORE for the logical day. `exploreSeries` already merges imported + computed
        // `sleep_performance` (imported-wins), so a Bluetooth-only user sees the on-device Rest
        // composite and an importer sees the export's figure — exactly like the Rest detail screen.
        let restSeries = await restSeriesA
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        // The Rest TILE's sparkline (#614 follow-up). The tile's number is `restScore` (the Rest composite,
        // 0–100) but its mini-graph used to plot raw sleep MINUTES (`sparks["sleep_total_min"]`), so the
        // trend didn't track the score it sat under. Plot the SAME merged `sleep_performance` 0–100 series
        // the score reads instead, windowed to the trailing 14 calendar days like every other spark.
        sparks["sleep_performance"] = trailingWindow(restSeries, days: 14).map { $0.value }

        // Steps ESTIMATE per day (WHOOP 4.0 motion → calibrated steps). exploreSeries reads the computed
        // "-noop" metricSeries the IntelligenceEngine writes, exactly like the Explore "steps_est" metric.
        // Only consulted when a day has no REAL step count (see the .steps tile), so it never overrides a
        // measured value — it just fills the gap a 4.0 user would otherwise see as "—".
        let stepsEstSeries = await stepsEstSeriesA
        stepsEstByDay = Dictionary(stepsEstSeries.map { ($0.day, Int($0.value.rounded())) },
                                   uniquingKeysWith: { _, last in last })
        // The selected day's Rest, falling back to the series tail only when today itself is selected —
        // a navigated past day with no Rest row shows "—" rather than borrowing the newest value.
        restScore = restByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? restSeries.last?.value : nil)

        // Component 4 — resolve the REAL per-day merge winner for the selected day's derived scores. The
        // cross-source resolver applies the SAME imported-WHOOP > NOOP-computed > Apple-Health precedence
        // the dashboard merge uses, returning the source that actually supplied each day's value — so the
        // provenance badge reflects the truth (computed vs imported), never a blanket "on-device". Keyed by
        // metric so the Charge ring and Rest tile each badge their own winner.
        var provenance: [String: String] = [:]
        let recoveryResolved = await recoveryResolvedA
        if let win = recoveryResolved.points.last(where: { $0.day == selectedDayKey })?.source {
            provenance["recovery"] = win
        }
        let restResolved = await restResolvedA
        if let win = restResolved.points.last(where: { $0.day == selectedDayKey })?.source {
            provenance["sleep_performance"] = win
        }
        provenanceByMetric = provenance

        workouts = await workoutsA
        appleDays = await appleDaysA
        // Mi Band (Mi Fitness import) — distinct days across its representative metric keys.
        let xSteps = await xStepsA
        let xSleep = await xSleepA
        xiaomiDays = Set(xSteps.map(\.day) + xSleep.map(\.day)).count
        // Your cards (#582 / Design Reset): latest Stress / Fitness age / Vitality for the pinned home
        // cards. Same merged exploreSeries reads their detail screens use; nil simply hides that card.
        stressToday = (await stressSeriesA).last?.value
        fitnessAgeToday = (await fitnessAgeSeriesA).last?.value
        vitalityToday = (await vitalitySeriesA).last?.value
        // Hydration card (opt-in): today's stored total + the sex/Effort goal. Only loaded when the
        // feature is on, so a disabled feature does zero work and the card stays hidden.
        if hydrationEnabled {
            hydrationTotalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
            hydrationGoalML = repo.hydrationGoalML(profileSex: profile.sex)
        } else {
            hydrationTotalML = nil
            hydrationGoalML = nil
        }
        if let store = await repo.storeHandle() {
            let farFuture = Int(Date.distantFuture.timeIntervalSince1970)
            xiaomiSleeps = ((try? await store.sleepSessions(deviceId: "xiaomi-band", from: 0, to: farFuture, limit: 4000))?.count) ?? 0
        }

        // HR trend for the SELECTED day — 5-minute bucket means from that logical day's local midnight.
        // For today the window runs to now (an in-progress curve); for a navigated past day it runs the
        // full 24h to the next midnight. The logical day rolls at 04:00 (Repository.logicalDayStart), so
        // in the small hours after midnight today still starts at yesterday's midnight rather than
        // blanking to an empty new-calendar-day axis (#144).
        let dayStart = Calendar.current.startOfDay(for: selectedLogicalDay)
        let windowStart = Int(dayStart.timeIntervalSince1970)
        let windowEnd: Int = selectedDayOffset == 0
            ? Int(Date().timeIntervalSince1970)
            : Int((Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)
        hrPoints = await repo.hrBuckets(from: windowStart, to: windowEnd, bucketSeconds: 300)
            .map { TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0.ts)), value: $0.bpm) }

        // #605: if today itself has no HR yet, land the dashboard on the most recent day that DOES have
        // data rather than presenting an empty graph (the top fresh-strap complaint). One-shot — changing
        // selectedDayOffset re-runs this load for the landed day via .task(id:); the guard stops it
        // re-evaluating, so the user can chevron back to today freely. Mirrors the Deep Timeline (#597).
        if !didAutoLandLatest, selectedDayOffset == 0, hrPoints.isEmpty,
           let latest = await repo.latestDataDayStart() {
            didAutoLandLatest = true
            let cal = Calendar.current
            let todayStart = cal.startOfDay(for: Repository.logicalDay(Date()))
            let latestStart = cal.startOfDay(for: latest)
            let back = cal.dateComponents([.day], from: latestStart, to: todayStart).day ?? 0
            if back > 0 { selectedDayOffset = back; return }
        }

        // In-progress Effort for TODAY (#402): score today's strain over the SAME window the HR curve
        // above shows (logical-day midnight → now) so the gauge tracks the day live instead of lagging
        // on the last persisted daily row. Uses the identical params the daily pass uses — Tanaka HRmax
        // from age, today's resting HR (else the default), sex — so the live number matches what the
        // engine will eventually persist. Below StrainScorer.minReadings the scorer returns nil and the
        // gauge falls back to the stored row (never a fabricated value); a navigated past day clears it.
        if selectedDayOffset == 0 {
            let todayHr = await repo.hrSamples(from: windowStart, to: windowEnd)
            let maxHR = profile.age > 0 ? StrainScorer.tanakaHRmax(age: Double(profile.age)) : nil
            let restHR = displayDay?.restingHr.map(Double.init) ?? StrainScorer.defaultRestingHR
            liveTodayStrain = StrainScorer.strain(todayHr, maxHR: maxHR, restingHR: restHR, sex: profile.sex)
        } else {
            liveTodayStrain = nil
        }
        // Pin the chart axis to the loaded window — today midnight→now, a past day the full 24h — so
        // a gap (e.g. a morning the strap wasn't banking) shows as empty space, not a late start.
        hrAxis = Date(timeIntervalSince1970: TimeInterval(windowStart))
            ... Date(timeIntervalSince1970: TimeInterval(windowEnd))

        // Sleep session overlapping the window. Uses `allSleepSessions` (BOTH the imported and the
        // on-device COMPUTED source) — a Bluetooth-only user's sleep lives under the computed source,
        // so the imported-only `sleepSessions` returns nothing. Keep blocks that actually overlap the
        // displayed window, then pick the LONGEST — the main night, not an afternoon nap. Drives the
        // HR sleep band + the recovery marker's wake anchor.
        sleepToday = await repo.allSleepSessions(days: selectedDayOffset + 2)
            .filter { $0.endTs > windowStart && $0.startTs < windowEnd }
            .max(by: { ($0.endTs - $0.startTs) < ($1.endTs - $1.startTs) })

        announceNewDaysIfNeeded()
    }

    /// Post a single honest `.reading` update to the inbox when a refresh brought in genuinely NEWER
    /// history (a WHOOP import or an overnight backfill that pushed the newest day forward). We compare
    /// the MAX day-key in `repo.days`, not the count (#521): a background recompute rebuilds the window
    /// via delete-then-reinsert, so the count momentarily dips and recovers, but the newest key is
    /// unchanged — so churn never fires this. The very first load (empty baseline) records the key
    /// silently; a navigated past day is ignored; the persisted key means a relaunch over the same
    /// history never re-announces. The count of newly-forward days is real (keys strictly above the
    /// previous max), never fabricated. Links to Trends.
    private func announceNewDaysIfNeeded() {
        guard selectedDayOffset == 0 else { return }
        guard let newestKey = repo.days.map(\.day).max() else { return }   // no history yet
        let previousKey = lastAnnouncedDayKey
        defer { lastAnnouncedDayKey = newestKey }
        // No baseline yet → record silently, never announce historical data on first sight.
        guard !previousKey.isEmpty else { return }
        // Only a STRICTLY newer day-key counts as new history (yyyy-MM-dd sorts chronologically).
        guard newestKey > previousKey else { return }
        // Honest count of how many distinct days arrived ABOVE the old watermark.
        let added = Set(repo.days.map(\.day)).filter { $0 > previousKey }.count
        guard added > 0 else { return }
        updateStore.post(UpdateItem(
            kind: .reading,
            title: "New data added",
            message: added == 1 ? "1 new day of history landed. Open Trends to see it."
                                : "\(added) new days of history landed. Open Trends to see them.",
            deepLink: NavRouter.Destination.trends.rawValue
        ))
    }

    /// Trailing-window values for a metric — NO fall back to all history. The section is labelled a
    /// current trend ("14-day trend"), so a stale import must not render months-old points as if they
    /// were recent (same spirit as the #23 trailing-window fix). The window is generous enough that a
    /// genuinely sparse-but-recent series still renders — weight uses 90 days — and the Sparkline view
    /// already handles 0/1 points (empty / a single head dot), so no fallback is needed for layout.
    /// `latestString` reads `.last` of this windowed series, so a value older than the window shows
    /// "—" rather than a stale number under a Today tile (#49).
    private func sparkValues(_ key: String, source: String, window: Int) async -> [Double] {
        let all = await repo.series(key: key, source: source)   // full history, asc
        guard !all.isEmpty else { return [] }
        return trailingWindow(all, days: window).map { $0.value }
    }

    /// Keep only points within the trailing `days` CALENDAR days ending TODAY (the phone's local date).
    /// Was anchored to the most-recent point, which on a stale import pinned the window to months-old
    /// data shown as a current trend (issue #23). ISO yyyy-MM-dd compares chronologically.
    private func trailingWindow(_ points: [(day: String, value: Double)], days: Int) -> [(day: String, value: Double)] {
        let cutoffKey = Repository.localDayKey(Calendar.current.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date())
        return points.filter { $0.day >= cutoffKey }
    }

    /// Latest value of a loaded sparkline series, formatted — for tiles whose hero
    /// can't be read off `appleDailyRows` (e.g. respiratory from apple-health).
    private func latestString(_ key: String, decimals: Int, unit: String = "") -> String {
        guard let last = sparks[key]?.last else { return "—" }
        let n = decimals == 0 ? intString(last) : String(format: "%.\(decimals)f", last)
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    /// The Weight tile's display string + an honest caption ("from profile" only on the fallback).
    /// Prefers a real Apple-Health reading (today's daily, else the "weight" series' newest point so a
    /// sparse-but-recent value still renders); when neither carries a weight, falls back to the user's
    /// self-reported profile weight instead of "—" (#204). Always formatted through the shared
    /// `UnitFormatter` so the Imperial/Metric toggle reaches this tile. Mirrors Android's `weightTile`.
    private func weightTile(_ appleWeightKg: Double?) -> (value: String, caption: String) {
        if let kg = appleWeightKg ?? sparks["weight"]?.last {
            return (UnitFormatter.massFromKilograms(kg, system: unitSystem), "latest")
        }
        return (UnitFormatter.massFromKilograms(profile.weightKg, system: unitSystem), "from profile")
    }

    // MARK: - Derived text

    /// Greeting word used as the section's trailing label (no lone text block).
    private var greetingWord: String {
        #if DEBUG
        // DEBUG promo harness: pin the greeting to the active frame's wording. No-op otherwise.
        if let f = DemoDayHarness.active { return f.greeting }
        #endif
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case ..<12:   return "Good morning"
        case 12..<17: return "Good afternoon"
        default:      return "Good evening"
        }
    }

    private var dateLine: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE, d MMMM"
        // The selected day's date when navigated; today's banked-row date (or today) at offset 0.
        if selectedDayOffset == 0, let day = repo.today?.day, let date = Self.dayParser.date(from: day) {
            return f.string(from: date)
        }
        return f.string(from: selectedLogicalDay)
    }

    /// Hero title that names the selected day — "Today's"/"Yesterday's"/"Day's" Synthesis.
    private var synthesisTitle: LocalizedStringKey {
        switch selectedDayOffset {
        case 0:  return "Today’s Synthesis"
        case 1:  return "Yesterday’s Synthesis"
        default: return "Synthesis"
        }
    }

    /// Section overline naming the selected day — "Today"/"Yesterday"/"EEE d MMM".
    private var selectedDayOverline: String {
        switch selectedDayOffset {
        case 0:  return "Today"
        case 1:  return "Yesterday"
        default:
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE d MMM"
            return f.string(from: selectedLogicalDay)
        }
    }

    /// A short recovery state word for the synthesis hero.
    private func synthesisWord(_ score: Double?) -> String {
        guard let s = score else { return "No Data" }
        switch s {
        case ..<25:  return "Depleted"
        case ..<50:  return "Low"
        case ..<70:  return "Steady"
        case ..<88:  return "Primed"
        default:     return "Peak"
        }
    }

    /// Plain-English synthesis of recovery + sleep.
    private func synthesisDetail(_ d: DailyMetric?) -> String {
        guard let d, let rec = d.recovery else {
            return "No metrics yet. Import your Whoop export or wear the strap to begin."
        }
        let recPart: String
        switch rec {
        case ..<50:  recPart = "Charge is low"
        case ..<70:  recPart = "Charge is steady"
        default:     recPart = "Charge is strong"
        }
        let sleepPart: String
        if let mins = d.totalSleepMin {
            let h = mins / 60.0
            sleepPart = h >= 7 ? " and sleep was consistent" : " but sleep ran short"
        } else {
            sleepPart = ""
        }
        return recPart + sleepPart + "."
    }

    private func ringSupporting(_ d: DailyMetric?) -> String {
        let hrv = d?.avgHrv.map { "\(Int($0.rounded())) ms" } ?? "— ms"
        let rhr = d?.restingHr.map { "\($0)" } ?? "—"
        return "HRV \(hrv) · RHR \(rhr)"
    }

    private func sleepValue(_ d: DailyMetric?) -> String {
        guard let m = d?.totalSleepMin else { return "—" }
        let h = Int(m) / 60, mm = Int(m) % 60
        return "\(h)h \(mm)m"
    }

    /// The Rest tile's caption — hours-in-bed for the day, the figure that used to be the tile's
    /// VALUE before #248 moved the Rest score there. Falls back to the efficiency read-out when no
    /// duration is banked, and to nil so the tile shows no caption line at all when neither exists.
    private func restCaption(_ d: DailyMetric?) -> String? {
        if d?.totalSleepMin != nil { return sleepValue(d) }
        return d?.efficiency.map { String(format: "%.0f%% eff", $0) }
    }

    /// Short "it's coming, not broken" caption for an unscored Effort/Rest tile on TODAY only. The
    /// call sites only reach here when the score is genuinely absent; this adds the today-only gate so
    /// a navigated PAST day with no score honestly stays a bare "—" (missing data, not mid-calibration).
    /// Mirrors the recoveryCalibration today-only rule the Charge tile uses for its "N of 4" treatment.
    private func buildingHint(_ metric: KeyMetric) -> String? {
        Self.buildingHintCopy(metric, isToday: selectedDayOffset == 0)
    }

    /// The Component-2 "needs the strap" tile caption — the honest no-data state word a Charge/Rest tile
    /// shows instead of a bare blank when there's no value, no calibration count and nothing to carry.
    /// Matches `MetricTileState.needsStrap.title` verbatim so the tile and the explained note say the same words.
    static let needsStrapCaption = "Needs the strap"

    /// H10 — the honest empty-state caption for a recovery-vital tile (HRV / Resting HR / SpO₂ / Respiratory)
    /// when TODAY has no value yet and there's nothing to carry over. Those vitals are measured overnight, so
    /// "After tonight's sleep" tells the user WHEN the tile fills rather than leaving a bare "—" beside a lone
    /// unit that read as broken. Returns nil off-today (a past day keeps the plain unit — it's missing data the
    /// user can't act on now). Pure copy/gate so it can be unit-tested without a live view. Mirror in Kotlin.
    static func emptyVitalCaption(unit: String, isToday: Bool) -> String? {
        guard isToday else { return nil }
        return "After tonight's sleep"
    }

    /// Pure copy/gate behind `buildingHint` — extracted so it can be unit-tested without a live view.
    /// Rest fills in after a night's sleep; Effort fills in once cardio load is logged. Em-dash-free
    /// house style. Returns nil off-today and for any metric other than Effort/Rest (#527).
    static func buildingHintCopy(_ metric: KeyMetric, isToday: Bool) -> String? {
        guard isToday else { return nil }
        switch metric {
        case .rest:   return "Building, wear it tonight"
        case .effort: return "Building, moves as you do"
        default:      return nil
        }
    }

    /// Active calories (Apple) for the latest day, falling back to the sparkline tail.
    private func caloriesValue(_ a: AppleDaily?) -> String {
        if let kcal = a?.activeKcal { return intString(kcal) }
        return latestString("active_kcal", decimals: 0)
    }

    private func workoutDuration(_ w: WorkoutRow) -> String {
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        let mins = Int((secs / 60).rounded())
        if mins >= 60 { return "\(mins / 60)h \(mins % 60)m" }
        return "\(mins)m"
    }

    /// "d MMM · HH:mm–HH:mm", start-only when the row has no real end (#157). The "· N bpm"
    /// segment was dropped: the StatTile caption is lineLimit(1) and date + range + bpm clips —
    /// avg HR remains on the Workouts screen.
    private func workoutCaption(_ w: WorkoutRow) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d MMM"
        let start = Date(timeIntervalSince1970: TimeInterval(w.startTs))
        let date = f.string(from: start)
        guard w.endTs > w.startTs else { return "\(date) · \(Self.hrTimeFmt.string(from: start))" }
        let end = Date(timeIntervalSince1970: TimeInterval(w.endTs))
        return "\(date) · \(Self.hrTimeFmt.string(from: start))–\(Self.hrTimeFmt.string(from: end))"
    }

    /// Thousands-grouped integer string (steps / calories).
    private func intString(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(Int(v.rounded()))"
    }

    // MARK: - Date parsing (yyyy-MM-dd, en_US_POSIX, LOCAL zone)
    //
    // Parses a `DailyMetric.day` key, which is written in the device's LOCAL zone
    // (Repository.dayKeyFormatter sets no zone — the post-#277 local-day bucketing).
    // It MUST parse in that same local zone: parsing a local-day key like "2026-06-14"
    // as UTC yields 00:00Z, which is still June 13 in any negative-UTC zone, so the
    // header subtitle then printed the previous day for everyone west of UTC (#319/#320).
    // Matching dayKeyFormatter (no explicit zone) makes the parse→format round-trip an identity.

    static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Local wall-clock time for the HR trend's x-axis / tooltip — the chart spans one day, so it must
    /// show times, not the day-granularity default ("EEE d MMM"). Also formats the workout-tile caption's
    /// time range (#157). The "jmm" skeleton respects the device's 12-/24-hour setting (#337): "7:10 AM"
    /// where 12-hour is preferred, "19:10" where 24-hour is — instead of forcing one on everyone.
    static let hrTimeFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()
}

/// `.task(id:)` key combining the data refresh sequence with the selected day so a reload runs on
/// either a data change or a day-navigation change (the HR trend + Rest score are day-scoped).
private struct TodayLoadKey: Equatable {
    let seq: Int
    let offset: Int
}

// MARK: - Live-observing leaf subviews (scroll-stutter isolation)
//
// TodayView itself does NOT observe `LiveState` (see the @EnvironmentObject note at the top of the
// type). These small leaves each hold their OWN `@EnvironmentObject var live`, so a connected strap's
// ~1 Hz publish re-renders only the affected dot / note / row, never the rings, scene, sparklines,
// HR chart or cards. They render byte-for-byte what the inline code did before the extraction.

/// The compact 36pt recording-status light in the iOS top bar — a colour-coded dot (green recording,
/// amber last-synced, red not recording, accent for experimental 5.0 history). Taps to Devices. Owns
/// the `LiveState` observation so a live-HR tick refreshes only this dot.
private struct RecordingStatusLight: View {
    @EnvironmentObject private var live: LiveState
    let selectedDayOffset: Int
    let onTap: () -> Void

    /// Colour for the light: green recording, amber last-synced, red not recording, accent for
    /// experimental history. Mirrors the prior `TodayView.recordingHue` semantics verbatim.
    private func hue(_ state: RecordingState) -> Color {
        switch state {
        case .recording:           return StrandPalette.statusPositive
        case .lastSynced:          return StrandPalette.statusWarning
        case .notRecording:        return Color(red: 0.98, green: 0.27, blue: 0.23)
        case .historyExperimental: return StrandPalette.accent
        }
    }

    var body: some View {
        if let state = TodayView.recordingState(live: live, selectedDayOffset: selectedDayOffset) {
            Button(action: onTap) {
                Circle().fill(StrandPalette.surfaceInset)
                    .frame(width: 36, height: 36)
                    .overlay(Circle().fill(hue(state)).frame(width: 10, height: 10))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.accessibilityText)
        }
    }
}

/// The "Syncing strap history…" note, shown only while a historical offload is running (#77). Owns the
/// `LiveState` observation so the chunk count ticks without re-rendering the rest of Today.
private struct SyncingHistoryNoteIfBackfilling: View {
    @EnvironmentObject private var live: LiveState
    var body: some View {
        if live.backfilling { SyncingHistoryNote(chunks: live.syncChunksThisSession) }
    }
}

/// Honest strap-sync outcome row for the Data Sources card (ports the Android Live line, ed6a31d): the
/// stalled-offload error when the last one died, else "History synced N ago". Hidden while an offload
/// runs — the SyncingHistoryNote already says so. The `TimelineView` re-renders the relative label each
/// minute. Owns the `LiveState` observation (scroll-stutter isolation).
private struct StrapSyncRow: View {
    @EnvironmentObject private var live: LiveState
    var body: some View {
        if !live.backfilling {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                HStack(alignment: .top, spacing: 10) {
                    SourceBadge("Strap sync",
                                tint: live.lastSyncError != nil ? StrandPalette.statusWarning
                                    : live.lastSyncedAt != nil ? StrandPalette.accent
                                    : StrandPalette.textTertiary)
                    Spacer()
                    if let error = live.lastSyncError {
                        Text(error)
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.statusWarning)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let at = live.lastSyncedAt {
                        Text("History synced \(relativeAgo(at, now: context.date.timeIntervalSince1970))")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        Text("Not synced yet")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
        }
    }
}

/// Strap battery row for the Data Sources card (#159) — shown ONLY while a strap is connected AND a
/// reading exists, with its own leading divider so the row + divider appear/vanish together (no empty
/// state). Owns the `LiveState` observation (scroll-stutter isolation).
private struct StrapBatteryRow: View {
    @EnvironmentObject private var live: LiveState

    /// Battery tint — same thresholds as the menu-bar stat (MenuBarContent.batteryTone).
    private func tint(_ pct: Double) -> Color {
        switch pct {
        case ..<15: return StrandPalette.statusCritical
        case ..<35: return StrandPalette.statusWarning
        default:    return StrandPalette.statusPositive
        }
    }

    /// Level-banded battery glyph; the bolt variant when the strap reports charging.
    private func symbol(_ pct: Double) -> String {
        if live.charging == true { return "battery.100.bolt" }
        switch pct {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default:    return "battery.100"
        }
    }

    var body: some View {
        if live.connected, let pct = live.batteryPct {
            Divider().overlay(StrandPalette.hairline)
            HStack(spacing: 10) {
                SourceBadge("Strap battery", tint: tint(pct))
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: symbol(pct))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tint(pct))
                    Text("\(Int(pct.rounded()))%")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Strap battery \(Int(pct.rounded())) percent\(live.charging == true ? ", charging" : "")")
            }
        }
    }
}

// MARK: - Explainability state models (Components 2 & 3 of the sleep-guidance spec)
//
// "No bare number without a STATE, a REASON, and a NEXT STEP." Each enum carries its own
// verbatim copy from the 2026-06-20 spec so a score/tile never renders a lone blank. These are
// pure value types with pure mappers so they unit-test off the live view, and they mirror 1:1
// with the Kotlin Today lane (com.noop.ui — same case names, same order, same words).

/// COMPONENT 2 — the explained state of one score/tile on Today. `scored` carries the real value;
/// the other three NEVER carry a number (the honesty rule — calibrating / needsStrap show no value,
/// carried always stamped with its date). Each non-scored case yields a title, a detail line, and a
/// next step the UI renders instead of a bare blank.
enum MetricTileState: Equatable {
    /// Today's own value exists — the caller renders the number itself; this case is the "all good" gate.
    case scored
    /// Baselines still cold-start: `nightsRemaining` more nights until the score is personal. No number.
    case calibrating(nightsRemaining: Int)
    /// A prior scored day shown pre-tonight (#543 carry-over). `date` is that scored day's own date.
    case carriedLastNight(date: String)
    /// No data for the period — strap not worn / not connected / not synced. No number.
    case needsStrap

    /// The state's short title. `scored` has no title (the value is the headline) so it returns nil.
    /// Verbatim spec copy; `\(...)` interpolation feeds the dynamic value into the LocalizedStringKey slot.
    var title: LocalizedStringKey? {
        switch self {
        case .scored:                       return nil
        case .calibrating:                  return "Calibrating"
        case .carriedLastNight(let date):   return "Last night · \(date)"
        case .needsStrap:                   return "Needs the strap"
        }
    }

    /// The one-line detail + next step. Verbatim spec copy.
    var detail: LocalizedStringKey? {
        switch self {
        case .scored:
            return nil
        case .calibrating(let n):
            // "night(s)" pluralises honestly so a single remaining night doesn't read "1 nights".
            return "Building your baseline. About \(n) more \(n == 1 ? "night" : "nights") until your scores are personal."
        case .carriedLastNight:
            return "Tonight's lands after you sleep with the strap on."
        case .needsStrap:
            return "No data for today. Was your strap worn and connected overnight?"
        }
    }

    /// VoiceOver-friendly plain string of title + detail (no markdown interpolation surprises). nil when scored.
    var accessibilityText: String? {
        switch self {
        case .scored:
            return nil
        case .calibrating(let n):
            return "Calibrating. Building your baseline. About \(n) more \(n == 1 ? "night" : "nights") until your scores are personal."
        case .carriedLastNight(let date):
            return "Last night, \(date). Tonight's lands after you sleep with the strap on."
        case .needsStrap:
            return "Needs the strap. No data for today. Was your strap worn and connected overnight?"
        }
    }

    /// Convenience for the hero, where calibration is already richly explained by the data-confidence
    /// pill + Synthesis card + ring overlay, so the explained note defers to those for that one case.
    var isCalibrating: Bool {
        if case .calibrating = self { return true }
        return false
    }

    /// PURE mapper (unit-testable) — the honest precedence behind every Today score/tile state, given
    /// the engine outputs already computed on the view. Mirror EXACTLY in Kotlin (same order of checks):
    ///   1. today's own value exists            → `.scored`
    ///   2. still mid-calibration (today only)  → `.calibrating(nightsRemaining)`
    ///   3. a prior scored day to carry (#543)  → `.carriedLastNight(date)`
    ///   4. nothing banked anywhere             → `.needsStrap`
    /// `nightsRemaining` is clamped to AT LEAST 1 so a boundary count never reads "0 more nights" while
    /// calibration is genuinely still on (the singular/plural rule then reads the clamped value). Mirror
    /// the Kotlin `coerceAtLeast(1)` exactly.
    static func resolve(hasTodayValue: Bool,
                        calibratingNightsRemaining: Int?,
                        carriedDate: String?) -> MetricTileState {
        if hasTodayValue { return .scored }
        if let remaining = calibratingNightsRemaining { return .calibrating(nightsRemaining: max(1, remaining)) }
        if let date = carriedDate { return .carriedLastNight(date: date) }
        return .needsStrap
    }
}

/// COMPONENT 3 — the strap's live recording status, mapped honestly from the BLE connection + last-sync.
/// One clear chip on Today so people know it's working, or know it isn't and why. Mirrors the Kotlin
/// Today lane 1:1 (same cases, same order, same words).
enum RecordingState: Equatable {
    /// Connected and saving data live.
    case recording
    /// Not connected now but synced `minutesAgo` minutes back — reconnect to pull the latest.
    case lastSynced(minutesAgo: Int)
    /// Strap not connected and nothing fresh to fall back on.
    case notRecording
    /// #580 — a connected WHOOP 5/MG streaming live HR fine, but its firmware hands over no history
    /// offload yet. NOT the WHOOP-4 "not recording" failure: the link is live, history sync is just
    /// experimental on 5.0. Surfaced from `LiveState.historySyncExperimental`, overriding the mapper.
    case historyExperimental

    /// The chip's short label. Verbatim spec copy; the dynamic "Xm" goes into the LocalizedStringKey slot.
    var label: LocalizedStringKey {
        switch self {
        case .recording:                 return "Recording"
        case .lastSynced(let mins):      return "Last synced \(mins)m ago"
        case .notRecording:              return "Not recording"
        case .historyExperimental:       return "Connected"
        }
    }

    /// The supporting detail line. Verbatim spec copy.
    var detail: LocalizedStringKey {
        switch self {
        case .recording:           return "Your strap is connected and saving data."
        case .lastSynced:          return "Reconnect to pull the latest."
        case .notRecording:        return "Strap not connected. Tap to connect."
        case .historyExperimental: return "History sync is experimental on 5.0."
        }
    }

    /// VoiceOver plain string (label + detail).
    var accessibilityText: String {
        switch self {
        case .recording:
            return "Recording. Your strap is connected and saving data."
        case .lastSynced(let mins):
            return "Last synced \(mins) minutes ago. Reconnect to pull the latest."
        case .notRecording:
            return "Not recording. Strap not connected. Tap to connect."
        case .historyExperimental:
            return "Connected. History sync is experimental on 5.0."
        }
    }

    /// PURE mapper (unit-testable) — `recording` IFF (connected AND a live heart-rate sample is currently
    /// present). A connection with no live HR yet (handshaking, no PPG, strap off the wrist) is honestly
    /// NOT recording. Otherwise, if a last-sync time is known, reads "Last synced Xm ago"; else "Not
    /// recording". `lastSyncedAt` / `now` are unix seconds; the minute count clamps at >= 0 (strap-clock
    /// skew can't read negative) and uses ceil so a 30-second-old sync reads "1m ago" rather than "0m ago".
    /// Mirror EXACTLY in Kotlin.
    static func resolve(connected: Bool,
                        heartRate: Int?,
                        lastSyncedAt: TimeInterval?,
                        now: TimeInterval = Date().timeIntervalSince1970) -> RecordingState {
        if connected && heartRate != nil { return .recording }
        if let at = lastSyncedAt {
            let secs = max(0, now - at)
            let mins = Int((secs / 60).rounded(.up))
            return .lastSynced(minutesAgo: mins)
        }
        return .notRecording
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Control Center") {
    let repo = Repository(deviceId: "preview")
    let cal = Calendar(identifier: .gregorian)
    let today = cal.startOfDay(for: Date())
    var sample: [DailyMetric] = []
    for i in stride(from: 39, through: 0, by: -1) {
        let date = cal.date(byAdding: .day, value: -i, to: today)!
        let day = Repository.dayString(date)
        let phase = Double(i)
        let rec = 48 + 34 * sin(phase / 5.0) + Double((i * 7) % 11)
        let strain = 8 + 7 * abs(sin(phase / 4.0))
        let total = 380 + 70 * sin(phase / 6.0)
        sample.append(DailyMetric(
            day: day, totalSleepMin: total, efficiency: 88 + 6 * sin(phase / 3.0),
            deepMin: 95, remMin: 110, lightMin: total - 200, disturbances: 4,
            restingHr: 50 + (i % 6), avgHrv: 58 + 16 * sin(phase / 4.0),
            recovery: min(max(rec, 8), 99), strain: strain, exerciseCount: i % 3,
            spo2Pct: 96, skinTempDevC: 33.4, respRateBpm: 14.6
        ))
    }
    repo.days = sample
    repo.loaded = true

    return TodayView()
        .environmentObject(repo)
        .frame(width: 920, height: 940)
        .preferredColorScheme(.dark)
}
#endif
