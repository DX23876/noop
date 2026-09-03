//  LiquidTodayView.swift
//  NOOP · Liquid design language — the Today screen, rebuilt in the liquid finish.
//
//  This is the FULL Today, re-created faithfully from the locked mockup
//  (scratchpad/liquid-metal-home.html): sky title + record/add/battery controls,
//  the three scores as liquid vessels with a card-level source badge, the live heart-rate
//  thread, the five "your cards" as liquid chips, a greeting + readiness pills,
//  Synthesis, Recovery Vitals, a Key Metrics grid (incl. steps), Last Workouts
//  and Data Sources. Every value binds to the SAME real data the classic
//  TodayView reads (accessors verified against TodayView.swift), and every tap
//  routes to the same public destination. The sky is a fixed, full-bleed
//  background (edge-to-edge under the status bar, does not scroll).

import SwiftUI
import StrandDesign
import WhoopStore
import StrandAnalytics

/// Size for the Today header's round controls, in one place because the buttons live in several separate
/// views (`LiquidAddButton`, `LiquidBatteryButton`, the inline Arrange button, the profile avatar, the
/// Coach and Updates-bell buttons) and drifted apart otherwise. One uniform size for the whole cluster,
/// six icons and all.
///
/// It is now an ALIAS for the design system's `compactControlSize` rather than this fork's own 30pt: the
/// charge/sync indicator (#837) sizes its ring and its expanded capsule off that token, and a header
/// where one control is 6pt smaller than the one beside it reads as a mistake. Kept as a named constant
/// so the several call sites keep saying what they mean.
enum LiquidHeaderMetrics {
    /// Every header control: profile, coach, add, battery, bell, arrange.
    static let control: CGFloat = NoopMetrics.compactControlSize
}

