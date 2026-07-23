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
// Data-loading here is a REASONABLE simplification of what `TodayView.swift`/`LiquidTodayView.swift`
// do, not a byte-identical replica of their carry-over selectors (`carriedVital`, `lastScoredRecoveryDay`
// etc., see docs/decisions.md-worthy note below) — this screen carries forward the single most-recent
// non-nil value per field and labels it Today/Yesterday/weekday, which is honest (never invents data)
// but simpler than the full #543 fallback chain. Close enough for this screen to show real numbers and
// be tested on-device; worth reconciling with the exact TodayView selectors later if this screen is
// promoted past "Experimental".
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
    @State private var charge: Double = 0
    @State private var effort: Double = 0
    @State private var rest: Double = 0
    @State private var vitalReadings: [String: HeuteVitalReading] = [:]
    @State private var activitySummary: String?
    @State private var cards: [NotificationCardItem] = HeuteRedesignView.sampleCards

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HeuteHeaderView(status: $status, selectedDayOffset: $selectedDayOffset)
                HeuteRingsView(charge: charge, effort: effort, rest: rest, effortScale: effortScale)
                    .padding(.top, 2)
                HeuteCardZoneView(status: dayStatus, readiness: readiness, cards: $cards)
                    .padding(.top, 24)
                HeuteVitalsGridView(readings: vitalReadings, activitySummary: activitySummary)
                    .padding(.top, 26)
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
        .task(id: selectedDayOffset) { await load() }
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
        let anchor = repo.days.last(where: { $0.day <= key && $0.recovery != nil })?.day ?? key
        readiness = ReadinessEngine.evaluate(days: repo.days, today: anchor)

        charge = latestValue({ $0.recovery })?.value ?? 0
        effort = latestValue({ $0.strain })?.value ?? 0
        let sleepSeries = await repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
        rest = sleepSeries.last(where: { $0.day <= key })?.value ?? 0

        let fitnessSeries = await repo.exploreSeries(key: "fitness_age", source: "my-whoop")
        let fitnessAge = fitnessSeries.last(where: { $0.day <= key })?.value
        vitalReadings = buildReadings(fitnessAge: fitnessAge)

        activitySummary = nil
        // Logical-day window, not a raw midnight-to-midnight one: a 01:00 workout belongs to the logical
        // day that is still running, exactly as `CoupledView` buckets workouts.
        let workoutDayKey = selectedLogicalDayKey
        let workouts = await repo.workoutRows(days: 400)
        let dayWorkouts = workouts.filter { w in
            Repository.logicalDayKey(Date(timeIntervalSince1970: TimeInterval(w.startTs))) == workoutDayKey
        }
        if let latest = dayWorkouts.max(by: { $0.startTs < $1.startTs }) {
            activitySummary = activitySummaryText(latest)
        }
    }

    private func buildReadings(fitnessAge: Double?) -> [String: HeuteVitalReading] {
        var out: [String: HeuteVitalReading] = [:]
        if let hrv = latestValue({ $0.avgHrv }) {
            out["my-whoop:hrv"] = HeuteVitalReading(value: hrv.value, asOf: asOfLabel(hrv.day),
                                                      sparkline: sparkline({ $0.avgHrv }))
        }
        if let rhr = latestValue({ $0.restingHr.map(Double.init) }) {
            out["my-whoop:rhr"] = HeuteVitalReading(value: rhr.value, asOf: asOfLabel(rhr.day),
                                                      sparkline: sparkline({ $0.restingHr.map(Double.init) }))
        }
        if let resp = latestValue({ $0.respRateBpm }) {
            out["my-whoop:resp_rate"] = HeuteVitalReading(value: resp.value, asOf: asOfLabel(resp.day),
                                                            sparkline: sparkline({ $0.respRateBpm }))
        }
        if let spo2 = latestValue({ $0.spo2Pct }) {
            out["my-whoop:spo2"] = HeuteVitalReading(value: spo2.value, asOf: asOfLabel(spo2.day),
                                                       sparkline: sparkline({ $0.spo2Pct }))
        }
        if let fitnessAge {
            out["my-whoop:fitness_age"] = HeuteVitalReading(value: fitnessAge, asOf: String(localized: "Weekly"))
        }
        if let steps = latestValue({ $0.steps.map(Double.init) }) {
            out["apple-health:steps"] = HeuteVitalReading(value: steps.value, asOf: asOfLabel(steps.day),
                                                            sparkline: sparkline({ $0.steps.map(Double.init) }))
        }
        return out
    }

    /// The selected day's own value if present, else the most recent non-nil value at or before it — a
    /// simple carry, never invents a number. Returns the day it actually came from so the caption can
    /// say so.
    private func latestValue(_ extract: (DailyMetric) -> Double?) -> (value: Double, day: String)? {
        let key = selectedDayKey
        if let day = repo.days.first(where: { $0.day == key }), let v = extract(day) { return (v, day.day) }
        guard let day = repo.days.last(where: { $0.day <= key && extract($0) != nil }) else { return nil }
        return (extract(day)!, day.day)
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

    private func activitySummaryText(_ workout: WorkoutRow) -> String {
        let secs = workout.durationS ?? Double(max(workout.endTs - workout.startTs, 0))
        var parts = [String(localized: "\(Int(secs / 60)) min")]
        if let kcal = workout.energyKcal { parts.append(String(localized: "\(Int(kcal.rounded())) kcal")) }
        return parts.joined(separator: " · ")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        return f
    }()
}
