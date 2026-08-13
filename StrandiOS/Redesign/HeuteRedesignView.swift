import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Finale Zusammensetzung (docs/fork/design/design-spec.md §5)
//
// Assembles the four parts with the spacing table from design-spec §5 and loads real data from
// `Repository`. `status` is owned HERE (not inside `ActivityStatusChip`) and threaded to both the
// header chip and the Basiskarte as the same value — otherwise changing status via the chip's sheet
// wouldn't be reflected in the base card, which is the whole point of feature-spec §1/§2.
//
// Data-loading COMPOSES the same carry-over selectors the other two Today screens use — it does not
// re-implement them. This screen used to carry forward "the most recent non-nil value ≤ the selected day"
// for EVERYTHING (Charge, Effort, vitals alike), which is a different rule from the one classic/Liquid
// agree on and could therefore show a different number for the same day:
//  • recovery-derived (Charge) goes through `TodayView.lastScoredRecoveryDay` + `LiquidTodayView
//    .ChargeDisplay.resolve`, so a mid-calibration wearer reads the honest "Learning your baseline, N of
//    4 nights" here too, instead of a stale prior score presented as today's.
//  • raw vitals (HRV / resting HR / respiratory / SpO₂) go through `Repository.lastVitalsDay` /
//    `lastSpo2Day`, which are recovery-INDEPENDENT (a night with real HRV but no recovery is a valid
//    source for a vital, but NOT for Charge — that asymmetry is the whole point of having two selectors).
// `LiquidChargeCarryTests` pins the composition for Liquid on the same basis: "the selection itself is
// NOT re-implemented here … so Liquid and Classic cannot drift." Heute now participates in that.
struct HeuteRedesignView: View {
    @EnvironmentObject private var repo: Repository
    /// Needed for the Weight tile's profile fallback (`Repository.resolveWeightKg`) — every other vital
    /// on this screen comes from `repo`, but weight is the one metric with a user-editable last resort.
    @EnvironmentObject private var profile: ProfileStore

    /// Same key every other screen reads (`Strand/Data/Units.swift`) — the Effort ring must respect
    /// whichever scale the user picked in Settings, not assume one fixed axis (on-device feedback).
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { EffortScale(rawValue: effortScaleRaw) ?? .hundred }
    /// Same key every other screen reads — the Weight tile must respect Imperial/Metric like every other
    /// mass value in the app, not hardcode kg (`MetricCatalog`'s `weight` entry's unit is fixed "kg").
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    @State private var status = ActivityStatusStore.load()
    /// Days back from today (0 = today) — feature-spec/design-spec don't cover day navigation at all;
    /// added from on-device feedback ("keine Tagewechsel-Funktion"). Drives every field `load()` reads.
    @State private var selectedDayOffset = 0
    @State private var readiness = ReadinessEngine.evaluate(days: [], today: nil)
    /// The resolved Charge state — scored / carried / calibrating / no-data. Shared with Liquid Today
    /// (`LiquidTodayView.ChargeDisplay`) rather than reduced to a bare `Double` here, because "no score"
    /// is not the same as "0%": the ring must draw nothing and the base card must say why.
    @State private var chargeDisplay: LiquidTodayView.ChargeDisplay = .noData
    @State private var effort: Double = 0
    @State private var rest: Double = 0
    /// Presents the Charge breakdown (why the value is what it is) when the Charge ring is tapped —
    /// parity with the other two Today screens, where tapping the Charge ring opens the same drivers.
    @State private var showChargeBreakdown = false
    /// The row the breakdown reads, mirroring the ring: today's own scored row, else the carried
    /// last-scored day, so the sheet matches the carried ring instead of being empty at the rollover.
    /// Set in `load()` from the same `priorScored`/`displayDay` the ring resolves — same rule as
    /// `TodayView.chargeBreakdownRow`, so classic and Heute describe the same day.
    @State private var chargeBreakdownRow: DailyMetric?
    @State private var vitalReadings: [String: HeuteVitalReading] = [:]
    /// The selected day's most recent workout, or nil. The grid renders it as a tappable card (sport +
    /// duration/calories + effort), matching the other two Today screens' last-workout affordance.
    @State private var dayWorkout: WorkoutRow?
    /// The selected day's banked HR trace (5-minute buckets) and each bucket's start time, index-aligned.
    /// Kept as its own array rather than derived (midnight + i·5min) because `hrBuckets` returns only
    /// buckets that HAVE data. Feeds the scrubbable HR thread; the live beat-by-beat stream is layered on
    /// top inside `HeuteHeartRateSection`. Mirrors `LiquidTodayView.hrValues`/`hrTimes`.
    @State private var hrValues: [Double] = []
    @State private var hrTimes: [Date] = []
    /// True while a finger is scrubbing the HR thread — gates `daySwipeGesture` so a scrub can't also flip
    /// the day. `hrScrubEndedAt` guards the tail of the same lift (the two gestures' `onEnded` fire in an
    /// unspecified order). Same mechanism as `LiquidTodayView`'s day-swipe suppression.
    @State private var hrScrubbing = false
    @State private var hrScrubEndedAt = Date.distantPast