struct LiquidTodayView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter
    @EnvironmentObject var profile: ProfileStore
    // For the pull-to-sync gesture (#334): a pull kicks a manual strap history offload via ble.syncNow().
    // Observe BLEManager, NOT AppModel — AppModel @Publishes `bpm` on the ~1 Hz HR tick, so observing it
    // would re-render all of Today every second (the exact churn the LiveState leaves isolate). BLEManager
    // only publishes connect/discovery state, never HR. Injected at the app roots beside .environmentObject(model).
    @EnvironmentObject var ble: BLEManager
    /// The bell's backing store — already injected as an `@EnvironmentObject` at both app roots
    /// alongside the other stores; this view just wasn't declaring it yet.
    @EnvironmentObject var updateStore: UpdateStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Low Power Mode poses the sky still too — the behaviour the comment on the sky branch below
    /// has always described. There is no environment key for it, hence the shared monitor.
    /// Low Power Mode — and the in-app "Reduce motion in NOOP" toggle — pose the sky still too, the
    /// behaviour the comment on the sky branch below has always described. Neither has a SwiftUI
    /// environment key, hence the shared monitor.
    @ObservedObject private var motion = NoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }

    /// Shared with the real Today's card-customise editor so the two stay in sync.
    @AppStorage(DashboardCardPrefs.selectionKey) private var dashboardCardsRaw = ""
    /// #today-hosted-cards: the ordered Trends/Sleep cards the user has hosted in Today. Empty by default
    /// (opt-in); rendered by the `.addedCards` section. Shared @AppStorage key with Android.
    @AppStorage(HostedCardPrefs.selectionKey) private var hostedCardsRaw = ""
    /// #989 parity with classic Today + Android: the hydration card is opt-in twice over — the feature
    /// toggle AND an explicit add in CUSTOMISE. Liquid filtered on neither, so a user who added the card
    /// and later switched the feature off kept a permanently-blank row.
    @AppStorage(HydrationStore.enabledKey) private var hydrationEnabled = false
    /// Today's hydration total + goal (ml), resolved in `load()`. nil → the card shows "—".
    @State private var hydrationTotalML: Double?
    @State private var hydrationGoalML: Int?

    // async-loaded via the confirmed Repository accessors
    @State private var restScore: Double?          // sleep_performance, day-keyed
    /// Input providers for the three scores, keyed by recovery / strain / sleep_performance.
    @State private var heroProviderByMetric: [String: ScoreInputProvider] = [:]
    @State private var stress: Double?             // StressModel(...).score, 0–3
    @State private var fitnessAge: Double?         // exploreSeries("fitness_age").last
    @State private var vo2max: Double?             // exploreSeries("vo2max_est").last (#1391)
    @State private var vitality: Double?           // exploreSeries("vitality").last
    // Queue 11a: day-keyed "spo2_candidate" metricSeries (WHOOP `spo2_candidate_82` or Oura
    // ceiling@100 `0x6F`, device-conditional — see `IntelligenceEngine`). Empty when the
    // experimental toggle is OFF (the engine writes nothing) or the owner has no in-band reading.
    // Read unconditionally like the classic TodayView's `spo2CandidateSpark` — always empty when
    // the toggle is off, so no separate gate is needed at fetch time.
    @State private var spo2CandidateByDay: [String: Double] = [:]
    @State private var stepsEst: Double?           // steps_est, day-keyed to the selected day (fallback)
    @State private var importedStepsDay: Int?      // Apple Health steps for the selected day (middle tier)
    /// Canonical energy summaries keyed by local day. Both the full-width Energy card and the compact
    /// Calories tile read this same map, so choosing one or both in CUSTOMISE never changes the number.
    @State private var energySummariesByDay: [String: DailyEnergySummary] = [:]
    /// The Weight tile's resolved value and which tier it came from, or nil before the first `load()`.
    /// Was a permanent hardcoded "—" placeholder before — `WeightSeries.displayWeight` gives the same
    /// trend → last measurement → profile fallback classic/Heute use.
    @State private var resolvedWeightKg: (kg: Double, tier: WeightDisplayTier)?
    @State private var hrValues: [Double] = []     // hrBuckets since midnight → 5-min means
    /// The bucket START time for each `hrValues` entry, index-aligned. Kept as its own array rather
    /// than derived (midnight + i·5min) because `hrBuckets` returns only buckets that HAVE data —
    /// a strap-off gap shifts every later index, so a derived clock would misdate the scrub readout.
    @State private var hrTimes: [Date] = []
    @State private var workouts: [WorkoutRow] = [] // newest-first
    /// #today-hosted-cards: the shared SleepModel that backs every SleepModel-derived hosted sleep card
    /// (Stages vs typical today; more to follow). Built ONCE in `load()` from the SAME inputs the Sleep tab
    /// uses (`SleepModel.build`), and only when a sleep-origin card is actually hosted — so a Today with no
    /// hosted sleep card pays none of the extra Repository work. nil until (and unless) it's built.
    @State private var hostedSleepModel: SleepModel? = nil

    /// Wraps a tapped row so `.sheet(item:)` can present its detail (`WorkoutRow` isn't `Identifiable`) —
    /// mirrors `WorkoutsView.WorkoutDetailTarget` exactly.
    private struct WorkoutDetailTarget: Identifiable {
        let row: WorkoutRow
        let id = UUID()
    }
    /// A workout tapped in `lastWorkoutsSection`, presented directly as its own detail sheet — NOT via
    /// `TabRoute.workoutDetail`, which resolves to the full Workouts overview screen first and only then
    /// auto-opens the detail on top of it. The full `WorkoutRow` is already in hand at the tap site.
    @State private var workoutDetailTarget: WorkoutDetailTarget?

    // sheets / expanders
    @State private var guideSection: ScoreSection?
    @State private var customizationDestination: TodayCustomizationDestination?
    @State private var showSettings = false
    @State private var synthesisExpanded = false

    // MARK: Momentum (#momentum)
    // The SAME `@AppStorage` keys the classic Today screen uses. One wearer, one card: switching Today
    // variants must not restart the dwell or resurrect a message hidden an hour ago.
    @AppStorage("momentum.lastKind") private var momentumLastKind = ""
    @AppStorage("momentum.lastAt") private var momentumLastAt: Double = 0
    @AppStorage("momentum.snoozed") private var momentumSnoozedRaw = ""
    @AppStorage("momentum.stepGoal") private var momentumStepGoal = 0
    @State private var momentumFeed: [MomentumMessage] = []
    @State private var showMomentumMore = false
    @State private var showLiveSession = false
    @State private var showUpdatesInbox = false
    /// Coach: the AI coach engine (injected at the app root) and the full-screen chat presentation. The
    /// prominent Today entries open the redesigned Coach chat directly, so it isn't buried under More.
    /// Each entry point (banner section, header icon) is its own independent toggle — see `CoachEntryPrefs`.
    @EnvironmentObject private var coach: AICoachEngine
    /// The coach's identity (name/avatar/tone) — observed so the banner's name/photo updates live, same
    /// as classic Today's `CoachTodayRow`.
    @ObservedObject private var identityStore = CoachIdentityStore.shared
    @State private var showCoach = false
    @State private var showPlan = false
    @State private var showGoalJourney = false
    /// The full-width coach banner, rendered as the reorderable `.coach` section (`TodaySection`).
    @AppStorage(CoachEntryPrefs.bannerKey) private var coachBannerEnabled = true
    /// The compact avatar/sparkle button in the header icon cluster (see `scene`).
    @AppStorage(CoachEntryPrefs.headerIconKey) private var coachHeaderIconEnabled = true
    /// Master switch (#R7): hides every Coach entry point when the coach UI is turned off.
    @AppStorage(CoachEntryPrefs.uiEnabledKey) private var coachUIEnabled = true
    @AppStorage(CoachFeaturePrefs.enabledKey) private var coachFeatureEnabled = false
    /// False renders the generic sparkle disc instead of the coach's own avatar on the banner/header entries.
    @AppStorage(CoachEntryPrefs.todayAvatarKey) private var todayAvatar = true
    /// The breath switch (Settings → Appearance) — shared with the classic row's avatar.
    @AppStorage(CoachTilePrefs.breathingKey) private var coachBreathingEnabled = true

    /// Live Sessions (silent guardian) beta gate — the SAME key the Settings toggle writes. Default ON
    /// (the entry is BETA-labelled in-UI); off removes the Start-session control entirely.
    @AppStorage(LiveSessionPrefs.betaKey) private var liveSessionsBeta = true
    // #today-layout: the user-chosen section order, persisted under the "today.sectionOrder" key. Order and
    // visibility are both edited in `TodayCustomizationSheet` (#940); every section always renders (decode
    // inserts a missing one at its default spot) unless it is in the explicit hidden set.
    @AppStorage(TodayLayoutPrefs.orderKey) private var sectionOrderRaw = ""
    @AppStorage(TodayLayoutPrefs.hiddenKey) private var hiddenSectionsRaw = ""
    private var sectionOrder: [TodaySection] {
        TodayLayoutPrefs.visibleOrder(orderRaw: sectionOrderRaw, hiddenRaw: hiddenSectionsRaw)
    }
    // #430 parity: the Key-Metrics grid honours the SAME editor selection/order + Detailed-tiles switch as
    // Android (byte-identical @AppStorage keys). `kSparks` holds the trailing-30-day series the detailed
    // tiles graph (keyed by metric-catalog key), filled by the loader alongside everything else.
    @AppStorage(KeyMetricPrefs.layoutKey) private var keyMetricsRaw = ""
    @AppStorage("today.keyMetricsDetailed") private var keyMetricsDetailed = false
    /// The detailed graphs' trailing window — 1 week / 2 weeks / 1 month (shared key with Android). The
    /// loader banks a day-keyed 30-day superset; render filters down, so a window change applies instantly.
    @AppStorage("today.keyMetricsWindowDays") private var keyMetricsWindowDays = 14
    /// Tiles per row (2 or 3; 3 = the original layout). Set on the Key Metrics page of the customization sheet.
    @AppStorage(KeyMetricPrefs.columnsKey) private var keyMetricsColumnsRaw = 3
    private var keyMetricsColumns: Int {
        dynamicTypeSize.isAccessibilitySize ? 1 : KeyMetricPrefs.columns(keyMetricsColumnsRaw)
    }
    @State private var kSparks: [String: [(String, Double)]] = [:]
    private var enabledKeyMetrics: [KeyMetric] { KeyMetricPrefs.decodeEnabled(keyMetricsRaw) }

    // day navigation (0 = today, 1 = yesterday, …)
    @State private var selectedDayOffset = 0
    @State private var showDayPicker = false
    /// Manual activity status (sick/injured/onBreak/active), owned here and threaded to the Synthesis
    /// card's header chip — same pattern as `HeuteRedesignView.status`.
    @State private var status = ActivityStatusStore.load()
    /// The rotating one-word "this is tappable / swipeable" hint under the headline; nil shows the date.
    /// Same two words and cadence the classic Today uses, so the affordance is learned once.
    @State private var dayNavHint: String? = nil
    private static let dayNavHints = ["Swipe", "Tap"]

    // PERF: the body was rescanning repo.days (599 days) ~23× per pass for displayDay and ~3× for
    // readiness on EVERY re-render (every HR notify, every canvas frame that invalidates, every scroll).
    // Resolve both ONCE per data/day change in load() and read the cache in body (O(1)).
    @State private var cachedDisplayDay: DailyMetric?
    @State private var cachedReadiness: ReadinessEngine.Readiness?
    /// The recovery-INDEPENDENT prior-day vitals carry (HRV / RHR / respiratory), resolved ONCE in load()
    /// alongside cachedDisplayDay. Fixes the v8 rollover blank: after 04:00, before tonight's sleep scores,
    /// today's row has no vitals yet, so these fall back to the last night that recorded them. Never
    /// resolved in body — body rescans repo.days ~23× per pass, and this cache keeps that read O(1).
    @State private var cachedVitalsDay: DailyMetric?
    /// PER-FIELD carries for the two vitals whose predicate `cachedVitalsDay` does NOT check. The engine
    /// writes `spo2Pct` / `skinTempDevC` as nil on computed "-noop" rows, so the whole-row carry above
    /// lands on a row with an empty field and the card reads "–" even though a real reading exists a few
    /// nights back. Twins of classic Today's `lastSpo2Day` / `lastSkinTempDay` (and Android's
    /// `lastSpo2Row` / `lastSkinTempRow`); resolved ONCE in load() like every other O(days) scan here.
    @State private var cachedSpo2Day: DailyMetric?
    @State private var cachedSkinTempDay: DailyMetric?
    @State private var cachedRespDay: DailyMetric?
    /// The Charge hero's resolved state (#543 carry + the honest label), resolved ONCE in load() alongside
    /// the other caches. It composes `TodayView.lastScoredRecoveryDay`, which is O(days) — exactly the scan
    /// this cache exists to keep out of body. Never resolved in body.
    /// Today's in-progress Effort (#402), re-scored from the raw HR stream because the stored daily row
    /// lags. Read LAST in load() (see the assignment) so the hero paints on the stored row first and this
    /// only ever raises it — `StrainScorer.effectiveEffort` takes the max, so it cannot flicker downward.
    /// nil on a navigated past day, which has no in-progress figure.
    @State private var liveTodayStrain: Double?
    @State private var cachedChargeDisplay: ChargeDisplay = .noData
    /// The last fully-scored prior recovery day, cached in load() so the Charge-breakdown sheet can read
    /// the same `chargeBreakdownRow` classic Today uses (today's own row, else the carried last-scored)
    /// without an O(days) scan in body. Mirrors `TodayView.lastScoredRecoveryDay`.
    @State private var cachedPriorScored: DailyMetric?
    /// The Charge-breakdown sheet, opened from the readiness pill (parity with classic TodayView's
    /// `showChargeBreakdown`): tapping "Push"/"Maintain"/"Rest" opens the full drivers + confidence
    /// breakdown, the same sheet the Charge-ring tap opens in classic.
    @State private var showChargeBreakdown = false
    /// Flips true once the first load() completes. Until then the hero gauges + sky render STATIC so the
    /// launch data-churn (refresh publish + BLE/HR notifies) isn't fighting 4 live canvases + CoreMotion.
    @State private var dataLoaded = false

    // Custom liquid pull-to-refresh: a vessel that FILLS as you drag, releases into a refresh (replaces
    // the system spinner). Driven by the scroll's top overscroll offset.
    @State private var pullY: CGFloat = 0
    @State private var refreshArmed = false
    @State private var refreshing = false
    @State private var pullHaptic = 0
    private let pullThreshold: CGFloat = 80

    /// Measured width of the trailing header-control cluster, feeding the day title's fade mask. Seeded
    /// with the design-system default so the first frame is not laid out against a reserve of zero.
    @State private var headerControlsWidth = NoopMetrics.headerControlReserveWidth

    /// Mock Vitality purple (#9b7bff) has no exact StrandPalette token in this theme.
    private let liquidPurple = Color(.sRGB, red: 0x9b / 255, green: 0x7b / 255, blue: 0xff / 255, opacity: 1)
    /// The liquid heart pink (matches LiquidThread's default + the mockup #ff6b81).
    private let liquidHeart = Color(.sRGB, red: 1, green: 107 / 255, blue: 129 / 255, opacity: 1)
    /// Hero card fill: a translucent near-black so it floats over the sky (mock rgba(13,14,20,.78)).
    private let heroFill = Color(.sRGB, red: 13 / 255, green: 14 / 255, blue: 20 / 255, opacity: 0.80)
    /// Slightly tighter than the app-wide 30pt hero radius. Liquid Today's three 96pt vessels already
    /// provide the soft focal shape, so 28pt keeps the surrounding card visually proportional.
    private let liquidHeroRadius: CGFloat = 28
    /// "Card transparency" (0–100, default 100): fades every liquid card surface here — the hero, the
    /// session-start row, the metric tiles and the `card` helper — in lockstep with the frosted cards.
    /// Content sits above the surface so it stays readable. Mirrors Kotlin `NoopPrefs.cardOpacityPercent`.
    @AppStorage(CardAppearancePrefs.opacityKey) private var cardOpacityPercent = CardAppearancePrefs.defaultPercent
    private var cardOpacity: Double {
        reduceTransparency ? 1 : max(0, min(1, Double(cardOpacityPercent) / 100))
    }
    /// "Sky behind cards" (default OFF): extend the day-cycle sky behind the WHOLE scroll so the
    /// Card-transparency slider reveals it under every card. User-toggleable. Mirrors Kotlin `NoopPrefs.skyBehindCards`.
    @AppStorage(SkyBehindCardsPrefs.enabledKey) private var skyBehindCards = false
    /// Day-cycle scene backdrop (#698). Default OFF. When on, the liquid Today adds the moving sky; off
    /// (the default) keeps the plain dark canvas — parity with the classic TodayView, which already
    /// honours this pref. Mirrors Kotlin `NoopPrefs.showDayCycleBackground`.
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = false
    /// Custom background image (#custom-background): when active it overrides the sky in the backdrop below.
    @ObservedObject private var backgroundStore = BackgroundImageStore.shared

    // MARK: - Day navigation (ported from classic Today: swipe + calendar, day-keyed reads)

    /// The logical day the selector resolves to (offset 0 = today's logical day, rolls at 04:00).
    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }
    /// The day key the day-scoped read-outs key on. At offset 0 follows repo.today?.day.
    private var selectedDayKey: String {
        if selectedDayOffset == 0, let todayKey = repo.today?.day { return todayKey }
        return Repository.localDayKey(selectedLogicalDay)
    }
    /// The DailyMetric shown for the selected day — read from the cache resolved in load() (was an
    /// O(days) `.last(where:)` scan referenced ~23× per body pass; now O(1)).
    private var displayDay: DailyMetric? { cachedDisplayDay }
    /// The prior-day vitals carry (see `cachedVitalsDay`), read O(1) from the cache. Non-nil only at
    /// offset 0 (today); a navigated past day carries nothing (its own row is the whole story).
    private var vitalsDay: DailyMetric? { cachedVitalsDay }
    /// The per-field SpO₂ / skin-temperature carries (see the caches), read O(1). Like `vitalsDay`,
    /// non-nil only at offset 0 — a navigated past day carries nothing.
    private var spo2Day: DailyMetric? { cachedSpo2Day }
    private var skinTempDay: DailyMetric? { cachedSkinTempDay }
    /// The prior-day RESPIRATORY carry (#1331): staleness-bounded, so a recent missed night reads the last
    /// real value while a weeks-old one honestly shows "No Data". Non-nil only at offset 0.
    private var respDay: DailyMetric? { cachedRespDay }
    /// The Charge hero's resolved state (see `cachedChargeDisplay`), read O(1) from the cache.
    private var chargeDisplay: ChargeDisplay { cachedChargeDisplay }
    /// THE Effort figure for this screen (#1001): the live in-progress score floored at the stored row, so
    /// the hero, the zero-note and the Key Metrics tile cannot show three different numbers — and so this
    /// screen agrees with classic Today, which has resolved Effort this way all along. A past day has no
    /// live figure and reads its stored row verbatim.
    private var effortValue: Double? {
        StrainScorer.effectiveEffort(live: selectedDayOffset == 0 ? liveTodayStrain : nil,
                                     stored: displayDay?.strain)
    }
    /// The last fully-scored prior recovery day (see `cachedPriorScored`), read O(1) from the cache.
    /// Used by `chargeBreakdownRow` so the breakdown sheet reads the same carried row the ring shows.
    private var priorScoredDay: DailyMetric? { cachedPriorScored }
    /// The row the Charge-breakdown sheet reads: today's own row, else the carried last-scored (#543).
    /// Mirrors `TodayView.chargeBreakdownRow` so both Today screens attribute the same night.
    private var chargeBreakdownRow: DailyMetric? { priorScoredDay ?? displayDay }
    /// Calibration nights gathered so far, or nil. Extracted from `chargeDisplay` (`.calibrating(nights:)`)
    /// so the sheet's countdown reads the same count the hero pill shows — no second scan.
    private var recoveryCalibration: Int? {
        guard case .calibrating(let nights) = chargeDisplay else { return nil }
        return nights
    }
    /// The Charge breakdown (drivers + confidence), computed from the same row + rest-score the ring
    /// reads. Uses the shared pure `ChargeBreakdownFormat.compute` so classic Today and Liquid can't drift.
    private func chargeBreakdown() -> (drivers: [ChargeDriver], confidence: ScoreConfidence)? {
        ChargeBreakdownFormat.compute(row: chargeBreakdownRow, days: repo.days, restScore: restScore)
    }
    /// The night's relative skin-temp marker, surfaced verbatim from `RecoveryScorer.skinTempRelative`.
    private var chargeSkinTempRel: SkinTempRelative? {
        RecoveryScorer.skinTempRelative(deviationC: chargeBreakdownRow?.skinTempDevC)
    }
    /// Readiness-level → colour, mirroring `TodayView.readinessColor` so the hero pill matches classic.
    private func readinessColor(_ l: ReadinessEngine.Level) -> Color {
        switch l {
        case .primed:       return StrandPalette.accent
        case .balanced:     return StrandPalette.statusPositive
        case .strained:     return StrandPalette.statusWarning
        case .rundown:      return StrandPalette.metricRose
        case .insufficient: return StrandPalette.textTertiary
        }
    }

    /// The actual O(days) resolution. Offset 0 prefers live repo.today; past offsets look up. Run ONCE
    /// per data/day change from load(), never from body.
    private func resolveDisplayDay() -> DailyMetric? {
        if selectedDayOffset == 0 {
            return repo.today ?? repo.days.last(where: { $0.day == selectedDayKey })
        }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }
    /// How far back navigation can go (whole days from the earliest banked day to today).
    private var earliestDayOffset: Int {
        Self.maxDayOffset(earliestDayKey: repo.freshness.earliestDay,
                          todayKey: Repository.logicalDayKey(Date()))
    }
    /// The big header title: Today / Yesterday / weekday for older days.
    private var dayTitle: String {
        switch selectedDayOffset {
        // #1013: these must localize — the header showed English "Today"/"Yesterday"/weekday even when the
        // system UI (tab bar etc.) was another language. "Today"/"Yesterday" go through String(localized:)
        // (matching the classic TodayView.dayNavLabel), and the weekday name is formatted in the user's
        // locale, not the en_US_POSIX one used only for machine day-keys.
        case 0: return String(localized: "Today")
        case 1: return String(localized: "Yesterday")
        default:
            return selectedLogicalDay.formatted(.dateTime.weekday(.wide).locale(AppLanguage.activeLocale))
        }
    }
    /// Two-way binding for the graphical calendar: reads the shown day, writes back an offset.
    private var dayPickerBinding: Binding<Date> {
        Binding(
            get: { selectedLogicalDay },
            set: { newValue in
                selectedDayOffset = Self.pickedDayOffset(pickedDate: newValue,
                                                         anchorLogicalDay: Repository.logicalDay(Date()))
                showDayPicker = false
            }
        )
    }
    /// Horizontal swipe between days (left = older, right = newer), clamped to [today, earliest].
    ///
    /// The HR thread scrubs horizontally too, and this gesture is attached with `simultaneousGesture`
    /// on the scroll view — so both recognisers see the same finger and a scrub would otherwise also
    /// flip the day. `hrScrubbing` / `hrScrubEndedAt` give the thread horizontal dominance while it
    /// owns the touch: whichever `onEnded` runs first, the other is suppressed (the flag is still set
    /// if this one wins the race, the timestamp catches it if the thread's does). Both are written
    /// SYNCHRONOUSLY from the thread's gesture callback, not via `onChange`, so there is no render
    /// pass in between where the guard could read stale state. Swipes anywhere else are untouched.
    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !hrScrubbing, Date().timeIntervalSince(hrScrubEndedAt) > 0.4 else { return }
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50 else { return }
                let delta = dx < 0 ? 1 : -1
                let next = Self.clampedDayOffset(current: selectedDayOffset, delta: delta,
                                                 maxOffset: earliestDayOffset)
                guard next != selectedDayOffset else { return }
                withAnimation(StrandMotion.interactive) { selectedDayOffset = next }
            }
    }

    /// True while a finger (or the pointer) is scrubbing the HR thread — see `daySwipeGesture`.
    @State private var hrScrubbing = false
    /// When the last scrub let go. Guards the tail of the same gesture, since the day-swipe's `onEnded`
    /// and the thread's fire in an unspecified order on lift.
    @State private var hrScrubEndedAt = Date.distantPast

    static func clampedDayOffset(current: Int, delta: Int, maxOffset: Int) -> Int {
        min(max(0, maxOffset), max(0, current + delta))
    }
    static func maxDayOffset(earliestDayKey: String?, todayKey: String) -> Int {
        guard let earliestKey = earliestDayKey,
              let earliest = dayKeyParser.date(from: earliestKey),
              let today = dayKeyParser.date(from: todayKey) else { return 0 }
        let gap = Calendar.current.dateComponents([.day],
                                                  from: Calendar.current.startOfDay(for: earliest),
                                                  to: Calendar.current.startOfDay(for: today)).day ?? 0
        return max(0, gap)
    }
    static func pickedDayOffset(pickedDate: Date, anchorLogicalDay: Date) -> Int {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: pickedDate),
                                      to: cal.startOfDay(for: anchorLogicalDay)).day ?? 0
        return max(0, days)
    }
    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Scroll-to-top on an at-root Today re-tap (#198 follow-up); default 0 so macOS/other contexts stay inert.
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal
    private static let topAnchorID = "liquidToday.top"

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 0) {
                // Zero-height scroll-to-top anchor (#198 follow-up): the target for an at-root Today re-tap.
                Color.clear.frame(height: 0).id(Self.topAnchorID)
                // Scroll-offset probe at the very top (before padding), so its minY in the scroll's
                // coordinate space reads the top OVERSCROLL: ~0 at rest, positive as you pull down.
                GeometryReader { g in
                    Color.clear.preference(key: PullOffsetKey.self,
                                           value: g.frame(in: .named(Self.pullSpace)).minY)
                }
                .frame(height: 0)

                liquidRefreshIndicator   // grows in the revealed space; a vessel filling with the pull

                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    scene
                    // The coach entry is NOT here any more: a full-width row between the wordmark and the
                    // scores both dominated the screen and pushed Charge/Effort/Rest down the page. It is now
                    // a narrow tile beside the Synthesis card (`synthesisSection`), so the hero is the first
                    // thing under the wordmark — the two cards below self-hide in the normal case.
                    // The strain/illness early-warning banner, dropped in the liquid Home rewrite. Liquid is
                    // the DEFAULT Today on both platforms (RootTabView.swift's liquidTodayEnabled = true,
                    // RootView.swift likewise), so while this was unmounted a RAISED health alert had no
                    // home-screen surface at all: it survived only as one push at the moment it fired
                    // (IllnessNotifier.post) and as HeadsUpCard two taps deep in More → Health. Pinned ABOVE
                    // the reorderable block — the same position classic TodayView uses on both platforms and
                    // the same one Android pins it to (TodayScreen.kt) — so a warning cannot be reordered
                    // below the fold. Renders nothing when model.healthAlert is nil.
                    HealthAlertBanner()
                    // #105: the live "workout in progress" card, dropped in the liquid Home rewrite. Restored
                    // here as the SAME leaf the classic TodayView renders (and Android's WorkoutInProgressCard),
                    // pinned above the reorderable block so an active manual workout is immediately visible
                    // and taps straight through to Live. Renders nothing when no workout is active.
                    ActiveWorkoutIndicatorSection()
                    MorningSuggestionCard(showPlan: $showPlan)
                    // #today-layout: every Today section — the Charge/Effort/Rest hero and Start-session
                    // included — renders in the user's saved order. Reorder and hide in the customization
                    // sheet (the header's slider button); `sectionOrder` is already filtered to the visible
                    // set, and a hidden section keeps its slot in the stored order so unhiding restores its
                    // position. A gated-off Start-session renders nothing and keeps its slot too.
                    ForEach(sectionOrder) { section in
                        // UX: major sections (hero, synthesis, keyMetrics, recoveryVitals) get extra top
                        // breathing room so the screen reads in clear groups; minor sections sit tighter.
                        // The base VStack spacing is NoopMetrics.gap (12); major sections add space2 (8)
                        // for a total of ~20pt — graduated hierarchy without a cramped uniform density.
                        Group {
                        switch section {
                        // The full-width Coach banner — the reorderable twin of classic Today's
                        // `CoachTodayRow`, independent of the compact header-icon entry (see `scene`).
                        case .coach:
                            if coachFeatureEnabled, coachUIEnabled, coachBannerEnabled { coachBanner }
                        case .hero: heroCard
                        // Live Sessions (silent guardian) is an OPTIONAL, strap-dependent beta, so it no
                        // longer holds a prominent card between the scores and Synthesis. On iOS it lives in
                        // the "+" quick-action sheet (`QuickActionSheet`, RootTabView); macOS has no such
                        // sheet — its "+" sets `router.requestQuickActions()`, which only the iOS tab shell
                        // consumes — so the row stays there rather than stranding the feature. The enum case
                        // is deliberately KEPT: `today.sectionOrder` is a byte-identical cross-platform
                        // string and Android still ships the section.
                        case .liveSession:
                            #if os(macOS)
                            if liveSessionsBeta { liveSessionStartRow }
                            #else
                            EmptyView()
                            #endif
                        case .synthesis: synthesisSection
                        case .goals:
                            if selectedDayOffset == 0 { GoalsTodaySection(showGoalJourney: $showGoalJourney) }
                        case .keyMetrics: keyMetricsSection
                        case .energy:
                            if selectedDayOffset == 0, let energySummary = selectedEnergySummary {
                                NavigationLink(value: TabRoute.energy) {
                                    EnergyCard(summary: energySummary)
                                }
                                .buttonStyle(.plain)
                            }
                        case .workouts: lastWorkoutsSection
                        case .heartRate: heartRateSection
                        case .recoveryVitals: recoveryVitalsSection
                        case .yourCards: yourCardsSection
                        case .menstrualCycle:
                            if selectedDayOffset == 0 { MenstrualCycleHomeCard() }
                        // #656: the persistent journal widget (last-7-days strip + tap-through). Now a
                        // reorderable section like the others — the Arrange sheet moves it. Today only;
                        // the card self-hides when the reminder toggle is off (an empty branch renders
                        // nothing yet keeps its slot). Twin of Android TodayScreen's JOURNAL arm.
                        case .journal: if selectedDayOffset == 0 { JournalReminderCard() }
                        // Data Sources is now a reorderable, hideable section (hidden by default, §4) rather
                        // than a fixed card pinned to the bottom.
                        case .dataSources: dataSourcesSection
                        // #today-hosted-cards: cards the user pulled in from the Trends/Sleep tabs, in the
                        // order they arranged. Empty (renders nothing) until they add one in Customise.
                        // Today-only, matching Android's addedCards section gate + the classic TodayView.
                        case .addedCards: if selectedDayOffset == 0 { hostedCardsSection }
                        }
                        }
                        .padding(.top, section.isMajorSection ? NoopMetrics.space1 : 0)
                    }
                    // The committed "next up" session sits BELOW the metric sections on purpose: once
                    // accepted it's an ambient reminder, not a demand for the top of the screen. It draws
                    // attention on its own terms as its time nears (colour + breathe, see PlanTodayCard).
                    PlanTodayCard(showPlan: $showPlan)
                    // Opt-in "looks like a workout?" suggestion, dropped in the liquid Home rewrite. Its
                    // Settings toggle (PuffinExperiment.autoDetectWorkoutsKey) had no visible effect on the
                    // DEFAULT screen: the card's only mount was classic TodayView, so a user could switch
                    // auto-detect on and never be shown a single suggestion. Self-gates on the toggle AND
                    // on the detector finding an unsaved, un-dismissed window, so it renders nothing by
                    // default. Upstream also re-mounts `dataSourcesSection` here; this fork does not —
                    // it is already rendered through the reorderable card block above (`case .dataSources`),
                    // so a second mount would show the section twice.
                    AutoWorkoutCard()
                    Color.clear.frame(height: 90) // floating tab-bar clearance
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.top, 30) // sit the title lower into the sky, not jammed under the status bar
            }
            #if os(macOS)
            // Keep the phone-shaped column readable + centred on the wide mac detail pane. The sky is a
            // ScrollView background (full-bleed), so constraining the content column here doesn't touch it.
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            #endif
        }
        .coordinateSpace(name: Self.pullSpace)
        #if os(iOS)
        // #697 parity: ScreenScaffold already stops a vertical scroll from drifting/bouncing the
        // screen left-right on every other tab. Liquid Today runs its own ScrollView (not
        // ScreenScaffold) and never got the fix, so it was the one screen left with the spurious
        // horizontal rubber-band/swipe. `.basedOnSize` only permits horizontal bounce when content
        // genuinely overflows the width (it does not here, the column is width-capped), so this
        // brings Today's scroll behaviour in line with the rest of the app without touching the
        // vertical pull-to-refresh gesture above.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        .onPreferenceChange(PullOffsetKey.self) { handlePull($0) }
        // The sky is a FIXED full-bleed backdrop drawn behind the scroll content, edge-to-edge under the
        // status bar. A ScrollView background does not scroll with the content, so pulling down never
        // moves the sky (the exact behaviour the scaffold uses on the classic Today).
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                StrandPalette.surfaceBase
                // Custom background image (#custom-background): a picked photo OVERRIDES the sky, filling
                // the whole backdrop (same cached image as every other tab, so it's seamless).
                if backgroundStore.isActive {
                    BackgroundImageBackdrop()
                }
                // Day-cycle scene (#698): the sky only paints when the toggle is ON AND no custom image is
                // active; off = the plain surfaceBase canvas above (parity with Android + classic TodayView).
                else if showDayCycleBackground {
                    // Reduce-motion (and low-power) users get the same sky posed still — no twinkle/breath.
                    // Also static until the first data load settles, so launch isn't fighting a live sky too.
                    // "Sky behind cards" (opt-in): fill the whole backdrop with a softer settle so the sky
                    // reads under every card, instead of the default 340 top band that dissolves to canvas.
                    Group {
                        if poseStill || !dataLoaded { LiquidSkyStatic(hour: liveHour, settleStrength: skyBehindCards ? 0.78 : 1) }
                        else { LiquidSky(hour: liveHour, settleStrength: skyBehindCards ? 0.78 : 1) }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: skyBehindCards ? nil : 340, alignment: .top)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .ignoresSafeArea()
        }
        // Swipe left/right to change DAYS (WHOOP-style). Tab-swipe is disabled on Today in RootTabView so
        // this owns the horizontal gesture here.
        .simultaneousGesture(daySwipeGesture)
        // A light tick when the day changes (swipe or calendar pick) — the WHOOP-style day nav should
        // feel physical ("every tiny little thing").
        .liquidSelectionHaptic(trigger: selectedDayOffset)
        // A firm tick when the pull passes the release threshold (the custom liquid refresh).
        .liquidMediumHaptic(trigger: pullHaptic)
        // hydrationSeq joins the id so logging a drink re-reads the card immediately, the same trigger set
        // classic TodayView's reloadHydration() uses.
        .task(id: "\(repo.refreshSeq)-\(selectedDayOffset)-\(repo.hydrationSeq)-\(hydrationEnabled)") { await load() }
        // Momentum is resolved here, not in the body — see `TodayView.MomentumKey`.
        .task(id: momentumKey) { rebuildMomentum() }
        // Honour a one-shot "open Live Session" request (the coach chat's action chip, or any future
        // deep-link) — fires on the flag itself, not just on appear, so it still works when Today is
        // ALREADY the active tab and RootTabView's own tab switch is a no-op. Tab roots stay alive across
        // switches, so this reacts regardless of which tab is currently visible.
        .onChangeCompat(of: router.presentLiveSession) { present in
            guard present else { return }
            consumeLiveSessionRequest()
        }
        .sheet(item: $guideSection) { section in
            NavigationStack { ScoringGuideView(initialSection: section, onClose: { guideSection = nil }) }
        }
        // A tapped workout from `lastWorkoutsSection`, opened directly — mirrors WorkoutsView's own
        // `WorkoutDetailTarget` sheet exactly, so the detail looks identical wherever it's opened from.
        .sheet(item: $workoutDetailTarget) { target in
            NavigationStack { WorkoutDetailView(row: target.row).environmentObject(repo) }
                #if os(iOS)
                .noopSheetPresentation(largeFirst: true)
                #else
                .frame(width: 620, height: 720)
                #endif
        }
        // Every Today layout/card affordance presents the same draft-based editor (#940).
        .sheet(item: $customizationDestination) { destination in
            TodayCustomizationSheet(
                initialDestination: destination,
                sectionOrderRaw: $sectionOrderRaw,
                hiddenSectionsRaw: $hiddenSectionsRaw,
                keyMetricsRaw: $keyMetricsRaw,
                keyMetricsDetailed: $keyMetricsDetailed,
                keyMetricsWindowDays: $keyMetricsWindowDays,
                keyMetricsColumns: $keyMetricsColumnsRaw,
                dashboardCardsRaw: $dashboardCardsRaw,
                hostedCardsRaw: $hostedCardsRaw
            )
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .background(StrandPalette.surfaceBase.ignoresSafeArea())
                    .liquidSheetDoneChrome { showSettings = false }
            }
        }
        // Live Session (silent guardian, beta): the in-session screen owns the whole display — full
        // screen on iOS (nothing should compete with the ring mid-workout), a sheet on macOS where
        // fullScreenCover doesn't exist.
        .liveSessionCover(isPresented: $showLiveSession)
        .coachCover(isPresented: $showCoach, coach: coach)
        // The plan book, opened from PlanTodayCard when a committed session has a time coming up.
        .sheet(isPresented: $showPlan) { CoachPlanView().environmentObject(coach) }
        // Wrapped in a NavigationStack, exactly like the chat's goal shortcut (CoachView). Without one
        // the screen has no navigation host, and `CoachGoalJourneyView`'s guided setup — deliberately a
        // PUSH rather than a sheet, so the wizard can't reset itself mid-flow — had nowhere to go: the
        // "Set up with a few questions" button did nothing at all when opened from Today.
        .sheet(isPresented: $showGoalJourney) {
            NavigationStack {
                CoachGoalJourneyScreen()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showGoalJourney = false }
                        }
                    }
            }
            .environmentObject(coach)
        }
        // The bell — same store, same inbox, as the classic Today's (TodayView.swift).
        .sheet(isPresented: $showUpdatesInbox) {
            UpdatesInboxView(onClose: { showUpdatesInbox = false })
        }
        // The Charge-breakdown sheet — opened from the readiness hero pill (Maintain/Push/Rest), parity
        // with classic TodayView's `showChargeBreakdown`. Shows the drivers + confidence + calibration
        // countdown + the scoring-guide link, the same sheet the Charge-ring tap opens in classic.
        .sheet(isPresented: $showChargeBreakdown) { chargeBreakdownSheet }
        // The Momentum dashboard — the same feed at full size, same host shape as classic Today.
        .sheet(isPresented: $showMomentumMore) {
            NavigationStack {
                MomentumView(messages: momentumFeed, recentDays: repo.days,
                             onAction: { if $0 == .chargeBreakdown {
                                 showMomentumMore = false; showChargeBreakdown = true
                             } })
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showMomentumMore = false }
                        }
                    }
            }
            .environmentObject(repo)
        }
        #if os(macOS)
        // Hide the mac window toolbar's vibrant material so the full-bleed day-of-sky reads dark + edge-to-edge
        // at the top instead of the white scroll-under-titlebar wash.
        .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
        #if os(iOS)
        // Scroll-to-top on an at-root Today re-tap (#198 follow-up); iOS-only — the tab shell is the only driver.
        .onChange(of: scrollToTopSignal) { _, _ in
            withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(Self.topAnchorID, anchor: .top) }
        }
        #endif
        }
    }

    // MARK: - Liquid pull-to-refresh

    static let pullSpace = "liqTodayScroll"

    /// Reserves the revealed space at the top and shows a vessel that fills with the pull, then sloshes
    /// while the refresh runs. A plain computed property (not a LiveState-isolated leaf) — it doesn't read
    /// LiveState itself, so it's cheap to re-evaluate as part of the main body. It hands the actual
    /// visibility decision to `LiquidRefreshIndicator` below, which DOES own LiveState.
    private var liquidRefreshIndicator: some View {
        LiquidRefreshIndicator(pullY: pullY, pullThreshold: pullThreshold, refreshing: refreshing,
                               liquidHeart: liquidHeart)
    }

    /// Arm the refresh once the pull passes the threshold; FIRE it when the finger releases (the pull
    /// springs back toward zero). Guarded so it can't double-fire or re-trigger mid-refresh.
    private func handlePull(_ y: CGFloat) {
        pullY = max(0, y)
        guard !refreshing else { return }
        // #1748 twin: gate the ARM, not the release. `syncNow()`'s own gate checks connected + bonded, and
        // `bonded` is set by the live-HR path for a 5/MG that has never completed a handshake — so the pull
        // was accepted and then declined in silence. `historyReady` is the client's OWN precondition, so
        // this cannot withhold a sync that would have run.
        //
        // On the ARM specifically: gating the RELEASE below would leave `refreshArmed` stuck true for the
        // rest of the gesture, since that branch is the only thing that clears it — a worse failure than
        // the silent one being fixed. Not arming also withholds the haptic, which is the honest signal
        // that the gesture is unavailable rather than unresponsive.
        if pullY >= pullThreshold, !refreshArmed, ble.state.historyReady {
            refreshArmed = true
            pullHaptic &+= 1
        }
        if refreshArmed, pullY < 6 {
            refreshArmed = false
            refreshing = true
            Task {
                // #334 (iOS twin of Android #426): a pull requests a fresh strap history offload, not just
                // a UI reload. syncNow() is internally gated (connected + bonded + not-already-backfilling),
                // so a pull while disconnected or mid-offload safely no-ops. The sync status chip owns the
                // ongoing offload progress; the pull spinner stays short (the reload below).
                ble.syncNow()
                await repo.refresh()
                await load()
                try? await Task.sleep(nanoseconds: 350_000_000)   // let the fill read as "done"
                withAnimation(.easeOut(duration: 0.25)) { refreshing = false }
            }
        }
    }

    // MARK: - Scene (sky title + controls + hero)

    private var scene: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Button { showDayPicker = true } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        // On TODAY the headline greets the user; a navigated past day falls back to the
                        // "Yesterday"/weekday title. A greeting over last Tuesday would be a false statement,
                        // and the relative word is the day-swipe's most visible signal — it has to come back
                        // the moment the shown day isn't today.
                        Text(headlineLine)
                            .font(StrandFont.rounded(24))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                            // A long name ("Good afternoon, Konstantin") must scale, not shove the icon
                            // cluster off the trailing edge on a 375pt phone.
                            .minimumScaleFactor(0.7)
                            .shadow(color: .black.opacity(0.4), radius: 10, y: 1)
                        // The date is the day-picker's trigger, so it needs to READ as tappable without a
                        // second control. Same affordance the classic Today uses (TodayView.dayNavHint): every
                        // ~10s it swaps for ~1.5s to a one-word accent hint, then returns to the date.
                        Text(dayNavHint ?? dateLine)
                            .font(StrandFont.caption)
                            .foregroundStyle(dayNavHint != nil ? StrandPalette.accent : StrandPalette.textSecondary)
                            .contentTransition(.opacity)
                            .shadow(color: .black.opacity(0.35), radius: 8, y: 1)
                    }
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(dayTitle). Tap to pick a day, swipe to change day.")
                // One async loop, cancelled with the view — no leaked timer. Mirrors the classic Today's.
                .task {
                    var i = 0
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        if Task.isCancelled { break }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            dayNavHint = Self.dayNavHints[i % Self.dayNavHints.count]
                        }
                        i += 1
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        withAnimation(.easeInOut(duration: 0.3)) { dayNavHint = nil }
                    }
                }
                .popover(isPresented: $showDayPicker) {
                    DatePicker("", selection: dayPickerBinding, in: ...Repository.logicalDay(Date()),
                               displayedComponents: [.date])
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(12)
                        .frame(minWidth: 320, minHeight: 360)
                        .liquidPopoverAdaptation()
                }
                // Long names fade beneath the trailing controls while an expanded transient control
                // participates in layout and pushes its preceding siblings left. The reserve is the
                // cluster's MEASURED width, not a constant: a constant is only ever right for the exact
                // set of controls it was written against, and this row has already gained one (Customize,
                // #1207) since. Measuring also means the fade tracks the sync capsule as it expands,
                // which is the push-left behaviour rather than a separate approximation of it.
                .headerTrailingControlFadeMask(reserving: headerControlsWidth)
                HStack(spacing: headerClusterSpacing) {
                    // (#R-header-coach): the Coach entry leads the trailing cluster as a compact
                    // avatar/sparkle button — the same spot it held before it was ever demoted to a
                    // full-width card. Sized off the shared control token so it stays flush with the
                    // profile picture and the sync indicator beside it.
                    if coachFeatureEnabled, coachUIEnabled, coachHeaderIconEnabled {
                        Button { showCoach = true } label: {
                            // The breath (#coach-breath): the corona behind the button is the only thing
                            // that still reads as "alive" at this size — the old tile's 3% scale swell
                            // would be under a point here. Applied to the GROUP, so it wraps the avatar
                            // and the sparkle fallback alike: turning the avatar off is a choice about
                            // the picture, not a reason to lose the pulse.
                            Group {
                                if todayAvatar {
                                    CoachAvatarView(size: NoopMetrics.compactControlSize)
                                        .frame(width: NoopMetrics.compactControlSize,
                                               height: NoopMetrics.compactControlSize)
                                } else {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(StrandPalette.textPrimary)
                                        .frame(width: NoopMetrics.compactControlSize,
                                               height: NoopMetrics.compactControlSize)
                                        .background(Circle().fill(StrandPalette.surfaceInset.opacity(0.6)))
                                }
                            }
                            .coachBreathHalo(active: CoachBreath.isActive(reduceMotion: reduceMotion,
                                                                          enabled: coachBreathingEnabled,
                                                                          motion: motion))
                        }
                        .buttonStyle(LiquidPressStyle())
                        .accessibilityLabel("Ask your Coach")
                        .accessibilityHint("Opens the AI coach chat.")
                    }
                    // Profile pic (the one set in Settings) → opens Settings, matching the classic Today.
                    Button { showSettings = true } label: {
                        Color.clear.frame(
                            width: NoopMetrics.compactControlSize,
                            height: NoopMetrics.compactControlSize
                        )
                    }
                    .nativeLiquidGlassHeaderButton()
                    .overlay {
                        GeometryReader { proxy in
                            let diameter = min(proxy.size.width, proxy.size.height)
                            ProfileAvatarView(imageData: profile.avatarImageData, size: diameter)
                                .frame(width: diameter, height: diameter)
                                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                        }
                        .allowsHitTesting(false)
                    }
                    .nativeLiquidGlassPhotoFinish()
                    .accessibilityLabel("Profile and settings")
                    LiquidAddButton()
                    LiquidBatteryButton()
                    LiquidUpdatesBellButton(showUpdatesInbox: $showUpdatesInbox)
                    // One entry point for section order/visibility and both nested card editors.
                    Button { customizationDestination = .today } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .frame(
                                width: NoopMetrics.compactControlSize,
                                height: NoopMetrics.compactControlSize
                            )
                    }
                    .nativeLiquidGlassHeaderButton()
                    .accessibilityLabel("Customize Today")
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: HeaderControlsWidthKey.self,
                            value: proxy.size.width
                        )
                    }
                )
                .zIndex(1)
            }
            .onPreferenceChange(HeaderControlsWidthKey.self) { measured in
                // Ignore sub-point churn so a rounding wobble cannot re-render the mask every frame.
                guard measured > 0, abs(measured - headerControlsWidth) > 0.5 else { return }
                headerControlsWidth = measured
            }
            // Subtle NOOP wordmark in the sky between header and hero. Perfectly centred (a letter row has
            // no trailing tracking gap the way `Text(...).tracking()` does), with a tap easter egg.
            // #today-layout: the hero + Start-session row moved OUT of the scene into the reorderable
            // section block below. The wordmark's bottom pad (10) + the section VStack's 12 spacing keeps
            // the default hero-under-wordmark gap at the original 22.
            LiquidWordmark()
                .padding(.top, 30)
                .padding(.bottom, 10)
        }
    }

    /// Consume `router.presentLiveSession`: opens the SAME cover the manual Start-session row does.
    /// Guarded on the beta toggle so a user who turned the feature off doesn't get it silently opened
    /// from the coach chat — the chip that raised this request is itself hidden when the toggle is off
    /// (see `CoachView.actionRow`), so reaching here with the toggle off would only happen for a stale
    /// request, and it stays a no-op rather than presenting a screen the user disabled.
    private func consumeLiveSessionRequest() {
        router.presentLiveSession = false
        guard liveSessionsBeta else { return }
        showLiveSession = true
    }

    /// One-tap Live Session start (silent guardian, beta) — sits directly under the hero scores, the
    /// Charge its band is gated on. Same translucent chrome as the hero card so it reads as part of the
    /// sky scene, quiet by design.
    private var liveSessionStartRow: some View {
        Button { showLiveSession = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.metricCyan)
                // Theme-aware session-start chrome (#1160 parity): NoopPanelSurface + normal text
                // tokens — light ink on Dark, dark ink on Light. (Was pinned-dark + on-dark tokens.)
                Text("Start session")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("BETA")
                    .font(StrandFont.overlineScaled(8.5)).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.onDarkSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 2.5)
                    .background(Capsule().fill(StrandPalette.surfaceInset.opacity(0.72))
                        .overlay(Capsule().strokeBorder(
                            StrandPalette.hairline,
                            lineWidth: NoopMetrics.hairlineWidth
                        )))
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.vertical, NoopMetrics.space3)
            .background(NoopPanelSurface(cornerRadius: NoopMetrics.cardRadius, surfaceOpacity: cardOpacity))
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel("Start a live session. Beta. Silent strap coaching against today's Charge.")
    }

    private var heroCard: some View {
        HStack(alignment: .top, spacing: 4) {
            // #543 carry: an unscored today shows the last scored night's REAL Charge (labelled as prior by
            // the state pill) rather than an empty vessel, matching the classic Today, the widget/watch/Live
            // Activity (`Repository.widgetAnchor`) and Android. Effort deliberately does NOT carry — it is
            // today's own accumulation, so yesterday's number would be a false statement, not a stale one.
            // Value-sampled through the one shared Charge colour, the same helper the classic hero, both
            // iOS widgets, the watch glance and the complications now use. This is the DEFAULT Today
            // screen, so leaving it on the fixed accent would have kept the contradiction on the surface
            // most people actually see. No score = nothing to sample; the vessel keeps the domain accent.
            HeroScoreCell(label: DomainTheme.charge.productName, score: chargeDisplay.pct,
                          tint: chargeDisplay.pct.map { StrandPalette.chargeRingColor($0) }
                                ?? StrandPalette.chargeColor,
                          animated: dataLoaded, onGuide: { guideSection = .charge })
            // #45: the hero Effort must honour the user's Effort scale like every other Effort read-out.
            // Show the value on the chosen scale (0–100 or WHOOP 0–21) with the matching vessel max, and
            // one decimal on the compressed 0–21 axis to match the app-wide `effortDisplay` convention
            // (12.6, not a rounded "13"); the 0–100 hero stays a whole number as before.
            HeroScoreCell(label: DomainTheme.effort.productName,
                          score: effortValue.map { UnitFormatter.effortValue($0, scale: effortScale) },
                          tint: StrandPalette.effortColor, animated: dataLoaded,
                          onGuide: { guideSection = .effort },
                          maxValue: effortScale == .whoop ? 21 : 100,
                          decimals: effortScale == .whoop ? 1 : 0)
            // The hero's provenance badge — which device/import actually supplied the inputs, not just
            // where NOOP ran the calculation. Upstream #778 fixed its accuracy (persisted alongside the
            // score itself, so it can't drift) and restored its position, centred on the top border and
            // aligned with the Rest vessel.
            HeroScoreCell(label: DomainTheme.rest.productName, score: restScore, tint: StrandPalette.restColor,
                          animated: dataLoaded, onGuide: { guideSection = .rest })
                .overlay(alignment: .top) {
                    if let sourceLabel = heroSourceLabel {
                        SourceBadge("\(sourceLabel)", tint: StrandPalette.textSecondary)
                            // Match the badge's trailing edge to the Rest vessel and centre it on the card border.
                            .fixedSize()
                            .frame(width: HeroScoreCell.vesselDiameter, alignment: .trailing)
                            .offset(y: -(NoopMetrics.space4 + NoopMetrics.sourceBadgeHeight / 2))
                            .allowsHitTesting(false)
                            .accessibilityLabel(Text("Source: \(sourceLabel)"))
                    }
                }
        }
        .padding(.vertical, NoopMetrics.space4)
        .padding(.horizontal, NoopMetrics.space3)
        // The ONE content surface that gets real iOS 26 glass (material below 26): it is the screen's
        // headline card and there is exactly one of it, so the blur pass is affordable — unlike the ten
        // metric tiles, which take a lighter fill instead. `heroFill` stays under the glass so the vessels
        // keep the dark backing their on-dark text and colours were tuned against.
        .background(
            RoundedRectangle(cornerRadius: liquidHeroRadius, style: .continuous)
                .fill(heroFill)
                .liquidGlass(in: RoundedRectangle(cornerRadius: liquidHeroRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: liquidHeroRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 30, y: 16)
                .opacity(cardOpacity)
        )
    }

    // MARK: - Card-AI contexts (#R-explain): one small "ask coach" sparkle per "Your cards" row, built
    // from data this screen already loaded — nothing new derived, same posture as
    // `StressView.coachCardContext`. Nil (button hidden) until there's a real value to explain.

    /// Generic "Your cards" row context (#R-explain): title + the row's own already-computed value and
    /// subtitle line, stated plainly. No trend/baseline data invented beyond what the row itself shows.
    /// Nil for a placeholder value ("–"), same as an empty card showing no button.
    private func dashboardCoachContext(title: String, value: String, subtitle: String) -> CoachCardContext? {
        guard coachFeatureEnabled, coachUIEnabled, value != "–", !value.isEmpty else { return nil }
        return CoachCardContext(
            title: title,
            summary: "\(title): \(value). \(subtitle).",
            suggestions: [String(localized: "What does this mean for me?"),
                          String(localized: "Is this good, or something to watch?")])
    }

    // MARK: - Heart rate

    private var heartRateSection: some View {
        VStack(spacing: NoopMetrics.space2) {
            sectionHead("HEART RATE", trailing: "Live")
            // #979: the whole-day HR trend (Deep Timeline) still exists but was buried behind Metrics →
            // Show all → Deep Timeline. Make the live HR card a one-tap route into it, with a visible
            // "Full day" affordance so it's discoverable again. (This comment used to claim the Deep
            // Timeline already drew sleep + activity bands — it didn't at the time; the #979 spin-off
            // added that parity in FullDayChartView.)
            // The card itself is NO LONGER the navigation link: the thread is scrubbable (drag along
            // the curve, the readout follows the finger) and a whole-card link swallowed that drag as
            // a tap. Full day now hangs on its own control in the card's footer — the same discrete
            // "Show all metrics" posture `keyMetricsSection` uses — so scrub and tap can't collide and
            // VoiceOver still gets a real link (a drag-only affordance would be unreachable).
            card {
                VStack(spacing: 10) {
                    // Isolated leaf: it observes LiveState so the ~1 Hz HR notifies re-render ONLY
                    // this card, never the whole Today. Shows the current bpm live with a rolling
                    // beat-by-beat trace; falls back to today's banked 5-minute trace when idle.
                    LiquidLiveHR(tint: liquidHeart, fallback: hrValues, fallbackTimes: hrTimes,
                                 animated: dataLoaded,
                                 onScrubChange: { active in
                                     hrScrubbing = active
                                     if !active { hrScrubEndedAt = Date() }
                                 })
                    NavigationLink(value: TabRoute.fullDayChart) {
                        HStack(spacing: 4) {
                            Spacer()
                            Text("Full day").font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(StrandPalette.accent)
                        }
                        // The row spans the card width, so the whole footer strip is the hit target
                        // even though only the label and chevron are drawn.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the full-day heart rate timeline")
                }
            }
        }
    }

    // MARK: - Your cards

    private var yourCardsSection: some View {
        VStack(spacing: NoopMetrics.space2) {
            HStack {
                Text("YOUR CARDS").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
                Button { customizationDestination = .yourCards } label: {
                    // #492 item 4 parity: unify the Your Cards / Key Metrics edit affordance to "EDIT" across
                    // platforms (Android #563). Reuse the localized "Edit" key, uppercased at display, so this
                    // stays translated (BEARBEITEN / MODIFIER / …) without a new literal.
                    Text(String(localized: "Edit").uppercased()).font(StrandFont.overlineScaled(11))
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 2)
            .padding(.top, 4)

            // Data-driven off the SAME @AppStorage the CUSTOMISE editor writes, so add / remove /
            // reorder in Customise reflects on the home screen live. The hydration filter mirrors classic
            // TodayView's `enabledDashboardCards` and Android's `it != HYDRATION || hydrationEnabled`.
            ForEach(DashboardCardPrefs.decodeEnabled(dashboardCardsRaw)
                        .filter { hydrationEnabled || $0 != .hydration }) { card in
                liquidCard(for: card)
            }
        }
    }

    // MARK: - Added cards (#today-hosted-cards)

    /// The Trends/Sleep cards the user hosted in Today, in their arranged order. Data-driven off the SAME
    /// @AppStorage the Customise editor writes, so add / remove / reorder reflects live. Each hosted card
    /// is the SAME view its home tab renders (a mirror, not a copy) and carries its own header, so this
    /// section adds no header of its own. Renders nothing until the user hosts a card.
    @ViewBuilder
    private var hostedCardsSection: some View {
        let cards = HostedCardPrefs.decodeEnabled(hostedCardsRaw)
        if !cards.isEmpty {
            VStack(spacing: NoopMetrics.sectionGap) {
                ForEach(cards) { card in
                    hostedCard(for: card)
                }
            }
        }
    }

    /// Dispatch a hosted card id to its native view. Each case renders the exact view the originating tab
    /// uses, so the Today copy and the home-tab copy never diverge. P0 hosts only Sleep marks.
    @ViewBuilder
    private func hostedCard(for card: HostedCard) -> some View {
        switch card {
        case .sleepMarks: SleepMarkCard()
        case .asleepDuration: AsleepDurationCard(data: AsleepDurationData.build(days: repo.days))
        case .stagesVsTypical:
            // Renders from the shared SleepModel built in load() (same inputs as the Sleep tab). Until that
            // async build lands — or on a device with no usable latest night — show the graceful placeholder
            // rather than a half-built card, mirroring how AsleepDuration degrades on no data.
            if let m = hostedSleepModel {
                StagesVsTypicalCard(model: m)
            } else {
                hostedSleepPlaceholder(title: "Stages vs typical", overline: "Last night")
            }
        case .nightDetail:
            // Renders from the same shared SleepModel built in load(). Until that async build lands — or on a
            // device with no usable latest night — show the graceful placeholder, mirroring stagesVsTypical.
            if let m = hostedSleepModel {
                NightDetailCard(model: m)
            } else {
                hostedSleepPlaceholder(title: "Night detail", overline: "Metrics")
            }
        case .sleepDebt:
            // Renders from the same shared SleepModel built in load(). Until that async build lands — or on a
            // device with no usable latest night — show the graceful placeholder, mirroring stagesVsTypical.
            if let m = hostedSleepModel {
                SleepDebtLedgerCard(model: m)
            } else {
                hostedSleepPlaceholder(title: "Sleep-debt ledger", overline: "Last 14 nights")
            }
        case .stages:
            // The READ-ONLY latest-night stage card — same shared SleepModel (same night + intervals as the
            // Sleep tab), rendered without the Sleep tab's nav/edit/nap interaction. Until the async build
            // lands — or on a device with no usable latest night — show the placeholder, as above.
            if let m = hostedSleepModel {
                StagesCard(model: m)
            } else {
                // Was mislabelled "Stages vs typical" (reusing that placeholder) — should read "Stages",
                // matching this card's own title, and TodayView's twin switch which already got this right.
                hostedSleepPlaceholder(title: "Stages", overline: "Last night")
            }
        case .hoursVsNeeded:
            // The single hours-vs-need % metric, rendered from the same shared SleepModel built in load().
            // Until that async build lands — or on a device with no usable latest night — show the graceful
            // placeholder, mirroring stagesVsTypical.
            if let m = hostedSleepModel {
                HoursVsNeededCard(model: m)
            } else {
                hostedSleepPlaceholder(title: "Hours vs Needed", overline: "Sleep")
            }
        case .consistency:
            // The single sleep-consistency % metric, rendered from the same shared SleepModel built in
            // load(). Until that async build lands — or on a device with no usable latest night — show the
            // graceful placeholder, mirroring stagesVsTypical.
            if let m = hostedSleepModel {
                ConsistencyCard(model: m)
            } else {
                hostedSleepPlaceholder(title: "Consistency", overline: "Sleep")
            }
        }
    }

    /// Graceful empty state for a SleepModel-backed hosted card whose model hasn't built yet (first frame)
    /// or is nil (no usable latest night). Keeps the hosted slot present + labelled so add/remove/reorder in
    /// Customise still reads, without rendering a partial card. Twin of TodayView's own
    /// `hostedSleepPlaceholder`. #today-hosted-cards.
    private func hostedSleepPlaceholder(title: LocalizedStringKey, overline: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(title, overline: overline)
            Text("Not enough nights yet.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                .background(NoopPanelSurface(tint: StrandPalette.restColor, cornerRadius: NoopMetrics.groupedRadius))
        }
    }

    /// One "Your cards" row for a given card type — honours the user's CUSTOMISE selection + order.
    /// Wired cards show real values; the rest render "–" for now (they still appear, so add/remove/
    /// reorder is reflected). stress → Stress screen, sleep → Sleep, everything else → Health.
    @ViewBuilder
    private func liquidCard(for card: DashboardCard) -> some View {
        switch card {
        case .stress:
            cardLink(.stress, icon: card.icon, title: card.title, sub: card.subtitle,
                     value: stressText, tint: StrandPalette.accent, frac: fracOver(stress, 3))
        case .fitnessAge:
            cardLink(.metric("fitness_age"), icon: card.icon, title: card.title, sub: card.subtitle,
                     value: unitText(fitnessAge, card.unit), tint: StrandPalette.chargeColor, frac: 0.5)
        case .vo2max:
            cardLink(.metric("vo2max_est"), icon: card.icon, title: card.title, sub: card.subtitle,
                     value: unitText(vo2max, card.unit), tint: StrandPalette.chargeColor, frac: 0.5)
        case .vitality:
            cardLink(.metric("vitality"), icon: card.icon, title: card.title, sub: card.subtitle,
                     value: intText(vitality), tint: liquidPurple, frac: frac(vitality))
        // The three nightly vitals carry exactly like the Key-Metric tiles above (`ktileFor`): today's own
        // row first, else the last night that recorded the value. Without the carry these rows read "–"
        // from the rollover until tonight's sleep is scored, while the tiles a few hundred points up the
        // same screen showed the number — one screen, two answers. Coalesce ONCE per row so the value and
        // its ring fraction can never describe different days.
        case .hrv:
            let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
            cardLink(.metric("hrv"), icon: card.icon, title: card.title, sub: card.subtitle,
                     value: unitText(hrv, card.unit), tint: StrandPalette.metricCyan,
                     frac: fracOver(hrv, 120))
        case .restingHr:
            let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
            cardLink(.metric("rhr"), icon: card.icon, title: card.title, sub: card.subtitle,
                     value: unitText(rhr, card.unit),
                     tint: StrandPalette.metricRose, frac: fracOver(rhr, 100))
        case .respiratory:
            let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm
            cardLink(.metric("resp_rate"), icon: card.icon, title: card.title, sub: card.subtitle,
                     value: unitText(resp, card.unit, decimals: 1),
                     tint: StrandPalette.accent, frac: fracOver(resp, 24))
        case .steps:
            // Route by the EXACT (key, source) the tile chose to display — measured my-whoop, imported
            // apple-health, or the my-whoop estimate — NOT by bare key (bare "steps" resolves to
            // apple-health and would mismatch a WHOOP-measured value). Order-independent.
            cardLink(.metricSourced(key: stepsDetailKey, source: stepsDetailSource), icon: card.icon,
                     title: card.title, sub: card.subtitle,
                     value: stepsText, tint: StrandPalette.metricCyan, frac: fracOver(stepCount, 10000))
        case .bloodOxygen:
            // #1627: these two were the last cards still on the "not wired yet" placeholder, so on iOS 26 —
            // where Liquid Today is the DEFAULT Today screen — Blood Oxygen and Skin Temp read "–" for
            // everyone while every other card on the same screen showed a real number off the same
            // `displayDay`. Reported with a clean A/B: turning Liquid Today off restored both immediately.
            //
            // The VALUE resolution is copied from the Key Metrics tile below rather than reinvented —
            // candidate fallback and experimental gating included — so the card and the tile cannot
            // disagree about the same day's number. The tile's key/route handling is deliberately NOT
            // copied; see below for why the two are not interchangeable.
            let spo2Real = displayDay?.spo2Pct ?? vitalsDay?.spo2Pct
            let spo2CandidateOn = PuffinExperiment.spo2CandidateDisplayEnabled
            let spo2Candidate = spo2Real == nil && spo2CandidateOn
                ? spo2CandidateByDay[cachedDisplayDay?.day ?? selectedDayKey]
                : nil
            let spo2 = spo2Real ?? spo2Candidate
            // ALWAYS routes to "spo2", never "spo2_candidate". The Key Metrics tile switches that string,
            // but there it is a SPARKLINE SERIES key (ktile feeds it to windowedSpark; navigation goes
            // through its separate detailMetric argument). Here the string is a NAVIGATION route resolved
            // against MetricCatalog — which has no "spo2_candidate" entry — so switching it would drop the
            // tap into the Health catch-all instead of the Blood Oxygen detail. Same literal, two different
            // key spaces.
            // The candidate MUST carry its label. Every other surface that shows it says "strap estimate
            // (unverified)" — the Key Metrics tile below, VitalSignsSummary, the classic TodayView — and
            // PuffinExperiment's own doc says the toggle surfaces it "in the Blood Oxygen tile/card,
            // labelled". An unlabelled number here would read as a measured SpO2 on the one surface that
            // is the DEFAULT Today screen on iOS 26. The subtitle is the slot this card has.
            cardLink(.metric("spo2"), icon: card.icon,
                     title: card.title,
                     sub: spo2Candidate != nil ? String(localized: "strap estimate (unverified)") : card.subtitle,
                     // Em dash, not the en dash the stub used: the classic Blood Oxygen card and
                     // skinTempCardValue both return "—", so the stub's "–" would have left the two
                     // adjacent cards printing different glyphs for the same "no reading" state.
                     value: spo2.map { String(format: "%.0f%%", locale: AppLanguage.activeLocale, $0) } ?? "—",
                     tint: StrandPalette.metricCyan, frac: fracOver(spo2, 100))
        case .skinTemp:
            // Skin temp has NO Key Metrics tile to mirror (KeyMetric has no skinTemp case), so this uses
            // the classic card's extracted resolver instead — the same one TodayView calls, which is why
            // it is a static: the formatting decision is testable without a live view.
            //
            // frac stays nil deliberately. A signed deviation has no natural 0–100 fill, and a ring drawn
            // from one would imply a magnitude the number does not carry.
            let skin = displayDay?.skinTempC ?? vitalsDay?.skinTempC
                ?? displayDay?.skinTempDevC ?? vitalsDay?.skinTempDevC ?? skinTempDay?.skinTempDevC
            cardLink(.metric("skin_temp"), icon: card.icon, title: card.title, sub: card.subtitle,
                     value: TodayView.skinTempCardValue(skin, fahrenheit: temperatureUnit == .fahrenheit),
                     tint: StrandPalette.metricAmber, frac: nil)
        case .calories:
            cardLink(.energy, icon: card.icon,
                     title: card.title, sub: card.subtitle,
                     value: EnergyDisplay.totalText(selectedEnergySummary),
                     tint: StrandPalette.energyHighlight, frac: nil)
        case .sleep:
            cardLink(.sleep, icon: card.icon, title: card.title, sub: card.subtitle,
                     value: sleepText, tint: StrandPalette.restColor, frac: fracOver(displayDay?.totalSleepMin, 480))
        case .hydration:
            // #989: was hardcoded "–". `HydrationGoal.cardValueString` is unit-tested and byte-identical to
            // the Android twin, but classic TodayView was its only caller — so on the DEFAULT screen a
            // logged drink never appeared. Same "<total> / <goal> L" string and the same goal fraction on
            // the ring as classic; "—" only when the goal is genuinely underivable.
            cardLink(.hydration, icon: card.icon, title: card.title, sub: card.subtitle,
                     value: hydrationGoalML.map {
                         HydrationGoal.cardValueString(totalML: hydrationTotalML ?? 0, goalML: $0)
                     } ?? "—",
                     tint: StrandPalette.metricCyan,
                     frac: hydrationGoalML.map {
                         HydrationGoal.fraction(totalML: hydrationTotalML ?? 0, goalML: $0)
                     })
        case .coupled:
            // A tap-through to the full Coupled day screen. No value, so no coach button either.
            cardLink(.coupled, icon: card.icon, title: card.title, sub: card.subtitle,
                     value: "", tint: StrandPalette.chargeColor, frac: 0.6, showsCoachButton: false)
        case .weight:
            let weightText = resolvedWeightKg.map { UnitFormatter.massFromKilograms($0.kg, system: unitSystem) } ?? "—"
            cardLink(.weight, icon: card.icon, title: card.title, sub: card.subtitle,
                     value: weightText, tint: StrandPalette.metricRose, frac: nil)
        }
    }

    /// One card row pushing its `TabRoute` by value — the first hop off the Today root must ride
    /// the tab's `NavigationPath` so a re-tap of the Today tab can pop it (#198; see TabRoute.swift).
    /// `showsCoachButton` (#R-explain, default true): adds a small "ask coach" sparkle, built from this
    /// row's OWN title/subtitle/value — nothing new derived — as a SIBLING of the NavigationLink, never
    /// nested inside it, so the navigation tap and the coach tap stay two independent controls. Hidden for
    /// a placeholder value ("–", not wired up yet) or when the caller passes false (`.coupled`, which has
    /// no metric value to explain at all).
    private func cardLink(_ route: TabRoute, icon: String, title: String, sub: String,
                          value: String, tint: Color, frac: Double?,
                          showsCoachButton: Bool = true) -> some View {
        let ctx = showsCoachButton ? dashboardCoachContext(title: title, value: value, subtitle: sub) : nil
        return HStack(spacing: 8) {
            NavigationLink(value: route) {
                TodayDashboardRow(
                    systemImage: icon,
                    title: title,
                    subtitle: sub,
                    value: value,
                    tint: tint,
                    progress: frac,
                    isPlaceholder: value == "–" || value == "—"
                )
                // The card's padding used to live OUTSIDE this label (on the parent HStack below), so the
                // margin around the row read as part of the tappable card but silently ate taps. Pulling
                // the padding into the label — plus contentShape — makes the label's hit area match what
                // it visually looks like; the trailing edge only gets its own padding here when there's no
                // coach button riding along (that button gets its own trailing padding instead).
                .padding(.leading, NoopMetrics.space4)
                .padding(.vertical, NoopMetrics.space3)
                .padding(.trailing, ctx == nil ? NoopMetrics.space4 : 0)
                .contentShape(Rectangle())
            }
            .buttonStyle(LiquidPressStyle())
            if let ctx {
                CoachCardIconButton(context: ctx)
                    .padding(.trailing, NoopMetrics.space4)
            }
        }
        .background(TodayCardSurface(tint: tint, surfaceOpacity: cardOpacity))
    }

    // MARK: - Synthesis (greeting + readiness pills + one-liner)

    /// Liquid parity with classic `effortZeroNote`: the "no cardio load yet" line shown in the synthesis
    /// card when today's Effort is ~0, so a calm day explains itself instead of a bare 0. Reuses classic's
    /// String Catalog entry verbatim — one key serves both Today screens.
    private var effortZeroNote: String? {
        guard EffortDisplay.showsZeroNote(strain: effortValue, isToday: selectedDayOffset == 0) else { return nil }
        return String(localized: "No cardio load yet. Effort builds once your heart rate climbs into your effort zone (around 50% of your heart-rate reserve). A calm day honestly reads near zero.")
    }

    /// The one-word readiness pill (Push / Maintain / Rest) — a Button that opens the Charge-breakdown
    /// sheet, parity with classic `TodayView.readinessHeroPill`. Coloured by the readiness level so the
    /// glanceable verdict still leads to the detail it summarises. Hidden when there isn't enough history
    /// (nil word), matching classic's behaviour.
    @ViewBuilder
    private func readinessHeroPill(_ word: String) -> some View {
        Button {
            showChargeBreakdown = true
        } label: {
            Text(word)
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(readinessColor(readiness.level))
                .padding(.horizontal, NoopMetrics.space3)
                .padding(.vertical, 5)
                .background(Capsule(style: .continuous).fill(readinessColor(readiness.level).opacity(0.12)))
                .overlay(Capsule(style: .continuous).stroke(readinessColor(readiness.level).opacity(0.32), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Readiness: \(word)")
        .accessibilityHint("See your full readiness")
    }

    /// The SOLID / CALIBRATING data-confidence chip — display-only, NOT tappable. Mirrors classic
    /// `TodayView.recoveryStatePill`: SOLID (green) once today carries a settled recovery score;
    /// CALIBRATING (slate) while the HRV baseline is still forming, showing the running "N of 4" count.
    @ViewBuilder
    private var solidStatePill: some View {
        if chargeDisplay.pct != nil {
            ScoreStatePill(.solid)
        } else if let n = recoveryCalibration {
            ScoreStatePill(.calibrating, text: "Calibrating, \(n) of \(Baselines.minNightsSeed)")
        } else {
            ScoreStatePill(.calibrating)
        }
    }

    /// The full-width Coach banner — a reorderable Today section (`.coach`), independent of the compact
    /// header-icon entry (see `scene`). Same content `CoachTodayRow` shows on classic Today (identity name
    /// + avatar + unseen-message dot + chevron), through Liquid's own `card { }` chrome instead of
    /// `NoopCard`, so it sits flush with every other Liquid card (synthesis, key metrics, …).
    private var coachBanner: some View {
        Button { showCoach = true } label: {
            card {
                HStack(spacing: 12) {
                    CoachEntryAvatar(size: 40, showsAvatar: todayAvatar)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identityStore.identity.name)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Ask your coach")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: 0)
                    if coach.hasUnseenCoachMessage {
                        Circle()
                            .fill(StrandPalette.statusCritical)
                            .frame(width: 9, height: 9)
                            .accessibilityHidden(true)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel(Text("\(identityStore.identity.name), your coach"))
        .accessibilityHint("Opens the AI coach chat.")
    }

    private var synthesisSection: some View {
        // Parity with the classic Today screen: the status / readiness pills sit ABOVE the card, and the
        // card itself is the shared `MomentumCard`. Liquid used to render its own older one-liner under
        // the Momentum name — same label, different behaviour, which is the kind of split this whole
        // feature exists to remove.
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: 6) {
                Spacer(minLength: 4)
                // Own tap target with its own `.sheet` — sits left of the readiness pill so it doesn't
                // collide with anything at the row's trailing edge.
                ActivityStatusChipCompact(status: $status)
                // Maintain and Solid are SEPARATE elements: the readiness word is a Button → Charge
                // breakdown; the data-confidence chip is a display-only ScoreStatePill.
                if let word = readinessWord {
                    readinessHeroPill(word)
                }
                solidStatePill
                    .layoutPriority(1)
            }
            momentumSection()
            // #530 follow-up: the classic hero's "no cardio load yet" note, shown on a calm day so
            // today's ~0 Effort explains itself instead of a bare 0.
            if let note = effortZeroNote {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.effortColor)
                        .accessibilityHidden(true)
                    Text(note)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }


    // MARK: - Momentum (#momentum)

    /// This screen's half of the Momentum inputs. Everything derived identically for both Today
    /// variants lives in `MomentumBuilder.inputs(_:)`; this supplies only what is screen-specific.
    private func momentumContext() -> MomentumBuilder.Context {
        var c = MomentumBuilder.Context()
        let d = displayDay
        c.displayDay = d
        c.lastScoredDay = cachedPriorScored
        c.allDays = repo.days
        c.dayKey = selectedDayKey
        c.isToday = selectedDayOffset == 0
        // The carried provenance the Charge hero already resolved, so both read the same date.
        if case .carried(_, let caption) = chargeDisplay { c.carriedCaption = caption }
        if status.state != .active {
            c.statusOverride = BaseCardStatement.current(status: status, readiness: readiness)
        }
        if case .calibrating(let nights) = chargeDisplay {
            c.calibration = (headline: String(localized: "Calibrating"),
                             detail: String(localized: "Learning your baseline, \(nights) of \(Baselines.minNightsSeed) nights."))
        }
        // Liquid keeps its step tiers under different names than classic: `importedStepsDay` is the
        // measured Apple figure, `stepsEst` the strap estimate.
        c.measuredSteps = d?.steps ?? importedStepsDay
        c.estimatedSteps = stepsEst.map { Int($0) }
        c.stepGoal = momentumStepGoal
        if selectedDayOffset == 0,
           let next = PlanTodayCard.next(from: CoachPlanStore.shared.proposals,
                                         today: selectedDayKey, now: Date()),
           next.day == selectedDayKey, (d?.exerciseCount ?? 0) == 0 {
            c.openPlannedSessionToday = next.sport
        }
        return c
    }

    /// See `TodayView.MomentumKey` for why the feed is resolved off a key rather than in the body.
    private var momentumKey: TodayView.MomentumKey {
        TodayView.MomentumKey(refreshSeq: repo.refreshSeq,
                              dayOffset: selectedDayOffset,
                              hour: Calendar.current.component(.hour, from: Date()),
                              lastShownKind: momentumLastKind,
                              snoozed: momentumSnoozedRaw,
                              goalsUpdatedAt: GoalTrackingStore.shared.lastUpdated,
                              statusState: status.state.rawValue)
    }

    private func rebuildMomentum() {
        let messages = MomentumResolver.feed(context: momentumContext(),
                                             snoozedRaw: momentumSnoozedRaw,
                                             lastKind: momentumLastKind,
                                             lastAt: momentumLastAt,
                                             retrospective: selectedDayOffset != 0)
        momentumFeed = messages
        MomentumStore.shared.publish(messages, recentDays: repo.days)
    }

    @ViewBuilder
    private func momentumSection() -> some View {
        if let top = momentumFeed.first {
            MomentumCard(
                message: top,
                remainingCount: max(0, momentumFeed.count - 1),
                onOpenMore: { showMomentumMore = true },
                onAction: { destination in
                    switch destination {
                    case .chargeBreakdown: showChargeBreakdown = true
                    case .goalJourney, .plan, .liveSession, .none: break
                    }
                },
                onDismiss: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        momentumSnoozedRaw = MomentumResolver.snoozing(top.kind, into: momentumSnoozedRaw)
                    }
                })
                .onAppear { noteMomentumShown(top.kind) }
                .onChangeCompat(of: top.kind.rawValue) { _ in noteMomentumShown(top.kind) }
        }
    }

    private func noteMomentumShown(_ kind: MomentumKind) {
        guard momentumLastKind != kind.rawValue else { return }
        momentumLastKind = kind.rawValue
        momentumLastAt = Date().timeIntervalSince1970
    }

    // MARK: - Charge breakdown sheet (readiness-pill tap target)

    /// The sheet opened by tapping the readiness hero pill (Push / Maintain / Rest), parity with classic
    /// `TodayView.chargeBreakdownSheet`. A scored night shows the drivers + confidence; a calibrating
    /// night shows the honest "N of 4" countdown; otherwise the needs-strap note. The scoring-guide link
    /// separates "what shaped YOUR Charge" from "how the method works".
    @ViewBuilder
    private var chargeBreakdownSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    let breakdown = chargeBreakdown()
                    if let breakdown, !breakdown.drivers.isEmpty {
                        NoopCard(padding: 18, tint: StrandPalette.chargeColor) {
                            ChargeBreakdownSection(drivers: breakdown.drivers,
                                                   confidence: breakdown.confidence,
                                                   skinTempRel: chargeSkinTempRel)
                        }
                    } else if let banked = recoveryCalibration {
                        chargeCalibrationCountdown(banked: banked)
                    } else {
                        NoopCard(padding: 18, tint: StrandPalette.chargeColor) {
                            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                                Text("No Charge breakdown yet")
                                    .font(StrandFont.headline)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(TodayView.needsStrapCaption)
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    NavigationLink {
                        ScoringGuideView(initialSection: .charge, onClose: { showChargeBreakdown = false })
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "function")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(StrandPalette.chargeColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("How Charge is calculated")
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                                Text("The method behind the score, not today's values.")
                                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius).fill(StrandPalette.surfaceInset))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("How Charge is calculated. The method behind the score.")
                }
                .padding(NoopMetrics.screenPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("What shaped your Charge")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showChargeBreakdown = false }
                        .foregroundStyle(StrandPalette.accent)
                }
                #else
                ToolbarItem {
                    Button("Done") { showChargeBreakdown = false }
                        .foregroundStyle(StrandPalette.accent)
                }
                #endif
            }
        }
    }

    /// The Charge calibrating countdown card — the same pure `ChargeBreakdownFormat` copy classic Today
    /// shows, so both screens read identically while the baseline seeds.
    @ViewBuilder
    private func chargeCalibrationCountdown(banked: Int) -> some View {
        let remaining = max(1, Baselines.minNightsSeed - banked)
        let countdown = ChargeBreakdownFormat.calibrationCountdown(nightsRemaining: remaining)
        let unlock = ChargeBreakdownFormat.calibrationUnlockCopy(scoreName: String(localized: "Charge"))
        let progress = ChargeBreakdownFormat.calibrationProgress(banked: banked, seed: Baselines.minNightsSeed)
        NoopCard(padding: 14, tint: StrandPalette.chargeColor) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StrandPalette.chargeColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(countdown)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 0)
                        ConfidenceTierChip(confidence: .calibrating)
                    }
                    Text(unlock)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(progress)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Charge baseline calibrating. \(countdown), \(unlock). \(progress).")
    }

    // MARK: - Recovery vitals

    private var recoveryVitalsSection: some View {
        // PER-FIELD, today-first carry: each vital reads today's own value, else falls back to the prior
        // day that recorded it (`vitalsDay`). Coalesce ONCE so the number and its fill fraction agree.
        let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm
        return card {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack {
                    Text("RECOVERY VITALS").font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    if let line = vitalsProvenanceLine {
                        Text(line).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                vitalRow(String(localized: "Heart-rate variability"), unitText(hrv, "ms"),
                         StrandPalette.metricCyan, fracOver(hrv, 120))
                vitalRow(String(localized: "Resting heart rate"), unitText(rhr, "bpm"),
                         StrandPalette.metricRose, fracOver(rhr, 100))
                vitalRow(String(localized: "Breaths per minute"), unitText(resp, "rpm", decimals: 1),
                         StrandPalette.accent, fracOver(resp, 24))
            }
        }
    }

    private func vitalRow(_ label: String, _ value: String, _ tint: Color, _ frac: Double?) -> some View {
        HStack(spacing: 12) {
            LiquidVessel(value: frac, tint: tint, animated: false).frame(width: 26, height: 26)
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value).font(StrandFont.number(15)).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    // MARK: - Key metrics grid

    /// The chosen detailed-graph window's oldest day key (1 week / 2 weeks / 1 month ending on the
    /// selected day). The loader banks a 30-day superset; render filters down so a window change in the
    /// editor applies instantly, no reload.
    private var sparkWindowCutoffKey: String {
        let days = (keyMetricsWindowDays == 7 || keyMetricsWindowDays == 30) ? keyMetricsWindowDays : 14
        let cal = Calendar.current
        let anchor = cal.startOfDay(for: selectedLogicalDay)
        return Repository.localDayKey(cal.date(byAdding: .day, value: -(days - 1), to: anchor) ?? anchor)
    }

    /// A metric's spark values inside the chosen window, oldest → newest.
    private func windowedSpark(_ key: String) -> [Double] {
        Self.windowedSpark(points: kSparks[key] ?? [], cutoffKey: sparkWindowCutoffKey,
                           maxPoints: keyMetricsWindowDays)
    }

    /// The window rule behind every detailed tile's sparkline. Pure + static so it is testable with no
    /// view and no clock (`LiquidSparkWindowTests`).
    ///
    /// The date window is the normal path and stays: it keeps a stale import from being read as a current
    /// trend (#23). But it was the ONLY path, and a sparse series dies in it — someone who weighs
    /// themselves every few weeks has fewer than two points inside 2/7/14 days, so the Weight tile drew
    /// `Color.clear` while its number was right (`Repository.resolveWeightKg` takes the latest series
    /// point regardless of date). `docs/FEATURES.md` promises the opposite: "Sparse series (e.g. weight)
    /// fall back to all history so a tile never shows empty when data exists" — which classic Today gets
    /// for free from its count-based `suffix` (`TodayView.windowedSpark`).
    ///
    /// So: window first, and only when it cannot draw a line (< 2 points) fall back to the last
    /// `maxPoints` MEASUREMENTS of the full series. Dense metrics never reach the fallback.
    static func windowedSpark(points: [(String, Double)], cutoffKey: String, maxPoints: Int) -> [Double] {
        let windowed = points.filter { $0.0 >= cutoffKey }
        if windowed.count >= 2 { return windowed.map { $0.1 } }
        return Array(points.suffix(maxPoints)).map { $0.1 }
    }

    /// The Key-Metrics header's trailing label for the chosen detailed-graph window (Android twin).
    private var trendWindowLabel: String {
        switch keyMetricsWindowDays {
        case 7: return String(localized: "7-day trend")
        case 30: return String(localized: "30-day trend")
        default: return String(localized: "14-day trend")
        }
    }

    private var keyMetricsSection: some View {
        // HRV / Rest HR (+ Blood Oxygen / Respiratory) tiles share the recovery vitals' per-field
        // today-first carry so they don't blank at the rollover while Recovery/Strain/Rest stay strictly
        // today's own (they are scored surfaces).
        let hrv = displayDay?.avgHrv ?? vitalsDay?.avgHrv
        let rhr = (displayDay?.restingHr ?? vitalsDay?.restingHr).map(Double.init)
        return VStack(spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                sectionHead("KEY METRICS", trailing: trendWindowLabel)
                // #430 parity: the SAME editor the classic grid uses — selection + order + Detailed tiles.
                Button { customizationDestination = .keyMetrics } label: {
                    Text(String(localized: "Edit").uppercased())
                        .font(StrandFont.overlineScaled(11))
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit Key Metrics")
            }
            // #430 parity: the grid honours the Key-Metrics editor (selection + order, all ten metrics)
            // instead of a hard-coded six — the bespoke Sleep-hours ktile gives way to the shared REST
            // score tile, aligning the liquid grid with the classic macOS grid and Android.
            // Tiles WITH a value first, valueless ones after — each group keeping the user's own saved
            // order (a stable partition, not a sort). A "—" tile holds a full slot either way; it just
            // shouldn't hold a PRIME slot and push real numbers below the fold.
            let ordered = enabledKeyMetrics.filter { keyMetricHasValue($0, hrv: hrv, rhr: rhr) }
                + enabledKeyMetrics.filter { !keyMetricHasValue($0, hrv: hrv, rhr: rhr) }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8),
                                     count: keyMetricsColumns), spacing: 8) {
                ForEach(ordered) { metric in
                    ktileFor(metric, hrv: hrv, rhr: rhr)
                }
            }
            NavigationLink(value: TabRoute.metricExplorer) {
                LiquidFullWidthNavigationAction("Show all metrics")
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    /// Whether this metric has a real number for the selected day. Drives the "empty tiles last" ordering in
    /// `keyMetricsSection`.
    ///
    /// This switch MIRRORS `ktileFor` below case-for-case and must be edited with it — a metric added to one
    /// and not the other sorts wrong (silently, since both still render).
    private func keyMetricHasValue(_ metric: KeyMetric, hrv: Double?, rhr: Double?) -> Bool {
        switch metric {
        case .charge:       return chargeDisplay.pct != nil
        case .effort:       return effortValue != nil
        case .rest:         return restScore != nil
        case .hrv:          return hrv != nil
        case .restingHr:    return rhr != nil
        case .weight:       return resolvedWeightKg != nil
        case .bloodOxygen:  return (displayDay?.spo2Pct ?? vitalsDay?.spo2Pct) != nil
        case .respiratory:  return (displayDay?.respRateBpm ?? vitalsDay?.respRateBpm) != nil
        case .steps:        return stepCount != nil
        case .calories:     return selectedEnergySummary?.totalBurnedSoFar != nil
        case .skinTemp:     return (displayDay?.skinTempC ?? vitalsDay?.skinTempC
                                    ?? displayDay?.skinTempDevC ?? vitalsDay?.skinTempDevC) != nil
        }
    }

    /// One editor-selected Key-Metric tile: the metric's value/tint/fill exactly as the old hard-coded
    /// tiles read them (Android's descriptor map is the twin), plus the metric-catalog `key` that names
    /// both its 14-day spark series and its tap-through detail. Weight now resolves through the same
    /// 3-tier fallback classic/Heute use (`resolvedWeightKg`), no longer a permanent "—" placeholder.
    @ViewBuilder
    private func ktileFor(_ metric: KeyMetric, hrv: Double?, rhr: Double?) -> some View {
        switch metric {
        case .charge:
            // Reads the SAME resolved Charge the hero draws, not `displayDay?.recovery` raw — the tile and the
            // hero are the same number, so a carry that reached only one of them would put two answers for
            // Charge on one screen. (#543: one prior row feeds every recovery-derived read-out.) Strain below
            // stays raw, matching the Effort hero, which correctly does not carry.
            ktile(DomainTheme.charge.productName, icon: metric.customizationIcon, intText(chargeDisplay.pct), "%", StrandPalette.chargeColor, frac(chargeDisplay.pct), key: "recovery")
        case .effort:
            // #45 parity with the hero: route through effortDisplay so this tile shows the SAME number on
            // the SAME scale as the Effort hero (0–21 WHOOP vs 0–100), instead of always the raw 0–100
            // stored value — the two used to disagree whenever the user picked the WHOOP scale.
            let effortText = effortValue.map { UnitFormatter.effortDisplay($0, scale: effortScale) } ?? "–"
            ktile(DomainTheme.effort.productName, icon: metric.customizationIcon, effortText, "%", StrandPalette.effortColor, frac(effortValue), key: "strain")
        case .rest:
            ktile(DomainTheme.rest.productName, icon: metric.customizationIcon, intText(restScore), "%", StrandPalette.restColor, frac(restScore), key: "sleep_performance")
        case .hrv:
            ktile("HRV", icon: metric.customizationIcon, intText(hrv), "ms", StrandPalette.metricCyan, fracOver(hrv, 120), key: "hrv")
        case .restingHr:
            ktile(String(localized: "Rest HR"), icon: metric.customizationIcon, intText(rhr), "bpm", StrandPalette.metricRose, fracOver(rhr, 100), key: "rhr")
        case .bloodOxygen:
            let spo2Real = displayDay?.spo2Pct ?? vitalsDay?.spo2Pct
            let candidate = spo2Real == nil && PuffinExperiment.spo2CandidateDisplayEnabled
                ? spo2CandidateByDay[cachedDisplayDay?.day ?? selectedDayKey]
                : nil
            let spo2 = spo2Real ?? candidate
            ktile("SpO₂", icon: metric.customizationIcon, intText(spo2), "%",
                  StrandPalette.metricCyan, fracOver(spo2, 100),
                  key: candidate == nil ? "spo2" : "spo2_candidate",
                  caption: candidate == nil ? nil : String(localized: "strap estimate (unverified)"))
        case .respiratory:
            let resp = displayDay?.respRateBpm ?? vitalsDay?.respRateBpm ?? respDay?.respRateBpm
            ktile(String(localized: "Respiratory"), icon: metric.customizationIcon,
                  resp.map { String(format: "%.1f", locale: AppLanguage.activeLocale, $0) } ?? "—",
                  "rpm", StrandPalette.accent, fracOver(resp, 24), key: "resp_rate")
        case .steps:
            ktile(String(localized: "Steps"), icon: metric.customizationIcon, stepsText, "", StrandPalette.chargeColor,
                  fracOver(stepCount, 10000), key: stepsDetailKey, detailMetric: stepsDetailMetric)
        case .weight:
            let weightText = resolvedWeightKg.map { UnitFormatter.massFromKilograms($0.kg, system: unitSystem) } ?? "—"
            ktile(String(localized: "Weight"), icon: metric.customizationIcon, weightText, "", StrandPalette.metricAmber, nil, key: "weight")
        case .calories:
            ktile(String(localized: "Calories"), icon: metric.customizationIcon,
                  EnergyDisplay.totalText(selectedEnergySummary), "kcal", StrandPalette.energyHighlight,
                  nil, key: "energy_total", caption: String(localized: "total burned so far"),
                  route: .energy)
        case .skinTemp:
            // Added 2026-08-24 (queue 11c follow-up): first Key Metrics appearance for Skin Temp — was
            // already a "Your Cards" tile (`DashboardCard.skinTemp`), never a Key Metrics one. Same
            // 2-level carry the Blood Oxygen case just above uses (displayDay → the cached vitals carry),
            // and the SAME `SkinTempDisplay` formatter every other skin-temp surface uses so a deviation
            // reads "+0.1 Δ°C" here exactly as it does on "Your Cards"/the Deep Timeline, never the plain
            // `%+.1f°` that read a fabricated absolute value for a signed deviation (#622).
            let skinValue = displayDay?.skinTempC ?? vitalsDay?.skinTempC
                ?? displayDay?.skinTempDevC ?? vitalsDay?.skinTempDevC
            let skinText = skinValue.map {
                SkinTempDisplay.format($0, fahrenheit: temperatureUnit == .fahrenheit)
            } ?? "—"
            // The card's own unit is deliberately empty — the value carries "°C"/"Δ°F" itself, same as
            // the classic TodayView Skin Temp card.
            ktile(String(localized: "Skin Temp"), icon: metric.customizationIcon,
                  skinText, "", StrandPalette.metricAmber, nil, key: "skin_temp")
        }
    }

    private func ktile(_ label: String, icon: String, _ value: String, _ unit: String, _ tint: Color, _ frac: Double?,
                       key: String? = nil, detailMetric: MetricDescriptor? = nil,
                       caption: String? = nil, route: TabRoute? = nil) -> some View {
        // Two columns means ~50pt more width per tile — spend it on legibility (a bigger number, a taller
        // trend) instead of leaving it as empty card.
        let wide = keyMetricsColumns <= 2
        let spark = keyMetricsDetailed ? (key.map { windowedSpark($0) } ?? []) : nil
        let tile = TodayMetricTile(
            label: Text(verbatim: label.uppercased()),
            systemImage: icon,
            value: value,
            unit: unit,
            caption: caption,
            tint: tint,
            progress: frac,
            reservesProgressSpace: true,
            sparkline: spark,
            sparkColor: tint,
            sparklineHeight: keyMetricsDetailed ? (wide ? 28 : 22) : nil,
            dense: !wide,
            surfaceOpacity: cardOpacity
        )
        // #430 parity: tap -> the metric's trend detail (the same Explore dossier its MetricRow pushes,
        // closure-based NavigationLink per #38). A metric with no catalog entry stays inert.
        return Group {
            // Weight is the one Key Metric with a writable history behind it, so it opens its own
            // screen rather than the read-only metric dossier.
            if let route {
                NavigationLink(value: route) { tile }
                    .buttonStyle(.plain)
            } else if detailMetric == nil, key == "weight" {
                NavigationLink { WeightDetailView() } label: { tile }
                    .buttonStyle(.plain)
            } else if let metric = detailMetric ?? key.flatMap({ key in
                MetricCatalog.all.first(where: { $0.key == key })
            }) {
                NavigationLink { MetricDetailView(metric: metric) } label: { tile }
                    .buttonStyle(.plain)
            } else {
                tile
            }
        }
    }

    // MARK: - Last workouts

    private var lastWorkoutsSection: some View {
        VStack(spacing: NoopMetrics.space2) {
            sectionHead("LAST WORKOUTS", trailing: "\(workouts.count) total")
            if workouts.isEmpty == false {
                // Up to six, like classic Today (`TodayView.lastWorkoutsSection`) and the plural heading
                // promise — this rendered `workouts.first` alone, so "1998 total" stood over one card.
                // `WorkoutRow` isn't Identifiable, hence the offset key.
                ForEach(Array(workouts.prefix(6).enumerated()), id: \.offset) { _, w in
                    // Opens THIS workout's detail directly as a sheet — not a push through the Workouts
                    // overview screen (see `workoutDetailTarget`'s doc comment).
                    Button { workoutDetailTarget = WorkoutDetailTarget(row: w) } label: { workoutCard(w) }
                        .buttonStyle(LiquidPressStyle())
                }
            } else {
                card {
                    Text("No workouts yet")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func workoutCard(_ w: WorkoutRow) -> some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WorkoutSource.displaySport(w.sport)).font(StrandFont.number(15))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(workoutSub(w)).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer()
                    (Text(effortText(w.strain)).font(StrandFont.number(15))
                        + Text(" EFFORT").font(StrandFont.overlineScaled(9)))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                LiquidTube(frac: (w.strain ?? 0) / 100, tint: StrandPalette.effortColor, height: 12, animated: false)
            }
        }
    }

    // MARK: - Data sources

    private var dataSourcesSection: some View {
        VStack(spacing: NoopMetrics.space2) {
            sectionHead("DATA SOURCES", trailing: "Provenance")
            NavigationLink(value: TabRoute.dataSources) {
                card {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Synced from").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            Spacer()
                            HStack(spacing: 4) {
                                Text("View sources").font(StrandFont.subhead).foregroundStyle(StrandPalette.textTertiary)
                                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        LiquidStrapBatteryRow()
                        LiquidSyncStatusRow()
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
        }
    }

    // MARK: - Reusable chrome

    private func sectionHead(_ title: String, trailing: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(title)).font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(LocalizedStringKey(trailing)).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 2)
        .padding(.top, 4)
    }

    private func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .padding(NoopMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                TodayCardSurface(surfaceOpacity: cardOpacity)
            )
    }

    // MARK: - Data

    private func load() async {
        // Re-resolve the silent `validUntil` fallback on every (re)load, not just once at view creation —
        // a screen left open across the expiry would otherwise keep showing the stale exception state.
        let resolvedStatus = ActivityStatusStore.load()
        if resolvedStatus != status { status = resolvedStatus }

        // #989: today's hydration total + goal. One metricSeries row + a UserDefaults read, same as classic
        // TodayView.reloadHydration(). Cleared when the feature is off so the card can't show a stale total.
        if hydrationEnabled {
            hydrationTotalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
            hydrationGoalML = repo.hydrationGoalML(profileSex: profile.sex)
        } else {
            hydrationTotalML = nil
            hydrationGoalML = nil
        }
        // Resolve the O(days) lookups ONCE here (not on every body re-render): the selected day and the
        // readiness verdict. Both scan repo.days (up to 599 rows); doing it per-render was the stutter.
        let day = resolveDisplayDay()
        cachedDisplayDay = day
        // Prior-day vitals carry, resolved ONCE here (never in body). Bound to today's own key so it can't
        // echo today's still-forming row; only on today (a past day's own row is the whole story).
        let tkey = cachedDisplayDay?.day ?? selectedDayKey
        cachedVitalsDay = (selectedDayOffset == 0) ? Repository.lastVitalsDay(days: repo.days, todayKey: tkey) : nil
        // The two PER-FIELD carries, same rule and same key. Separate selectors because the whole-row one
        // above accepts a row whose `spo2Pct`/`skinTempDevC` is nil (computed rows always write nil there).
        cachedSpo2Day = (selectedDayOffset == 0) ? Repository.lastSpo2Day(days: repo.days, todayKey: tkey) : nil
        cachedSkinTempDay = (selectedDayOffset == 0) ? Repository.lastSkinTempDay(days: repo.days, todayKey: tkey) : nil
        cachedRespDay = (selectedDayOffset == 0) ? Repository.lastRespDay(days: repo.days, todayKey: tkey) : nil
        // Charge carry (#543) + the honest label, resolved here for the same reason as the two above: the
        // selector below scans repo.days. Calibration nights come from the SAME `RecoveryScorer` helper the
        // classic Today reads, so the two screens agree on when a wearer is genuinely mid-calibration
        // rather than simply lacking a scored night.
        let calNights = (selectedDayOffset == 0)
            ? RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                               dayKeys: repo.days.map(\.day),
                                               hasRecovery: day?.recovery != nil)
            : nil
        let priorScored = TodayView.lastScoredRecoveryDay(days: repo.days, selectedDayKey: tkey,
                                                           isToday: selectedDayOffset == 0,
                                                           todayScored: day?.recovery != nil,
                                                           isCalibrating: calNights != nil)
        // Readiness anchors on the day whose row carries today's vitals (#543): normally today, but while
        // carrying, the last SCORED day — otherwise `evaluate` reads `.insufficient` right after the
        // rollover and the readiness word would vanish/blank instead of carrying forward. Same anchor as
        // `TodayView.computeReadiness` / `HeuteRedesignView.load` — was previously anchored on `day?.day`
        // here only, which is what let this screen disagree with the other two (on-device feedback).
        cachedReadiness = ReadinessEngine.evaluate(days: repo.days,
                                                   today: priorScored?.day ?? Repository.logicalDayKey(Date()))
        cachedPriorScored = priorScored
        cachedChargeDisplay = ChargeDisplay.resolve(
            todayRecovery: day?.recovery,
            priorScored: priorScored,
            calibrationNights: calNights,
            todayKey: tkey)

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedLogicalDay)
        let from = Int(dayStart.timeIntervalSince1970)
        // today → midnight..now; a past day → its full 24h (a missing morning reads as empty space).
        let to: Int = selectedDayOffset == 0
            ? Int(Date().timeIntervalSince1970)
            : Int((cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)

        async let restA = repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        async let stressA = repo.series(key: "stress", source: "my-whoop")
        async let fitA = repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        async let vo2A = repo.exploreSeries(key: "vo2max_est", source: "my-whoop")
        async let vitA = repo.exploreSeries(key: "vitality", source: "my-whoop")
        async let stepsA = repo.exploreSeries(key: "steps_est", source: "my-whoop")
        // Queue 11a: SpO₂ candidate fallback (see `spo2CandidateByDay`'s declaration).
        async let spo2CandA = repo.exploreSeries(key: "spo2_candidate", source: "my-whoop")
        async let appleA = repo.appleDailyRows()
        async let hrA = repo.hrBuckets(from: from, to: to, bucketSeconds: 300)
        // `reconcileHrCap: 8` — same shape as `TodayView`: this renders `workouts.prefix(6)` and otherwise
        // only uses `.count`, so the full 300-row display-only HR reconcile spent ~294 launch-path queries
        // on rows nobody sees. The budget is spent newest-first, so the six rendered cards keep their
        // trace-reconciled values. See `Repository.workoutRows(days:reconcileHrCap:)`.
        async let wkA = repo.workoutRows(reconcileHrCap: 8)
        // Weight: a wider 91-day fetch (not the 14-day sparkCutoff window every sibling series uses below)
        // — weight is logged sparsely enough that a 14-day window would frequently be empty, defeating the
        // point of the series fallback. `windowedSpark` trims it at render time like every other entry.
        async let weightSeriesA = repo.weightDailyValues(days: 91)
        async let weightSummaryA = repo.weightTrendSummary(days: 91)
        async let energyA = repo.energySummaries(days: 30,
                                                  profile: Repository.analyticsProfile(profile))
        // Ask the same cross-source resolver the Classic Today view uses which source actually won each
        // displayed score. Include the exact carried-Charge day; a fixed relative lookback can miss a
        // legitimately old carried score.
        let sourceDayKey = selectedDayKey
        let sourceFromDay = min(sourceDayKey, priorScored?.day ?? sourceDayKey)
        async let chargeSourceA = repo.resolvedSeries(key: "recovery", source: Repository.whoopSource,
                                                      from: sourceFromDay, to: sourceDayKey)
        async let effortSourceA = repo.resolvedSeries(key: "strain", source: Repository.whoopSource,
                                                      from: sourceDayKey, to: sourceDayKey)
        async let restSourceA = repo.resolvedSeries(key: "sleep_performance", source: Repository.whoopSource,
                                                    from: sourceDayKey, to: sourceDayKey)

        let restSeries = await restA
        let stepsSeries = await stepsA
        let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        // Selected day's Rest; tail fallback only at offset 0 (a past day with no row shows nothing) AND
        // only when the tail night is still fresh. #977: a live 5.0 whose sleep never scores (no overnight
        // gravity ⇒ no sleep_performance point ever written) used to pin Rest to the weeks-old series tail
        // forever while Charge advanced; freshness-gate the tail-fallback so a stale tail falls through to
        // the Rest hero's No-Data/calibrating state (same empty treatment Effort uses) instead of freezing.
        restScore = TodayView.freshRestScore(
            todayValue: restByDay[selectedDayKey], lastDay: restSeries.last?.day,
            lastValue: restSeries.last?.value, isTodaySelected: selectedDayOffset == 0,
            todayKey: selectedDayKey)
        // StressModel loops the full history to build its baseline — run it OFF the main actor so a big
        // history doesn't stutter the UI. Snapshot the inputs (value types) into the detached task.
        let storedStress = await stressA
        let daysSnapshot = repo.days

        // #430 parity: the day-keyed series the DETAILED Key-Metrics tiles graph — a trailing CALENDAR
        // window ending on the selected day (not the last-N stored rows, which on an old import showed
        // months-old data as a fresh trend, issue #23). The loader banks the 30-day SUPERSET; the chosen
        // 1-week/2-week/1-month window filters at render (windowedSpark), so a picker change applies without
        // a reload. Keys mirror the metric catalog so a tile's graph, its tap-through detail and Android's
        // Window all read the same signal. Rest reuses the already-loaded sleep_performance series.
        let sparkCutoff = Repository.localDayKey(cal.date(byAdding: .day, value: -29, to: dayStart) ?? dayStart)
        let sparkRows = daysSnapshot.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
        let spo2CandSeries = await spo2CandA
        spo2CandidateByDay = Dictionary(
            spo2CandSeries.map { ($0.day, $0.value) },
            uniquingKeysWith: { _, last in last }
        )
        // Weight comes from the canonical resolver, which unions NOOP weigh-ins over Apple Health per day.
        let weightSeries = await weightSeriesA
        resolvedWeightKg = WeightSeries.displayWeight(summary: await weightSummaryA,
                                                      profileWeightKg: profile.weightKg)
        let energySummaries = await energyA
        energySummariesByDay = Dictionary(energySummaries.map { ($0.day, $0) },
                                          uniquingKeysWith: { _, latest in latest })
        let energyTotalSpark = energySummaries.compactMap { summary in
            summary.totalBurnedSoFar.map { (summary.day, $0) }
        }
        kSparks = [
            "recovery": sparkRows.compactMap { r in r.recovery.map { (r.day, $0) } },
            "strain": sparkRows.compactMap { r in r.strain.map { (r.day, $0) } },
            "hrv": sparkRows.compactMap { r in r.avgHrv.map { (r.day, $0) } },
            "rhr": sparkRows.compactMap { r in r.restingHr.map { (r.day, Double($0)) } },
            "spo2": sparkRows.compactMap { r in r.spo2Pct.map { (r.day, $0) } },
            "spo2_candidate": spo2CandSeries.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey },
            // Added 2026-08-24 (queue 11c follow-up) for the new Skin Temp Key Metrics tile — already
            // loaded on `sparkRows` (`daysSnapshot`), same as every other DailyMetric-column tile above.
            "skin_temp": sparkRows.compactMap { r in r.skinTempDevC.map { (r.day, $0) } },
            "resp_rate": sparkRows.compactMap { r in r.respRateBpm.map { (r.day, $0) } },
            "steps": sparkRows.compactMap { r in r.steps.map { (r.day, Double($0)) } },
            "energy_total": energyTotalSpark,
            "steps_est": stepsSeries.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
                .map { ($0.day, $0.value) },
            "sleep_performance": restSeries.filter { $0.day >= sparkCutoff && $0.day <= selectedDayKey }
                .map { ($0.day, $0.value) },
            "weight": weightSeries.map { ($0.day, $0.value) },
        ]
        stress = await Task.detached(priority: .utility) {
            StressModel(days: daysSnapshot, stored: storedStress)?.score
        }.value
        fitnessAge = (await fitA).last?.value   // history-wide latest banked (not day-scoped)
        vo2max = (await vo2A).last?.value        // #1391: latest banked VO₂max estimate
        vitality = (await vitA).last?.value
        // Steps is a DAILY metric, so key it to the SELECTED day (like restScore above), not the history-wide
        // latest. Without this, swiping to a past day with no strap step count showed today's estimate (the
        // `.last` value) instead of that day's. Mirrors the classic Today's stepsEstByDay[selectedDayKey].
        let stepsByDay = Dictionary(stepsSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
        stepsEst = stepsByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? stepsSeries.last?.value : nil)
        // Imported Apple Health steps for the SELECTED day (max across rows), the middle tier between the
        // measured strap count and the motion estimate. Health Connect is Android-only, so apple-health is
        // the sole import source on iOS. Mirrors Android `stepsForDay` (#377).
        importedStepsDay = (await appleA).filter { $0.day == selectedDayKey }.compactMap { $0.steps }.max()
        let hrBuckets = await hrA
        hrValues = hrBuckets.map { $0.bpm }
        hrTimes = hrBuckets.map { Date(timeIntervalSince1970: TimeInterval($0.ts)) }
        workouts = await wkA

        let (chargeSource, effortSource, restSource) = await (chargeSourceA, effortSourceA, restSourceA)
        let sourceResolutions = [
            ("recovery", chargeSource),
            ("strain", effortSource),
            ("sleep_performance", restSource),
        ]
        var providers: [String: ScoreInputProvider] = [:]
        for (metric, resolution) in sourceResolutions {
            let selectedPoint = resolution.points.last(where: { $0.day == sourceDayKey })
            let winner = selectedPoint
                ?? (metric == "recovery"
                    ? priorScored.flatMap { prior in resolution.points.last(where: { $0.day == prior.day }) }
                    : nil)
            if let winner {
                providers[metric] = await repo.scoreInputProvider(
                    resolvedSource: winner.source,
                    day: winner.day,
                    metricKey: metric
                )
            }
        }
        heroProviderByMetric = providers

        // #today-hosted-cards: build the shared SleepModel that backs the hosted sleep cards, but ONLY when
        // at least one sleep-origin card is actually hosted — otherwise Today pays no extra Repository cost.
        // The inputs (allSleepSessions / habitualMidsleepSec / sessionMotions) are loaded exactly as the
        // Sleep tab loads them, then handed to the SAME pure `SleepModel.build`, so a hosted card renders
        // numbers byte-identical to the Sleep tab. Reused by every SleepModel-backed hosted card (built once).
        let sleepOrigin = String(localized: "Sleep")
        if HostedCardPrefs.decodeEnabled(hostedCardsRaw).contains(where: { $0.origin == sleepOrigin }) {
            let hostedSessions = await repo.allSleepSessions()
            let hostedHabitual = await repo.habitualMidsleepSec()
            let hostedMotion = await repo.sessionMotions(sessions: hostedSessions)
            hostedSleepModel = SleepModel.build(SleepModelInputs(
                days: repo.days,
                sleeps: repo.sleeps,
                allSessions: hostedSessions,
                importedSleep: repo.importedSleep,
                habitualMidsleepSec: hostedHabitual,
                motionByStart: hostedMotion))
        } else {
            hostedSleepModel = nil
        }

        // Today's in-progress Effort, DELIBERATELY last: it is the heaviest read on this pass, and every
        // surface it feeds already has a value drawn from the stored row by the time it lands. Because
        // `effectiveEffort` floors at that row, the refinement can only raise the number.
        liveTodayStrain = selectedDayOffset == 0
            ? await LiveEffort.today(repo: repo, profile: profile, restingHr: displayDay?.restingHr)
            : nil

        // First load done — bring the hero gauges + sky to life now the launch churn has settled.
        if !dataLoaded { withAnimation(.easeIn(duration: 0.4)) { dataLoaded = true } }
    }

    // MARK: - Derived (sync, off repo.today / repo.days)

    /// Cached in load() — ReadinessEngine.evaluate scans the full history and was invoked ~3× per body
    /// pass (readinessWord + synthLine + readiness.summary). The fallback runs only in the brief window
    /// before the first load() populates the cache.
    private var readiness: ReadinessEngine.Readiness {
        cachedReadiness ?? ReadinessEngine.evaluate(days: repo.days, today: cachedDisplayDay?.day)
    }

    /// One card-level provenance label. Identical winners collapse to one name; mixed scores show at most
    /// two distinct winners in Charge / Effort / Rest order so the compact badge stays readable.
    private var heroSourceLabel: String? {
        Self.heroSourceLabel(
            providers: ["recovery", "strain", "sleep_performance"].compactMap { heroProviderByMetric[$0] })
    }

    /// Pure aggregation seam for the Liquid hero. The provider mapper names the sensors/imports that
    /// supplied the score inputs; identical names collapse and the compact badge is capped at two.
    static func heroSourceLabel(providers: [ScoreInputProvider]) -> String? {
        var seen = Set<String>()
        var labels: [String] = []
        for provider in providers {
            let label = TodayView.todayScoreProviderLabel(
                sourceId: provider.sourceId,
                brand: provider.brand
            )
            if seen.insert(label).inserted { labels.append(label) }
            if labels.count == 2 { break }
        }
        return labels.isEmpty ? nil : labels.joined(separator: " + ")
    }

    private var readinessWord: String? {
        switch readiness.level {
        case .primed: return String(localized: "Push")
        case .balanced: return String(localized: "Maintain")
        case .strained, .rundown: return String(localized: "Rest")
        case .insufficient: return nil
        }
    }

    private var synthLine: String {
        // #612: when still calibrating BECAUSE the strap stopped delivering nights (connected, but no new
        // night for > staleDays), say so directly instead of "still learning your baseline" — the honest
        // calibrating state with its reason attached. `stale` is always > staleDays (14), so always plural.
        if readiness.level == .insufficient,
           let stale = Baselines.nightsSinceNewestValidNight(dayKeys: repo.days.map(\.day),
                                                             nightlyHrv: repo.days.map(\.avgHrv),
                                                             today: Repository.logicalDayKey(Date())),
           stale > Baselines.staleDays {
            return String(localized: "No new nights from your strap for \(stale) days. Check it's connected and saving data.")
        }
        switch readiness.level {
        case .primed: return String(localized: "You're primed. A hard session should land well today.")
        case .balanced: return String(localized: "You're in a good spot for training.")
        case .strained: return String(localized: "Signals are down a touch. Keep it easy today.")
        case .rundown: return String(localized: "Several recovery signals are down. Prioritise rest today.")
        case .insufficient: return String(localized: "Still learning your baseline. A few more nights and this fills in.")
        }
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? String(localized: "Good morning")
            : h < 17 ? String(localized: "Good afternoon")
            : String(localized: "Good evening")
    }

    /// The greeting with the user's name when they set one in Settings ("Good morning, Marc"), the bare
    /// greeting when they didn't. `displayName` already trims and nils an empty name, so this can never
    /// render a dangling comma.
    private var greetingLine: String {
        guard let name = profile.displayName else { return greeting }
        return "\(greeting), \(name)"
    }

    /// The header's first line: the greeting on today, the relative day title on a navigated past day.
    private var headlineLine: String { selectedDayOffset == 0 ? greetingLine : dayTitle }

    // Measured strap count ?: imported Apple Health count ?: motion estimate — the same precedence the
    // detail routing follows below, so the tapped-through source always matches the number shown (#377).
    private var stepCount: Double? {
        displayDay?.steps.map(Double.init) ?? importedStepsDay.map(Double.init) ?? stepsEst
    }

    private var stepsDetailMetric: MetricDescriptor? {
        MetricCatalog.todayStepsMetric(hasMeasuredSteps: displayDay?.steps != nil,
                                       hasImportedSteps: importedStepsDay != nil)
    }

    private var stepsDetailKey: String { stepsDetailMetric?.key ?? "steps_est" }
    private var stepsDetailSource: String { stepsDetailMetric?.source ?? "my-whoop" }

    private var selectedEnergySummary: DailyEnergySummary? {
        energySummariesByDay[selectedDayKey]
    }

    private var liveHour: Double {
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        return Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
    }

    // MARK: - Formatting

    private func frac(_ v: Double?) -> Double? { v.map { max(0, min(1, $0 / 100)) } }
    private func fracOver(_ v: Double?, _ over: Double) -> Double? { v.map { max(0, min(1, $0 / over)) } }
    private func intText(_ v: Double?) -> String { v.map { String(Int($0.rounded())) } ?? "–" }

    private func unitText(_ v: Double?, _ unit: String, decimals: Int = 0) -> String {
        guard let v else { return "–" }
        let n = decimals > 0 ? String(format: "%.\(decimals)f", locale: AppLanguage.activeLocale, v) : String(Int(v.rounded()))
        return unit.isEmpty ? n : "\(n) \(unit)"
    }

    private var stressText: String { stress.map { String(Int($0.rounded())) } ?? String(localized: "Calibrating") }

    private var sleepText: String {
        guard let m = displayDay?.totalSleepMin else { return "–" }
        return "\(Int(m) / 60)h \(Int(m) % 60)m"
    }

    private var stepsText: String {
        guard let s = stepCount else { return "–" }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: Int(s))) ?? "\(Int(s))"
    }

    // °C / °F for the Skin Temp card, resolved exactly the way the other six screens that show a
    // temperature resolve it (TodayView, FullDayChartView, MetricExplorerView x2, SettingsView,
    // HealthView): the explicit override when set, else derived from the unit system. Liquid Today was
    // the ONLY one of them missing it — which is why its Skin Temp card could not honour the preference
    // even once it had a value to show (#1627).
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }

    // The user's Effort display scale (#268), 0–100 by default or the WHOOP 0–21 axis if chosen — the SAME
    // preference the Workouts screen + Trends read, so a workout's Effort number is identical everywhere.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    private func effortText(_ s: Double?) -> String {
        guard let s else { return "–" }
        // Route through the shared formatter instead of hardcoding *21: a default (0–100) user was shown the
        // WHOOP-scaled number here while the hero + Workouts table showed 0–100, two numbers for one workout.
        return UnitFormatter.effortDisplay(s, scale: effortScale)
    }

    private func workoutSub(_ w: WorkoutRow) -> String {
        var parts: [String] = []
        let secs = w.durationS ?? Double(max(w.endTs - w.startTs, 0))
        parts.append("\(Int(secs / 60)) min")
        if let dm = w.distanceM, dm > 0 { parts.append(UnitFormatter.distanceFromMeters(dm, system: unitSystem)) }
        if let k = w.energyKcal { parts.append("\(Int(k.rounded())) kcal") }
        return parts.joined(separator: " · ")
    }

    private var dateLine: String {
        // #1013: localize the sub-header date. The old en_US_POSIX "EEEE, d MMMM" formatter forced English
        // weekday + month names regardless of the UI language. A locale-aware field template localizes both
        // the names AND the field order (e.g. fr "mercredi 4 juillet") in the user's locale.
        return selectedLogicalDay.formatted(
            .dateTime.weekday(.wide).day().month(.wide).locale(AppLanguage.activeLocale))
    }

    /// Provenance caption for the recovery-vitals card, keyed on the row a vital actually came from — NOT a
    /// hardcoded "yesterday". If ANY shown vital fell back to `vitalsDay` (today's own value is nil and the
    /// carried row supplies it), it stamps that row's date via the shared `TodayView.carriedCaption`, so a
    /// genuine post-rollover carry reads "Last night · <date>" and a weeks-old carry relabels to
    /// "Latest sleep · <date>" (#779) instead of a false "Last night". When every shown vital is today's
    /// own (or there's nothing to carry), it returns nil — the card must not claim "Last night" at all.
    private var vitalsProvenanceLine: String? {
        guard let carried = vitalsDay else { return nil }
        let carriedHrv = displayDay?.avgHrv == nil && carried.avgHrv != nil
        let carriedRhr = displayDay?.restingHr == nil && carried.restingHr != nil
        let carriedResp = displayDay?.respRateBpm == nil && carried.respRateBpm != nil
        guard carriedHrv || carriedRhr || carriedResp else { return nil }
        return TodayView.carriedCaption(priorDayKey: carried.day,
                                        todayKey: displayDay?.day ?? selectedDayKey)
    }
}

