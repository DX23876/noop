import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Finale Zusammensetzung (docs/design/design-spec.md §5)
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

    /// Same key every other screen reads (`Strand/Data/Units.swift`) — the Effort ring must respect
    /// whichever scale the user picked in Settings, not assume one fixed axis (on-device feedback).
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { EffortScale(rawValue: effortScaleRaw) ?? .hundred }

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
    @State private var vitalReadings: [String: HeuteVitalReading] = [:]
    /// The selected day's most recent workout, or nil. The grid renders it as a tappable card (sport +
    /// duration/calories + effort), matching the other two Today screens' last-workout affordance.
    @State private var dayWorkout: WorkoutRow?
    @State private var cards: [NotificationCardItem] = HeuteRedesignView.sampleCards

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HeuteHeaderView(status: $status, selectedDayOffset: $selectedDayOffset,
                                earliestDayOffset: earliestDayOffset)
                HeuteRingsView(charge: chargeDisplay.pct, chargeEmptyLabel: chargeEmptyLabel,
                               effort: effort, rest: rest, effortScale: effortScale)
                    .padding(.top, 2)
                HeuteCardZoneView(status: dayStatus, readiness: readiness,
                                  calibrationNote: chargeDisplay.calibrationDetail, cards: $cards)
                    .padding(.top, 24)
                HeuteVitalsGridView(readings: vitalReadings, workout: dayWorkout)
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
            .padding(.bottom, NoopMetrics.tabBarClearance)
        }
        .background(HeuteRedesignPalette.bg.ignoresSafeArea())
        .simultaneousGesture(daySwipeGesture)
        .task(id: selectedDayOffset) { await load() }
    }

    /// Whole days from today's logical day back to the earliest banked day — the lower bound the day-swipe
    /// and the header chevrons clamp to (0 when there's no history, so today is the only reachable day).
    /// Reuses the classic Today's pure helper so the bound can't drift between the two screens.
    private var earliestDayOffset: Int {
        TodayView.maxDayOffset(earliestDayKey: repo.freshness.earliestDay,
                               todayKey: Repository.logicalDayKey(Date()))
    }

    /// The day-nav swipe: a clearly-horizontal drag flips the day (left → older, right → newer), clamped
    /// to `0 ... earliestDayOffset`. Same thresholds and pure clamp as `TodayView.daySwipeGesture`; Heute
    /// has no HR-chart pan to mask against, so the gesture is unconditional over the scroll view.
    private var daySwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.5, abs(dx) > 50 else { return }
                let delta = dx < 0 ? 1 : -1
                let next = TodayView.clampedDayOffset(current: selectedDayOffset, delta: delta,
                                                      maxOffset: earliestDayOffset)
                guard next != selectedDayOffset else { return }
                withAnimation(StrandMotion.interactive) { selectedDayOffset = next }
            }
    }

    /// Placeholder content so the drag-to-dismiss gesture has something to test on-device — real
    /// sourcing (propose_plan / vitals-anomaly detection) is out of scope here (feature-spec §3's
    /// generic-mechanic requirement is satisfied by `NotificationCardItem`; only the SOURCE is stubbed).
    private static let sampleCards: [NotificationCardItem] = [
        NotificationCardItem(category: String(localized: "Suggestion"),
                              text: String(localized: "Placeholder card — real training suggestions land here once propose_plan is wired in.")),
    ]

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
        vitalReadings = buildReadings(day: day, tkey: tkey, isToday: isToday, fitnessAge: fitnessAge)

        // Logical-day window, not a raw midnight-to-midnight one: a 01:00 workout belongs to the logical
        // day that is still running, exactly as `CoupledView` buckets workouts.
        let workoutDayKey = selectedLogicalDayKey
        let workouts = await repo.workoutRows(days: 400)
        let dayWorkouts = workouts.filter { w in
            Repository.logicalDayKey(Date(timeIntervalSince1970: TimeInterval(w.startTs))) == workoutDayKey
        }
        dayWorkout = dayWorkouts.max(by: { $0.startTs < $1.startTs })
    }

    /// Builds the vitals grid using the SAME recovery-independent carry the other two Today screens read:
    /// each vital is resolved today-first (`day?.field`), falling back PER FIELD to the freshest strictly-
    /// prior night that recorded it (`Repository.lastVitalsDay` for HRV/RHR/respiratory; `lastSpo2Day` for
    /// SpO₂, whose predicate the whole-row carry does not check). The carry is bounded by today's own key
    /// and applies only to today — a navigated past day shows its own row verbatim, or nothing.
    private func buildReadings(day: DailyMetric?, tkey: String, isToday: Bool,
                               fitnessAge: Double?) -> [String: HeuteVitalReading] {
        var out: [String: HeuteVitalReading] = [:]
        let vitalsDay = isToday ? Repository.lastVitalsDay(days: repo.days, todayKey: tkey) : nil
        let spo2Day = isToday ? Repository.lastSpo2Day(days: repo.days, todayKey: tkey) : nil

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
            out["my-whoop:fitness_age"] = HeuteVitalReading(value: fitnessAge, asOf: String(localized: "Weekly"))
        }
        // Steps are a daily accumulator like strain, not an overnight vital — yesterday's total is not a
        // stand-in for today, so this reads the selected day's OWN value and never carries.
        if let steps = day?.steps.map(Double.init) {
            out["apple-health:steps"] = HeuteVitalReading(value: steps, asOf: asOfLabel(tkey),
                                                            sparkline: sparkline({ $0.steps.map(Double.init) }))
        }
        return out
    }

    private func sparkline(_ extract: (DailyMetric) -> Double?) -> [Double] {
        let key = selectedDayKey
        return Array(repo.days.filter { $0.day <= key }.compactMap(extract).suffix(8))
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