    /// The coach's pending training proposals — the REAL source for the suggestion cards (was a stubbed
    /// placeholder). Observed so a freshly-proposed session appears without a manual reload. Generation
    /// stays in the coach / `MorningSuggestionCard` flow; Heute only surfaces what's already pending.
    @ObservedObject private var planStore = CoachPlanStore.shared
    @EnvironmentObject private var coach: AICoachEngine
    /// Locally-dismissed proposal ids (swipe hides a card for good WITHOUT declining the proposal). Pruned
    /// to still-pending ids on load so it can't grow without bound.
    @State private var dismissedSuggestions = DismissedSuggestionsStore.load()
    /// Presents the coach plan (accept / modify / decline) when a suggestion card is tapped.
    @State private var showPlan = false

    /// The suggestion cards for the shown day — pure mapping over the pending proposals, gated by activity
    /// status and local dismissals (`HeuteSuggestionCards`). Only today ever yields cards (a pending
    /// proposal carries today's `day`), which also matches the forward-looking nature of a suggestion.
    private var suggestionCards: [NotificationCardItem] {
        HeuteSuggestionCards.cards(pending: planStore.pending, dayKey: selectedDayKey,
                                   status: dayStatus, dismissed: dismissedSuggestions)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HeuteHeaderView(status: $status, selectedDayOffset: $selectedDayOffset,
                                earliestDayOffset: earliestDayOffset)
                HeuteRingsView(charge: chargeDisplay.pct, chargeEmptyLabel: chargeEmptyLabel,
                               effort: effort, rest: rest, effortScale: effortScale,
                               onChargeTap: { showChargeBreakdown = true })
                    .padding(.top, 18)
                // Pinned above the suggestion cards so an active manual workout is immediately visible —
                // same placement rationale as LiquidTodayView's ActiveWorkoutIndicatorSection. Renders
                // nothing when no workout is active.
                HeuteActiveWorkoutIndicatorSection()
                    .padding(.top, 18)
                HeuteCardZoneView(status: dayStatus, readiness: readiness,
                                  calibrationNote: chargeDisplay.calibrationDetail,
                                  cards: suggestionCards,
                                  onDismiss: { item in
                                      dismissedSuggestions.insert(item.id)
                                      DismissedSuggestionsStore.save(dismissedSuggestions)
                                  },
                                  onTap: { showPlan = true })
                    .padding(.top, 30)
                HeuteVitalsGridView(readings: vitalReadings, workout: dayWorkout)
                    .padding(.top, 26)
                // Heart rate — parity with the other two Today screens (Heute was the only one without it).
                // Shown on any day: a past day scrubs its banked trace, only the live layer is inactive.
                // `onScrubChange` gives the thread horizontal dominance over `daySwipeGesture`.
                HeuteHeartRateSection(values: hrValues, times: hrTimes, animated: true,
                                      onScrubChange: { active in
                                          hrScrubbing = active
                                          if !active { hrScrubEndedAt = Date() }
                                      })
                    .padding(.top, 26)
                // Journal reminder + provenance footer, parity with the other two Today screens. Only on
                // today — a navigated past day has no live strap state and no "log today" prompt to make.
                if selectedDayOffset == 0 {
                    JournalReminderCard()
                        .padding(.top, 20)
                    HeuteDataSourcesCard()
                        .padding(.top, 20)
                }
            }
            .padding(.horizontal, NoopMetrics.screenHPadding)
            // A dedicated top value, NOT `screenHPadding` reused sideways — that conflated two different
            // concerns and read as "jammed under the status bar" (on-device feedback). Matches
            // `LiquidTodayView.swift`'s own top padding for its header/title ("sit the title lower into
            // the sky, not jammed under the status bar") — the concrete reference the feedback asked for.
            .padding(.top, 30)
            // The platform tab bar is part of the safe area, so no extra reserve is needed — see the
            // same note in `ScreenScaffold`.
            .padding(.bottom, 24)
        }
        // Pull-to-refresh / manual strap sync — the other two Today screens have this via
        // ScreenScaffold's onRefresh (which is exactly this under the hood); Heute doesn't use
        // ScreenScaffold, so it needs its own .refreshable.
        .refreshable { await repo.refresh() }
        .background(HeuteRedesignPalette.bg.ignoresSafeArea())
        .sheet(isPresented: $showPlan) { CoachPlanView().environmentObject(coach) }
        .sheet(isPresented: $showChargeBreakdown) {
            HeuteChargeBreakdownSheet(row: chargeBreakdownRow, days: repo.days,
                                      restScore: rest > 0 ? rest : nil, chargeDisplay: chargeDisplay)
        }
        .simultaneousGesture(daySwipeGesture)
        // repo.refreshSeq in the id (mirrors LiquidTodayView.swift/TodayView.swift): without it, a strap
        // sync or backfill completing while Heute is open never triggers a reload.
        .task(id: "\(repo.refreshSeq)-\(selectedDayOffset)") { await load() }
    }

    /// Whole days from today's logical day back to the earliest banked day — the lower bound the day-swipe
    /// and the header chevrons clamp to (0 when there's no history, so today is the only reachable day).
    /// Reuses the classic Today's pure helper so the bound can't drift between the two screens.
    private var earliestDayOffset: Int {
        TodayView.maxDayOffset(earliestDayKey: repo.freshness.earliestDay,
                               todayKey: Repository.logicalDayKey(Date()))
    }

    /// The day-nav swipe: a clearly-horizontal drag flips the day (left → older, right → newer), clamped
    /// to `0 ... earliestDayOffset`. Same thresholds and pure clamp as `TodayView.daySwipeGesture`. The
    /// HR thread scrubs horizontally too, so — like Liquid — the swipe stands down while the thread owns
    /// the touch: `hrScrubbing` if this `onEnded` loses the race to the thread's, `hrScrubEndedAt` if it
    /// wins it (the two fire in an unspecified order on lift). The thread's lower `minimumDistance` (2 vs
    /// 24) means it engages first and sets the flag before this can end.
    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                guard !hrScrubbing, Date().timeIntervalSince(hrScrubEndedAt) > 0.4 else { return }
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50 else { return }
                let delta = dx < 0 ? 1 : -1
                let next = TodayView.clampedDayOffset(current: selectedDayOffset, delta: delta,
                                                      maxOffset: earliestDayOffset)
                guard next != selectedDayOffset else { return }
                withAnimation(StrandMotion.interactive) { selectedDayOffset = next }
            }
    }

    /// The manual activity status AS IT APPLIES TO THE SELECTED DAY. `ActivityStatus` is a *current*
    /// state (`validUntil`, silent reset — feature-spec §1); it is not recorded per day, so it can only
    /// honestly describe today. Navigating back therefore shows the normal computed readiness statement
    /// instead of retro-applying today's "Sick"/"Injured"/"On break" override to a past day.
    private var dayStatus: ActivityStatus {
        selectedDayOffset == 0 ? status : .active
    }

    /// What the Charge ring says INSTEAD of a number when there is nothing honest to draw. `.carried`
    /// still draws a real number (the prior night's), so only the two genuinely empty states land here.
    private var chargeEmptyLabel: String? {
        switch chargeDisplay {
        case .scored, .carried: return nil
        case .calibrating, .noData: return chargeDisplay.stateLabel
        }
    }

    /// The row the selected day actually shows: today prefers the live `repo.today` (so the small hours
    /// after midnight still read the logical day's banked row), a past day looks its own row up by key.
    /// Same resolution as `TodayView.displayDay` / `LiquidTodayView.resolveDisplayDay`.
    private var displayDay: DailyMetric? {
        if selectedDayOffset == 0 { return repo.today ?? repo.days.last(where: { $0.day == selectedDayKey }) }
        return repo.days.last(where: { $0.day == selectedDayKey })
    }

    /// The LOGICAL day the screen is showing. Offset 0 is today's logical day (rolls at 04:00 like
    /// `repo.today`), past offsets count back from it — same construction as `TodayView.selectedLogicalDay`.
    /// Raw calendar subtraction from `Date()` made "Today" and "Yesterday" resolve to the same date in the
    /// 00:00–04:00 window.
    private var selectedLogicalDay: Date {
        let base = Repository.logicalDay(Date())
        return Calendar.current.date(byAdding: .day, value: -selectedDayOffset, to: base) ?? base
    }

    /// `yyyy-MM-dd` of the selected logical day — what a timestamp's own `logicalDayKey` is compared to.
    private var selectedLogicalDayKey: String { Repository.localDayKey(selectedLogicalDay) }

    /// The day key the day-scoped read-outs key on. Same semantics as `TodayView.selectedDayKey`: at
    /// offset 0 follow `repo.today?.day` so it tracks the row the resolver actually surfaces (including
    /// the non-UTC pre-04:00 case where Today is the LOCAL-calendar-day row), otherwise the logical key.
    private var selectedDayKey: String {
        if selectedDayOffset == 0, let todayKey = repo.today?.day { return todayKey }
        return selectedLogicalDayKey
    }

    private func load() async {
        // Re-resolve the silent `validUntil` fallback on every (re)load, not just once at view creation —
        // a screen left open across the expiry would otherwise keep showing the stale exception state.
        let resolvedStatus = ActivityStatusStore.load()
        if resolvedStatus != status { status = resolvedStatus }

        // Prune locally-dismissed suggestion ids to the still-pending set, so the store can't accumulate
        // ids for proposals that were long since decided or aged out.
        let pruned = DismissedSuggestionsStore.load(keepingOnly: Set(planStore.pending.map { $0.id.uuidString }))
        if pruned != dismissedSuggestions { dismissedSuggestions = pruned }

        let key = selectedDayKey
        let day = displayDay
        let isToday = selectedDayOffset == 0
        // The key every carry is BOUNDED by — the row's own key when one exists, so a carry can never
        // echo today's still-forming row. Mirrors `LiquidTodayView.load()`'s `tkey`.
        let tkey = day?.day ?? key

        // Calibration comes from the SAME `RecoveryScorer` helper both other screens read, so all three
        // agree on when a wearer is genuinely mid-calibration rather than simply lacking a scored night.
        let calNights = isToday
            ? RecoveryScorer.calibrationNights(nightlyHrv: repo.days.map(\.avgHrv),
                                               dayKeys: repo.days.map(\.day),
                                               hasRecovery: day?.recovery != nil)
            : nil
        let priorScored = TodayView.lastScoredRecoveryDay(days: repo.days, selectedDayKey: tkey,
                                                          isToday: isToday,
                                                          todayScored: day?.recovery != nil,
                                                          isCalibrating: calNights != nil)
        chargeDisplay = LiquidTodayView.ChargeDisplay.resolve(todayRecovery: day?.recovery,
                                                              priorScored: priorScored,
                                                              calibrationNights: calNights,
                                                              todayKey: tkey)
        // The breakdown reads the same row the ring shows: today's own scored row, else the carried
        // last-scored day (`TodayView.chargeBreakdownRow`'s rule), so the sheet never disagrees with the ring.
        chargeBreakdownRow = priorScored ?? day

        // Readiness anchors on the day whose row carries today's vitals (#543): normally today, but while
        // carrying, the last SCORED day — otherwise `evaluate` reads `.insufficient` right after the
        // rollover and the base card's statement would vanish. Same anchor as `TodayView.computeReadiness`.
        readiness = ReadinessEngine.evaluate(days: repo.days,
                                             today: priorScored?.day ?? Repository.logicalDayKey(Date()))

        // Effort is the day's OWN strain, never carried: strain accumulates within a day, so yesterday's
        // total is not a stand-in for today's — a calm morning honestly reads near zero. (Charge is the
        // opposite: it scores a night that either happened or didn't, hence the carry above.)
        effort = day?.strain ?? 0
        let sleepSeries = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        rest = sleepSeries.last(where: { $0.day <= key })?.value ?? 0

        let fitnessSeries = await repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        let fitnessAge = fitnessSeries.last(where: { $0.day <= key })?.value

        // Liquid Today parity (on-device feedback): Vitality is a simple last-value series read, same
        // shape as fitness_age above.
        let vitalitySeries = await repo.exploreSeries(key: "vitality", source: "my-whoop")
        let vitality = vitalitySeries.last(where: { $0.day <= key })?.value

        // Stress reuses StressModel verbatim (Strand/Screens/StressView.swift) rather than re-deriving the
        // z-score math — off the main actor, mirroring LiquidTodayView.load(), so a long history doesn't
        // stutter this screen's load. Keeping the whole model (not just `.score`) also gives the tile's
        // sparkline for free via `StressModel.sparkValues`.
        let storedStress = await repo.series(key: "stress", source: "my-whoop")
        let daysSnapshot = repo.days
        let stressModel = await Task.detached(priority: .utility) {
            StressModel(days: daysSnapshot, stored: storedStress)
        }.value
        let stress = stressModel?.score
        let stressSpark = stressModel?.sparkValues ?? []

        // Calories: the same imported-first resolution LiquidTodayView.caloriesCount uses, scoped to the
        // selected day only (never carried — a daily accumulator, like Steps).
        let appleRows = await repo.appleDailyRows()
        let importedActiveKcalDay = appleRows.filter { $0.day == key }.compactMap { $0.activeKcal }.max()

        // Weight: same 3-tier resolution as classic/Liquid Today (`Repository.resolveWeightKg`) — a real
        // Apple Health reading (whole-history scan, weight is sparse, not day-scoped like calories/steps),
        // else the newest point in a 90-day "weight" series, else the profile's self-reported value. Never
        // carried per-day; weight doesn't have a "today's own value" concept the way strain/steps do.
        let latestAppleWeightKg = appleRows.filter { ($0.weightKg ?? 0) > 10 }.max { $0.day < $1.day }?.weightKg
        let weightSeries = await repo.series(key: "weight", source: "apple-health", days: 91)
        let resolvedWeight = Repository.resolveWeightKg(latestAppleWeightKg: latestAppleWeightKg,
                                                         seriesFallbackKg: weightSeries.last?.value,
                                                         profileWeightKg: profile.weightKg)
        let weightSpark = weightSeries.map(\.value)

        // Hydration: the day's logged fluid total (ml), or nil when nothing was logged — a real `0` is
        // indistinguishable from "never logged" (HydrationStore), so an unlogged day shows no tile rather
        // than a confusing "0 ml". Heute is the first Today screen to actually wire this (Liquid shows "–").
        // The sparkline is separate from the headline rule: `hydrationHistory` 0-fills unlogged days
        // (mirroring the app's existing 7-day mini-bar precedent), which is fine for a trend line even
        // though a single 0 day must not become the headline value.
        let hydrationTotal = await repo.hydrationTotal(day: key)
        let hydrationMl = hydrationTotal > 0 ? hydrationTotal : nil
        let hydrationSpark = await repo.hydrationHistory(days: 14).map(\.value)

        vitalReadings = buildReadings(day: day, tkey: tkey, isToday: isToday, fitnessAge: fitnessAge,
                                      fitnessAgeSpark: Array(fitnessSeries.suffix(14)).map(\.value),
                                      vitality: vitality, vitalitySpark: Array(vitalitySeries.suffix(14)).map(\.value),
                                      stress: stress, stressSpark: stressSpark,
                                      importedActiveKcalDay: importedActiveKcalDay,
                                      hydrationMl: hydrationMl, hydrationSpark: hydrationSpark,
                                      resolvedWeight: resolvedWeight, weightSpark: weightSpark)

        // Logical-day window, not a raw midnight-to-midnight one: a 01:00 workout belongs to the logical
        // day that is still running, exactly as `CoupledView` buckets workouts.
        let workoutDayKey = selectedLogicalDayKey
        let workouts = await repo.workoutRows(days: 400)
        let dayWorkouts = workouts.filter { w in
            Repository.logicalDayKey(Date(timeIntervalSince1970: TimeInterval(w.startTs))) == workoutDayKey
        }
        dayWorkout = dayWorkouts.max(by: { $0.startTs < $1.startTs })

        // Banked HR trace for the selected day (5-minute buckets). Window mirrors `LiquidTodayView.load()`:
        // today → midnight..now; a past day → its full 24h (a missing morning reads as empty space, not a
        // fabricated flat line).
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedLogicalDay)
        let from = Int(dayStart.timeIntervalSince1970)
        let to = isToday
            ? Int(Date().timeIntervalSince1970)
            : Int((cal.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart).timeIntervalSince1970)
        let hr = await repo.hrBuckets(from: from, to: to, bucketSeconds: 300)
        hrValues = hr.map(\.bpm)
        hrTimes = hr.map { Date(timeIntervalSince1970: TimeInterval($0.ts)) }
    }

    /// Builds the vitals grid using the SAME recovery-independent carry the other two Today screens read:
    /// each vital is resolved today-first (`day?.field`), falling back PER FIELD to the freshest strictly-
    /// prior night that recorded it (`Repository.lastVitalsDay` for HRV/RHR/respiratory; `lastSpo2Day` for
    /// SpO₂, whose predicate the whole-row carry does not check). The carry is bounded by today's own key
    /// and applies only to today — a navigated past day shows its own row verbatim, or nothing.
    private func buildReadings(day: DailyMetric?, tkey: String, isToday: Bool,
                               fitnessAge: Double?, fitnessAgeSpark: [Double],
                               vitality: Double?, vitalitySpark: [Double],
                               stress: Double?, stressSpark: [Double],
                               importedActiveKcalDay: Double?,
                               hydrationMl: Double?, hydrationSpark: [Double],
                               resolvedWeight: (kg: Double, isFromProfile: Bool),
                               weightSpark: [Double]) -> [String: HeuteVitalReading] {
        var out: [String: HeuteVitalReading] = [:]
        let vitalsDay = isToday ? Repository.lastVitalsDay(days: repo.days, todayKey: tkey) : nil
        let spo2Day = isToday ? Repository.lastSpo2Day(days: repo.days, todayKey: tkey) : nil
        let skinTempDay = isToday ? Repository.lastSkinTempDay(days: repo.days, todayKey: tkey) : nil

        // Resolves one vital today-first, else from the given carry row, and stamps the caption with the
        // day the value actually came from. Returns nil when neither has it (→ no tile, the "no empty
        // tiles" rule). The sparkline is the trailing history ≤ the selected day, independent of the carry.
        func reading(_ own: Double?, carry: DailyMetric?, _ extract: @escaping (DailyMetric) -> Double?)
            -> HeuteVitalReading? {
            if let v = own, let d = day {
                return HeuteVitalReading(value: v, asOf: asOfLabel(d.day), sparkline: sparkline(extract))
            }
            if let c = carry, let v = extract(c) {
                return HeuteVitalReading(value: v, asOf: asOfLabel(c.day), sparkline: sparkline(extract))
            }
            return nil
        }

        out["my-whoop:hrv"] = reading(day?.avgHrv, carry: vitalsDay, { $0.avgHrv })
        out["my-whoop:rhr"] = reading(day?.restingHr.map(Double.init), carry: vitalsDay,
                                      { $0.restingHr.map(Double.init) })
        out["my-whoop:resp_rate"] = reading(day?.respRateBpm, carry: vitalsDay, { $0.respRateBpm })
        out["my-whoop:spo2"] = reading(day?.spo2Pct, carry: spo2Day, { $0.spo2Pct })
        if let fitnessAge {
            out["my-whoop:fitness_age"] = HeuteVitalReading(value: fitnessAge, asOf: String(localized: "Weekly"),
                                                             sparkline: fitnessAgeSpark)
        }
        // Steps are a daily accumulator like strain, not an overnight vital — yesterday's total is not a
        // stand-in for today, so this reads the selected day's OWN value and never carries.
        if let steps = day?.steps.map(Double.init) {
            out["apple-health:steps"] = HeuteVitalReading(value: steps, asOf: asOfLabel(tkey),
                                                            sparkline: sparkline({ $0.steps.map(Double.init) }))
        }
        // Liquid Today parity (on-device feedback): Vitality/Stress are weekly/daily composites, not
        // per-night overnight vitals, so no carry — same "Weekly"/today-scoped shape as fitness_age above.
        if let vitality {
            out["my-whoop:vitality"] = HeuteVitalReading(value: vitality, asOf: asOfLabel(tkey),
                                                          sparkline: vitalitySpark)
        }
        if let stress {
            out["my-whoop:stress"] = HeuteVitalReading(value: stress, asOf: asOfLabel(tkey),
                                                        sparkline: stressSpark)
        }
        // Skin temp is a per-night vital like HRV/RHR/SpO2 — same today-first, per-field carry (the
        // dedicated `lastSkinTempDay` selector, mirroring `lastSpo2Day`'s reasoning).
        out["my-whoop:skin_temp"] = reading(day?.skinTempDevC, carry: skinTempDay, { $0.skinTempDevC })
        // Weight: was permanently dead here (registered but never populated, same shape Calories had
        // before D-package 4a). `valueText` overrides the catalog's hardcoded "kg" unit formatting so the
        // Imperial/Metric setting reaches this tile, matching classic Today's `weightTile`. The "From
        // profile" caption on the fallback tier is an honest admission the value isn't a real reading.
        out["apple-health:weight"] = HeuteVitalReading(
            value: resolvedWeight.kg,
            asOf: resolvedWeight.isFromProfile ? String(localized: "From profile") : asOfLabel(tkey),
            sparkline: weightSpark,
            valueText: UnitFormatter.massFromKilograms(resolvedWeight.kg, system: unitSystem))
        // Calories: imported-first (Apple Health active energy for the day) falling back to the on-device
        // estimate, matching LiquidTodayView.caloriesCount — never carried across days, like Steps.
        if let kcal = importedActiveKcalDay ?? day?.activeKcalEst {
            out["my-whoop:energy_kcal"] = HeuteVitalReading(value: kcal, asOf: asOfLabel(tkey),
                                                             sparkline: sparkline({ $0.activeKcalEst }))
        }
        // Special tiles (Liquid Today parity). Sleep: the night's asleep duration (not the Rest SCORE,
        // already a ring) as "7h 32m" — per-night, no carry, matching `LiquidTodayView.sleepText`. Its
        // route is the full Sleep screen (`HeuteVitalsGridView.route`). Hydration: the logged fluid total,
        // routing to the logging screen. Coupled view is a pure nav tile with no value — it needs no
        // reading (rendered by `navOnly`), so it is deliberately absent from `out`.
        if let sleepMin = day?.totalSleepMin {
            out["heute:sleep"] = HeuteVitalReading(value: sleepMin, asOf: asOfLabel(tkey),
                                                   sparkline: sparkline({ $0.totalSleepMin }),
                                                   valueText: "\(Int(sleepMin) / 60)h \(Int(sleepMin) % 60)m")
        }
        if let hydrationMl {
            out["heute:hydration"] = HeuteVitalReading(value: hydrationMl, asOf: asOfLabel(tkey),
                                                        sparkline: hydrationSpark)
        }
        return out
    }

    /// The trailing history ≤ the selected day, capped at the widest trend window (14 days). The tile
    /// trims this to the user's chosen window (`HeuteVitalTile.windowedSparkline`) — loading the 14-day
    /// superset once lets a window change take effect without a reload, matching classic/Liquid Today.
    private func sparkline(_ extract: (DailyMetric) -> Double?) -> [Double] {
        let key = selectedDayKey
        return Array(repo.days.filter { $0.day <= key }.compactMap(extract).suffix(14))
    }

    /// Both "Today" spellings: the logical-day key and, pre-04:00, the local-calendar row the resolver
    /// actually surfaces as Today (`repo.today?.day`, #304).
    private func asOfLabel(_ dayKey: String) -> String {
        let logicalToday = Repository.logicalDay(Date())
        if dayKey == Repository.localDayKey(logicalToday) || dayKey == repo.today?.day {
            return String(localized: "Today")
        }
        if let logicalYesterday = Calendar.current.date(byAdding: .day, value: -1, to: logicalToday),
           dayKey == Repository.localDayKey(logicalYesterday) {
            return String(localized: "Yesterday")
        }
        guard let date = Self.dayFormatter.date(from: dayKey) else { return dayKey }
        // Abbreviated ("Wed"), not the full weekday name — a full name like "Wednesday" was one of the
        // things making the tiles feel cramped on-device (on-device feedback, Fix 4).
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        return f
    }()
}