/// Carries the Today scroll's top overscroll offset up to the view for the custom liquid pull-to-refresh.
private struct PullOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - NOOP wordmark (centred, with a tap easter egg)

/// The subtle NOOP wordmark. Built as a row of letters (not `Text(...).tracking()`, which adds a
/// trailing gap after the last glyph and pushes the word off-centre), so it sits DEAD centre. Tap it
/// for a little easter egg: it plays one of several random one-shot animations — wiggle, shake, flip,
/// spin, bounce, or a jelly squash — with a light haptic.
private struct LiquidWordmark: View {
    @State private var rot = 0.0      // z-rotation (wiggle / spin)
    @State private var scaleX = 1.0   // horizontal scale (jelly squash)
    @State private var scaleY = 1.0   // vertical scale (bounce / jelly)
    @State private var dx = 0.0       // horizontal offset (shake)
    @State private var flip = 0.0     // y-axis 3D flip
    @State private var token = 0      // drives the tap haptic

    var body: some View {
        // Smaller AND brighter: the wordmark should cost less height between the header and the scores while
        // reading more like a mark and less like a watermark.
        HStack(spacing: 10) {
            ForEach(Array("NOOP".enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(StrandFont.rounded(13, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.9))
            }
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 1)
        .rotationEffect(.degrees(rot))
        .scaleEffect(x: scaleX, y: scaleY)
        .offset(x: dx)
        .rotation3DEffect(.degrees(flip), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .contentShape(Rectangle())
        .onTapGesture { playRandomEgg() }
        .liquidTapHaptic(trigger: token)
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }

    /// The easter egg: one of several one-shot animations at random. The oscillating ones (wiggle/shake/
    /// squash) kick the value to an extreme then let an under-damped spring settle it back through zero,
    /// which reads as a natural wobble without hand-authored keyframes.
    private func playRandomEgg() {
        token &+= 1
        switch Int.random(in: 0..<6) {
        case 0: // wiggle
            rot = -14
            withAnimation(.spring(response: 0.5, dampingFraction: 0.28)) { rot = 0 }
        case 1: // shake
            dx = -12
            withAnimation(.spring(response: 0.45, dampingFraction: 0.26)) { dx = 0 }
        case 2: // flip
            withAnimation(.easeInOut(duration: 0.6)) { flip += 360 }
        case 3: // spin
            withAnimation(.easeInOut(duration: 0.55)) { rot += 360 }
        case 4: // bounce
            scaleX = 1.28; scaleY = 1.28
            withAnimation(.spring(response: 0.5, dampingFraction: 0.42)) { scaleX = 1; scaleY = 1 }
        default: // jelly (squash + stretch)
            scaleX = 1.35; scaleY = 0.7
            withAnimation(.spring(response: 0.5, dampingFraction: 0.3)) { scaleX = 1; scaleY = 1 }
        }
    }
}

// MARK: - Hero score cell (count-up number over a filling vessel, tap-to-splash)

/// One of the three hero scores (Charge / Effort / Rest). The vessel fills from empty and the number
/// COUNTS UP to the value when data lands; tapping the gauge itself splashes (the number is
/// hit-transparent so the tap reaches the vessel). The label row taps through to the scoring guide.
private struct HeroScoreCell: View {
    static let vesselDiameter: CGFloat = 96

    let label: String
    let score: Double?            // on whatever scale the caller passes (nil = no data yet)
    let tint: Color
    let animated: Bool
    let onGuide: () -> Void
    // The scale `score` is already expressed on — 100 for Charge/Rest, or the user's chosen Effort scale
    // max (100 or 21, #45) — so the vessel fill matches the displayed number.
    var maxValue: Double = 100
    // Decimal places for the displayed number. 0 keeps the whole-number scores; the WHOOP 0–21 Effort
    // scale passes 1 to match the app-wide one-decimal `effortDisplay` convention (#45).
    var decimals: Int = 0

    var body: some View {
        VStack(spacing: 7) {
            // The vessel + count-up read-out now come from the shared `LiquidScoreGauge`
            // (LiquidPrimitives.swift), which Sleep's hero uses too. Same geometry and the same
            // hit-transparent number, so a tap still falls through to the vessel → splash.
            // `numberColor` is pinned white: this card's fill stays dark in BOTH themes.
            LiquidScoreGauge(
                score: score,
                tint: tint,
                diameter: Self.vesselDiameter,
                animated: animated,
                maxValue: maxValue,
                decimals: decimals,
                numberColor: .white
            )
            HStack(spacing: 4) {
                Button(action: onGuide) {
                    HStack(spacing: 3) {
                        // #74: one line, shrink-to-fit rather than wrap under large Dynamic Type (mirrors the
                        // score number above) so CHARGE/EFFORT/REST never grow the hero card to two lines.
                        Text(label.uppercased()).font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).opacity(0.6)
                    }
                    // The hero card fill is pinned dark in BOTH themes, so the CHARGE/EFFORT/REST label must use
                    // the scheme-invariant on-dark token — textSecondary flips to dark ink in Light mode and
                    // went dark-on-near-black here (#1013).
                    .foregroundStyle(StrandPalette.onDarkSecondary)
                }
                .buttonStyle(.plain)
            }
            .accessibilityLabel(Text("\(label), \(score.map { decimals > 0 ? String(format: "%.\(decimals)f", locale: AppLanguage.activeLocale, $0) : String(Int($0.rounded())) } ?? String(localized: "no data yet")). See how it is scored."))
        }
        .frame(maxWidth: .infinity)
    }
}


// MARK: - Scene controls (LiveState-isolated leaves)

/// The liquid pull-to-refresh vessel + a "Syncing…" label. A pure gesture affordance: it answers "did my
/// pull do anything", and nothing else.
///
/// It used to ALSO hold itself up for the whole of `live.backfilling`, because `ble.syncNow()` kicks off a
/// BLE history offload that far outlives the local `refreshing` flag (which flips false ~350ms after the
/// pull releases), and at the time the only other feedback was the easy-to-miss header `SyncStatusChip`.
/// `LiquidBatteryButton` is now that feedback — an ambient, always-on-screen signal that carries a live
/// chunk count — so the long tail belongs there and the vessel hands off to it instead of shadowing it.
/// Two surfaces reporting one signal is what this replaces: a 64pt banner AND a morphing header, both
/// running their own 60Hz clock (`LiquidVessel` has one too) for the same multi-hour offload.
///
/// No longer reads LiveState at all, so it is no longer an isolated leaf — there is nothing left to
/// isolate it from.
private struct LiquidRefreshIndicator: View {
    let pullY: CGFloat
    let pullThreshold: CGFloat
    let refreshing: Bool
    let liquidHeart: Color

    private var progress: CGFloat { min(1, max(0, pullY / pullThreshold)) }

    var body: some View {
        ZStack {
            if refreshing {
                VStack(spacing: 6) {
                    LiquidVessel(value: 0.6, tint: liquidHeart, animated: true)
                        .frame(width: 34, height: 34)
                    Text("Syncing…")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            } else if pullY > 2 {
                LiquidVessel(value: progress, tint: liquidHeart, animated: false)
                    .frame(width: 30, height: 30)
                    .opacity(progress)
                    .scaleEffect(0.7 + 0.3 * progress)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: refreshing ? 64 : min(pullY, pullThreshold * 1.15))
        .animation(.easeOut(duration: 0.22), value: refreshing)
    }
}

/// The ONE debounce for the raw "a sync is happening" signal, for any surface that reflects it.
///
/// `live.backfilling` toggles false→true between EVERY offload chunk (`exitBackfilling` at each
/// HISTORY_END → auto-continue re-kick → `beginBackfill`), with a real BLE round-trip gap in between, and
/// a deep backlog is up to ~24 chunks in ONE connection (#594 raised the auto-continue cap 6→24). Bound
/// straight to that signal, an indicator strobes in and out on every chunk boundary. (The MenuBar header
/// pins a constant height for the same reason — see MenuBarContent.)
///
/// Rises INSTANTLY, and falls only after riding out `syncIndicatorSignalDebounceNanoseconds` with no new
/// chunk. Written once on purpose: this existed as two hand-rolled copies with the delay spelled two
/// different ways, and the failure mode of letting them drift — an indicator that flickers only against a
/// strap carrying hours of history — is not reproducible at a desk.
private struct DebouncedSyncSignal: ViewModifier {
    let raw: Bool
    @Binding var debounced: Bool
    @State private var hideTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onAppear { apply(raw) }
            .onChangeCompat(of: raw) { apply($0) }
            .onDisappear { hideTask?.cancel() }
    }

    private func apply(_ raw: Bool) {
        hideTask?.cancel()
        guard !raw else {
            debounced = true                        // a sync is active — show at once
            return
        }
        guard debounced else { return }
        // Might just be the gap between two chunks — wait it out; a new chunk cancels this.
        hideTask = Task { @MainActor in
            try? await Task.sleep(
                nanoseconds: StrandMotion.syncIndicatorSignalDebounceNanoseconds
            )
            guard !Task.isCancelled else { return }
            debounced = false
        }
    }
}

private extension View {
    /// Drive `debounced` from the raw sync signal through the shared debounce above.
    func debouncedSyncSignal(_ raw: Bool, into debounced: Binding<Bool>) -> some View {
        modifier(DebouncedSyncSignal(raw: raw, debounced: debounced))
    }
}

/// Carries the trailing header cluster's measured width out to the day title's fade mask, so the reserve
/// is whatever the controls actually occupy — including the sync capsule mid-expansion.
private struct HeaderControlsWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Gap between the round Today-header controls. iOS tightens it so the sync capsule has room to expand
/// on a phone-width header without crowding the day title; macOS has the window width to spare, so it
/// opens the cluster up instead of paying for space it does not need.
#if os(iOS)
private let headerClusterSpacing = NoopMetrics.space1
#else
private let headerClusterSpacing = NoopMetrics.space3
#endif

private struct LiquidAddButton: View {
    @EnvironmentObject var router: NavRouter
    var body: some View {
        Button { router.requestQuickActions() } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(
                    width: NoopMetrics.compactControlSize,
                    height: NoopMetrics.compactControlSize
                )
        }
        .nativeLiquidGlassHeaderButton()
        .accessibilityLabel("Quick actions")
    }
}

/// The Updates-inbox bell — brings the classic Today's bell (`TodayView.swift`'s `updateBell`) to Liquid
/// Today, same store, same inbox, matching this row's existing icon pattern rather than the classic
/// bell's larger 36pt one.
private struct LiquidUpdatesBellButton: View {
    @EnvironmentObject var updateStore: UpdateStore
    @Binding var showUpdatesInbox: Bool
    var body: some View {
        Button { showUpdatesInbox = true } label: {
            Image(systemName: updateStore.unreadCount > 0 ? "bell.badge" : "bell")
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: LiquidHeaderMetrics.control, height: LiquidHeaderMetrics.control)
                .background(Circle().fill(StrandPalette.surfaceInset.opacity(0.6)))
                .overlay(alignment: .topTrailing) {
                    if updateStore.unreadCount > 0 {
                        Text("\(min(updateStore.unreadCount, 99))")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .frame(minWidth: 12, minHeight: 12)
                            .background(Circle().fill(StrandPalette.statusCritical))
                            .offset(x: 3, y: -3)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(LiquidPressStyle())
        .accessibilityLabel("Updates")
    }
}

/// Shared quiet, full-width navigation affordance used for a secondary dashboard destination.
/// The containing NavigationLink owns the destination and pressed interaction; this view owns one
/// consistent token-based surface, typography, geometry, and trailing chevron.
private struct LiquidFullWidthNavigationAction: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        HStack(spacing: NoopButtonMetrics.iconSpacing) {
            Text(title)
                .font(StrandFont.subhead.weight(.semibold))
            Spacer(minLength: NoopMetrics.space2)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
        }
        .foregroundStyle(StrandPalette.accent)
        .padding(.horizontal, NoopButtonMetrics.hPadding)
        .frame(maxWidth: .infinity)
        .frame(height: NoopButtonMetrics.height)
        .frame(minHeight: NoopButtonMetrics.minHitTarget)
        .contentShape(Rectangle())
        .background(NoopPanelSurface(cornerRadius: NoopButtonMetrics.cornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: NoopButtonMetrics.cornerRadius, style: .continuous))
    }
}

/// Static technical grid behind the live trace. Canvas draws only when layout/style changes, so the
/// incoming heart-rate samples remain the card's sole animation driver.
private struct LiquidHeartRateGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            let columns = 8
            let rows = 4

            for column in 1..<columns {
                let x = size.width * CGFloat(column) / CGFloat(columns)
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for row in 1..<rows {
                let y = size.height * CGFloat(row) / CGFloat(rows)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }

            context.stroke(path,
                           with: .color(StrandPalette.hairline.opacity(0.34)),
                           lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension LiquidTodayView {
    /// What the strap-battery ring can honestly say, resolved from the three live signals it has.
    /// Pure + static so the truth table is testable with no strap (`LiquidBatteryDisplayTests`).
    ///
    /// The three signals are INDEPENDENT and land separately, which is the whole reason this exists:
    ///  • `connected` — the CoreBluetooth link.
    ///  • `batteryPct` — standard 0x2A19 (5/MG) or the GET_BATTERY_LEVEL response (4.0).
    ///  • `charging` — a different source entirely: the strap's BATTERY_LEVEL event (~every 8 min),
    ///    which keeps arriving live even mid-offload (`FrameRouter`, "flag only — battery % keeps its
    ///    family-specific source", #77).
    ///
    /// So "charging, but no % yet" is REACHABLE, not hypothetical. The old code nested the bolt inside
    /// `if let pct`, so that state rendered as `bolt.slash` — a crossed-out bolt at a wearer whose strap
    /// was on the charger, which reads as "battery dead". And it drew the ring on `batteryPct` alone with
    /// no `connected` gate: `LiveState.batteryPct` is never cleared (`clearBiometrics` deliberately leaves
    /// it), so a dead strap kept showing its last % as if live — a 21 h old reading rendered identically
    /// to a fresh one. Gating on `connected` here also makes this ring agree with `LiquidStrapBatteryRow`
    /// directly below it, which already required `live.connected`.
    /// The Effort hero's "no cardio load yet" honest note (#530 follow-up — Liquid parity with classic
    /// `TodayView.effortZeroNote`). Pure + static so the gate is testable with no view: the note shows
    /// ONLY for today when a strain value exists and is ~0 — a genuinely calm day reads near zero, while a
    /// no-data day shows its own ring overlay and a past day is never annotated. Liquid reads
    /// `effortValue` — the same live-floored-by-stored figure its Effort hero draws, now that this screen
    /// resolves Effort through `StrainScorer.effectiveEffort` like classic Today does.
    enum EffortDisplay {
        static func showsZeroNote(strain: Double?, isToday: Bool) -> Bool {
            guard isToday, let s = strain else { return false }
            return s < 1.0
        }
    }

    /// (A3/B2, docs/bugs/2026-07-15-strap-battery-backfill-observability.md)
    typealias StrapBatteryDisplay = StrapBatteryDisplayState
}

/// Strap-battery ring. At sync start it briefly expands within the trailing control row, then settles into
/// an in-place spinner; the layered header keeps either state from moving the Today content. Tap → Devices.
private struct LiquidBatteryButton: View {
    @EnvironmentObject var live: LiveState
    @EnvironmentObject var router: NavRouter

    /// Debounced by `debouncedSyncSignal` below, so a per-chunk `backfilling` gap cannot flash the
    /// indicator back to the battery reading in the middle of one logical sync.
    @State private var syncing = false
    #if DEBUG
    /// Driven only by the `--demo-sync` harness; ignored entirely when that flag is absent.
    @State private var demoSyncing = false
    /// Synthetic chunk tally for the harness, so the expanded read-out is exercised without a strap.
    /// Kept local rather than written into LiveState — a demo aid must not touch real collector state.
    @State private var demoChunks = 0
    #endif

    /// The raw, confirmed "strap history is syncing" signal.
    ///
    /// Pull-to-refresh is not evidence of an offload: `syncNow()` can still decline after its
    /// connected/bonded gate when the connection handshake or backing store is not ready. A successful
    /// `beginBackfill()` publishes `live.backfilling` synchronously, so that state is both prompt and the
    /// only honest source for the header and its VoiceOver label.
    private var syncingRaw: Bool {
        #if DEBUG
        if DemoSyncHarness.active { return demoSyncing }
        #endif
        return live.backfilling
    }

    private var batteryDisplay: LiquidTodayView.StrapBatteryDisplay {
        #if DEBUG
        if DemoSyncHarness.active {
            return .resolve(
                connected: true,
                batteryPct: DemoSyncHarness.batteryPercent,
                charging: DemoSyncHarness.charging
            )
        }
        #endif
        return .resolve(
            connected: live.connected,
            batteryPct: live.batteryPct,
            charging: live.charging
        )
    }

    private var indicatorState: ChargeSyncIndicator.BatteryState {
        switch batteryDisplay {
        case .offline:
            return .offline
        case .pending(let charging):
            return .pending(charging: charging)
        case .charge(let percent, let charging):
            return .charge(percent: percent, charging: charging)
        }
    }

    var body: some View {
        NavigationLink(value: TabRoute.battery) {
            ChargeSyncIndicator(
                batteryState: indicatorState,
                syncing: syncing,
                chunks: syncChunks
            )
        }
        .nativeLiquidGlassSyncButton()
        .accessibilityLabel(batteryAccessibility)
        .debouncedSyncSignal(syncingRaw, into: $syncing)
        // DEBUG-gated at the CALL SITE too, not just in the body: in Release the harness must cost
        // literally nothing, rather than an async task created and immediately returned per appearance.
        #if DEBUG
        .task { await runDemoSyncCycleIfNeeded() }
        #endif
    }

    /// DEBUG `--demo-sync` only: loop the syncing signal so the charge→sync morph plays in both
    /// directions without a strap. Returns immediately in Release and whenever the flag is absent, and
    /// `.task` cancels it on disappear.
    private func runDemoSyncCycleIfNeeded() async {
        #if DEBUG
        guard DemoSyncHarness.active else { return }
        while !Task.isCancelled {
            try? await Task.sleep(
                nanoseconds: UInt64(DemoSyncHarness.idleSeconds * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            demoChunks = 0
            demoSyncing = true
            // Tick the tally the way an offload does, so the expanded label is watched changing rather
            // than appearing once and holding.
            for tick in 1...DemoSyncHarness.chunkTicks {
                try? await Task.sleep(
                    nanoseconds: UInt64(DemoSyncHarness.chunkIntervalSeconds * 1_000_000_000)
                )
                guard !Task.isCancelled else { return }
                demoChunks = tick
            }
            demoSyncing = false
        }
        #endif
    }

    /// Chunks acked this session, shown inside the spinner where the battery percentage sits. The
    /// expanded label stays "Syncing" — this is the numeric read-out, not the caption.
    private var syncChunks: Int {
        #if DEBUG
        if DemoSyncHarness.active { return demoChunks }
        #endif
        return live.syncChunksThisSession
    }

    /// Never "Strap battery" alone for a no-reading state — that was indistinguishable from a real one.
    private var batteryAccessibility: String {
        if syncing {
            // `syncChunks` is a COUNT, not an index, so it reads "3 chunks" — the phrasing the Android
            // twin and `SyncStatusChip` already use. Reusing that exact key also means this read-out
            // inherits its existing translations rather than adding an untranslated variant.
            //
            // The SAME accessor the ring draws from, not `live.syncChunksThisSession` directly: in
            // Release the two are identical, but under `--demo-sync` reading LiveState here would have
            // VoiceOver announcing a real count while the ring showed the synthetic one — i.e. the
            // harness could not be used to check the read-out it exists to exercise.
            let n = syncChunks
            return n > 0
                ? String(localized: "Syncing strap history, \(n) chunks")
                : String(localized: "Syncing strap history")
        }

        switch batteryDisplay {
        case .offline:
            return String(localized: "Strap battery, strap not connected")
        case .pending(let charging):
            return charging
                ? String(localized: "Strap battery charging, no reading yet")
                : String(localized: "Strap battery, no reading yet")
        case .charge(let percent, let charging):
            let n = Int(percent.rounded())
            return charging
                ? String(localized: "Strap battery \(n) percent, charging")
                : String(localized: "Strap battery \(n) percent")
        }
    }
}

private extension View {
    /// The edge-to-edge photo is overlaid after the native button style so it can fill the face. Finish
    /// the composed control with interactive system glass as the topmost visual layer; otherwise the
    /// opaque photo would conceal the button style's refraction and highlight. macOS keeps the photo
    /// as-is (Liquid Glass is iOS-only).
    @ViewBuilder
    func nativeLiquidGlassPhotoFinish() -> some View {
        self.nativeLiquidGlassCircleFinish()
    }

    /// Platform-owned Home-header button chrome. iOS 26 supplies the interactive Liquid Glass button
    /// material; macOS and older iOS keep the same circular geometry with a native system material.
    @ViewBuilder
    func nativeLiquidGlassHeaderButton() -> some View {
        self.nativeLiquidGlassButtonChrome(controlSize: .small) {
            self
                .buttonStyle(LiquidPressStyle())
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.8))
        }
    }

    /// Exact-bounds glass for the charge-to-sync morph. The same Capsule stretches only while its label
    /// expands. Not `nativeLiquidGlassButtonChrome(capsule:)`: `.buttonBorderShape(.capsule)` applies the
    /// system's capsule metrics, which pad wider than tall and render the compact 36-point state as a
    /// pill — hence the manual, equal padding here, which keeps it circular.
    ///
    /// iOS 26 matches the sibling `.glass` circles, whose own `.small` chrome insets the label by the
    /// same amount. The fallbacks add no padding: their siblings draw the material straight onto a
    /// 36-point label, so a Capsule over the identical 36×36 frame is already that circle.
    @ViewBuilder
    func nativeLiquidGlassSyncButton() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.plain)
                .padding(NoopMetrics.syncIndicatorGlassPadding)
                .glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self
                .buttonStyle(LiquidPressStyle())
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.8))
        }
        #else
        self
            .buttonStyle(LiquidPressStyle())
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.8))
        #endif
    }
}

/// Strap-history sync state inside the Data Sources card. Owns LiveState; display-only.
///
/// B1 (docs/bugs/2026-07-15-strap-battery-backfill-observability.md): the v8 Liquid redesign shipped no
/// backfill indication AT ALL, so on the iOS default Today a multi-hour history recovery was completely
/// invisible — the wearer could not tell a working strap mid-drain from a dead one. The classic
/// `TodayView` has always had this (`SyncStatusChip`), as do the Mac Sleep/Intelligence screens and the
/// menu bar (`SyncingHistoryNote`); Liquid simply dropped it. Same class of regression as #992, which
/// dropped the "~X days left" runtime estimate from the row directly above this one.
///
/// Deliberately scoped to what LiveState can honestly answer: THAT a drain is running, how many chunks
/// it has pulled, and when one last completed. It does NOT yet say "~15h behind" — that needs the
/// persisted data frontier (max HR ts) compared against `strapRange.newestUnix`, and the frontier is a
/// Repository read that LiveState does not carry. That remains open in B1. Kept here in the Data Sources
/// card as the detailed view; `LiquidBatteryButton` above is the header's ambient at-a-glance signal.
private struct LiquidSyncStatusRow: View {
    @EnvironmentObject var live: LiveState
    var body: some View {
        if live.backfilling {
            row(String(localized: "Strap history"), value: chunks, tone: StrandPalette.accent)
        } else if let ts = live.lastSyncedAt {
            row(String(localized: "Strap history"),
                value: String(localized: "Synced \(relativeAgo(ts))"), tone: StrandPalette.textPrimary)
        }
    }

    /// "Syncing…" alone reads as a spinner that might be stuck; the chunk count is the cheapest available
    /// proof that the drain is actually moving. Suppressed at zero — a session that has pulled nothing yet
    /// should not claim "0 chunks pulled" as if that were progress.
    private var chunks: String {
        live.syncChunksThisSession > 0
            ? String(localized: "Syncing… \(live.syncChunksThisSession) chunks")
            : String(localized: "Syncing…")
    }

    private func row(_ label: String, value: String, tone: Color) -> some View {
        HStack {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Text(value).font(StrandFont.subhead).foregroundStyle(tone)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The strap-battery readout inside the Data Sources card. Owns LiveState; display-only.
private struct LiquidStrapBatteryRow: View {
    @EnvironmentObject var live: LiveState
    var body: some View {
        if live.connected, let pct = live.batteryPct {
            HStack {
                Text("Strap battery").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                // #972: append "· Charging"; #992: append the "~X days left" runtime the v8 redesign dropped.
                Text(batteryText(pct: pct))
                    .font(StrandFont.number(15)).foregroundStyle(StrandPalette.textPrimary)
            }
        }
    }

    /// "87%" plus a trailing "· Charging" (#972) or "· ~9 days left" runtime (#992), matching the Settings /
    /// Mac / Android pill and the classic Today badge.
    private func batteryText(pct: Double) -> String {
        let base = "\(Int(pct.rounded()))%"
        if live.charging == true { return "\(base) · \(String(localized: "Charging"))" }
        if let est = estimateText { return "\(base) · \(est)" }
        return base
    }

    /// #992: the v8 Liquid redesign dropped the "~X days left" estimate the classic Today showed (#713).
    /// This was a verbatim copy of `TodayView.estimateText`; both now call the shared
    /// `StrapBatteryCopy.runtimeBadge`, so the wording and the 48-hour boundary have one home.
    private var estimateText: String? {
        StrapBatteryCopy.runtimeBadge(hoursRemaining: live.batteryEstimate?.hoursRemaining,
                                      charging: live.charging == true)
    }
}

// MARK: - Cross-platform chrome helpers
//
// The liquid Today is shared with the macOS target now (the mac split-view shell hosts it too). A few of
// its chrome modifiers are iOS-only, so they are wrapped here: `topBarTrailing` + `navigationBarTitleDisplayMode`
// don't exist on macOS, and `presentationCompactAdaptation` is an iOS phone-width concern. These keep the
// exact iOS behaviour while giving macOS the platform-correct equivalent.
private extension View {
    /// A sheet's trailing "Done" button (inline title on iOS; the confirmation-action toolbar slot on macOS).
    @ViewBuilder func liquidSheetDoneChrome(done: @escaping () -> Void) -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: done).foregroundStyle(StrandPalette.accent)
                }
            }
        #else
        self.toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", action: done).foregroundStyle(StrandPalette.accent)
            }
        }
        #endif
    }

    /// Keep a popover a popover in compact width (iOS 16.4+); a no-op on macOS where popovers never adapt.
    @ViewBuilder func liquidPopoverAdaptation() -> some View {
        #if os(iOS)
        if #available(iOS 16.4, *) { self.presentationCompactAdaptation(.popover) } else { self }
        #else
        self
        #endif
    }

}

// Not fileprivate like the chrome helpers above: the iOS tab shell (`RootTabView`) presents the guardian
// now that its entry lives in the quick-action menu, and the macOS Today row presents it from here — one
// helper, one presentation style per platform, two call sites.
extension View {
    /// Present the Live Session screen: fullScreenCover on iOS (the guardian owns the display mid-
    /// workout), a plain sheet on macOS where fullScreenCover doesn't exist. The session view calls
    /// `onClose` itself once the summary is dismissed.
    @ViewBuilder func liveSessionCover(isPresented: Binding<Bool>) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #else
        self.sheet(isPresented: isPresented) {
            LiveSessionView(onClose: { isPresented.wrappedValue = false })
        }
        #endif
    }
}
