#if os(iOS)
import Foundation
import WidgetKit
// For `AppleInspiredColorsPrefs`, whose key resolves the goal tint at publish time (the extension
// cannot read the app's plain UserDefaults).
import StrandDesign

extension WidgetSnapshot {
    /// Build a glance snapshot from the live app state and publish it to the shared App Group, then
    /// ask WidgetKit to refresh. Called when the app becomes active and after a Health sync.
    ///
    /// `async` because the Rest score (#446) lives in a computed metric series, not a `DailyMetric`
    /// column, so it needs an `exploreSeries` read. The sole caller already runs inside a `Task`, so it
    /// just gains an `await`. Charge / Effort / HRV / Resting HR all read synchronously off the SAME
    /// anchor day, so the richer fields and the headline never disagree about which day they describe.
    ///
    /// #911: the anchor is resolved the way Today resolves it (the current LOGICAL local day, `Date()`
    /// read here so the day rolls live as the extension republishes), NOT "the most recent day with any
    /// recovery score". The old anchor drifted around the day rollover: the new logical day exists but
    /// isn't scored yet, so `days.last(where: recovery != nil)` still pointed at yesterday's scored row
    /// and the widget showed the older day while Today had already moved on. We now anchor on today's
    /// row and, only when today isn't scored yet, carry over the last STRICTLY-PRIOR scored day for the
    /// recovery-derived fields (the same carry-over Today does), so the widget never blanks right after
    /// the rollover yet always describes today.
    @MainActor
    static func publish(from model: AppModel) async {
        let days = model.repo.days
        let now = Date()
        // The recovery-derived anchor: today's row when it's scored, else the freshest STRICTLY-PRIOR
        // scored day carried over. Resolved through the SHARED `Repository.widgetAnchor`, the ONE selector
        // the watch snapshot and the iOS Live Activity now also use, so all four surfaces describe the same
        // day (the #911 fix; see `Repository.widgetAnchor` for the rollover-drift rationale, the #304
        // pre-04:00 carve-out and the #547 future-day guard it folds in). The `$0.day < carriedKey` bound
        // inside the helper (matching `TodayView.selectedDayKey`) means a stale scored row can never
        // re-surface AS today.
        let day = Repository.widgetAnchor(days: days, now: now)
        // Rest (sleep_performance) for that same anchor day. exploreSeries merges imported + on-device,
        // exactly like the Today Rest tile. The tail fallback (restSeries.last) is ONLY valid when the
        // anchor day IS the local today: early in a fresh day today's Rest row may not exist yet, so we
        // borrow the latest value. For an anchor that is NOT today, borrowing the tail would surface a
        // DIFFERENT day's Rest as this day's (the cross-day bug), so we leave it nil. Mirrors TodayView's
        // `restByDay[selectedDayKey] ?? (selectedDayOffset == 0 ? restSeries.last?.value : nil)` and the
        // matching guard in WatchSessionBridge.
        var restScore: Double?
        if let day {
            let restSeries = await model.repo.exploreSeries(key: "sleep_performance", source: "my-whoop")
            let restByDay = Dictionary(restSeries.map { ($0.day, $0.value) }, uniquingKeysWith: { _, last in last })
            let anchorIsToday = day.day == Repository.localDayKey(now)
            restScore = restByDay[day.day] ?? (anchorIsToday ? restSeries.last?.value : nil)
        }
        // #313: honour the user's Effort scale at publish time. The widget extension cannot read the
        // app's plain `@AppStorage(UnitPrefs.effortScaleKey)` (it is not in the App Group), so we
        // pre-format the display string here and keep the 0–100 int for the ring fill (the fill
        // fraction is scale-independent: 38/100 == 8.0/21).
        let effortScale = UnitPrefs.resolveEffortScale(
            UserDefaults.standard.string(forKey: UnitPrefs.effortScaleKey) ?? ""
        )
        let strain = day?.strain
        let effortDisplay: String? = strain.map { stored in
            if effortScale == .whoop {
                return String(format: "%.1f", UnitFormatter.effortValue(stored, scale: .whoop))
            }
            return "\(Int(stored.rounded()))"
        }
        let goal = await goalFields(from: model)
        let snap = WidgetSnapshot(
            recovery: day?.recovery.map { Int($0.rounded()) },
            bpm: model.bpm ?? model.live.heartRate,
            batteryPct: model.live.batteryPct.map { Int($0.rounded()) },
            bonded: model.live.bonded,
            updated: Date(),
            // Stored 0–100 axis for ring fill; display string carries the #313 scale.
            effort: strain.map { Int($0.rounded()) },
            rest: restScore.map { Int($0.rounded()) },
            hrv: day?.avgHrv.map { Int($0.rounded()) },
            restingHr: day?.restingHr,
            effortDisplay: effortDisplay,
            effortWhoop: effortScale == .whoop,
            goalTitle: goal.title,
            goalSymbol: goal.symbol,
            goalTintId: goal.tintId,
            goalFraction: goal.fraction,
            goalRunwayWeeks: goal.runwayWeeks,
            goalLine: goal.line
        )
        snap.save()
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// The active goal's fields for the goal widget, or all-nil when there is no goal.
    ///
    /// Deliberately NOT recomputed on every publish. A goal's progress reads the coach's evidence, which
    /// costs real repository work, and `publish` also runs off the HR hook — recomputing there would put
    /// a history query behind a value that moves every few seconds. So the reading is refreshed at most
    /// once per `GoalPublishThrottle.interval` and otherwise CARRIED FORWARD from the last published
    /// snapshot: an hour-old runway is fine, a stalled app is not, and either beats a query per heartbeat.
    ///
    /// The "which goal" rule matches `GoalTodayCard`: the nearest target date, since that's the one with
    /// a clock on it.
    @MainActor
    private static func goalFields(from model: AppModel)
        async -> (title: String?, symbol: String?, tintId: String?, fraction: Double?,
                  runwayWeeks: Double?, line: String?) {
        // No goal is a real answer, and it must clear the carried-forward fields — a deleted goal that
        // lingered in the widget would be the one lie this whole path is written to avoid.
        guard let goal = CoachGoalStore.shared.primaryActiveGoal else {
            return (nil, nil, nil, nil, nil, nil)
        }

        let title = goal.title.isEmpty ? goal.kind.label.localizedCatalogValue : goal.title
        // The colour preference lives in the app's plain UserDefaults, out of the extension's reach —
        // resolved to an id here, exactly as `effortDisplay` resolves the Effort scale above.
        let appleColors = UserDefaults.standard.object(forKey: AppleInspiredColorsPrefs.enabledKey) as? Bool
            ?? AppleInspiredColorsPrefs.defaultEnabled
        let tintId: String? = appleColors ? "coach.goal.\(goal.kind.rawValue)" : nil

        guard GoalPublishThrottle.admit() else {
            // Between refreshes: keep the previous reading, but re-derive the cheap parts (name, mark,
            // runway) so an edited title or date shows up immediately rather than waiting out the window.
            let previous = WidgetSnapshot.load()
            return (title, goal.kind.icon, tintId, previous?.goalFraction,
                    goal.weeksRemaining(), previous?.goalLine)
        }
        let evidence = await model.coach.goalEvidence()
        let weight = await model.coach.latestLoggedWeightKg()
        let reading = GoalProgress.reading(goal: goal, evidence: evidence, latestWeightKg: weight)
        return (title, goal.kind.icon, tintId, reading.fraction, reading.runwayWeeks, reading.line)
    }

    /// Caps how often the goal reading behind the widget is recomputed — see `goalFields`. A goal moves
    /// over weeks, so half an hour is generous; the point is only that a per-heartbeat publish can't drag
    /// a repository query along with it. `@MainActor` (publish already runs there), so no locking.
    @MainActor
    enum GoalPublishThrottle {
        static let interval: TimeInterval = 30 * 60
        private static var lastComputedAt: Date = .distantPast
        /// True (and stamps `now`) when at least `interval` has elapsed. The first call always admits.
        static func admit(now: Date = Date()) -> Bool {
            guard now.timeIntervalSince(lastComputedAt) >= interval else { return false }
            lastComputedAt = now
            return true
        }
    }

    /// #114/#169: HR is the ONE high-frequency widget-publish trigger — `model.bpm` moves every few
    /// seconds during activity, unlike battery (~8 min) or connection flips (rare). Left ungated, the
    /// `model.$bpm` hook re-ran `publish`'s `exploreSeries` read + `reloadAllTimelines()` on every tick.
    /// This caps HR-DRIVEN publishes to one per `interval`, mirroring Android's `PushGate` 60 s
    /// `HR_REFRESH_MS` cadence. Only the bpm hook consults it; the low-frequency score/battery/connection/
    /// scenePhase publish sites stay ungated, exactly as before. `@MainActor` (the hook already runs there),
    /// so the shared timestamp needs no locking.
    @MainActor
    enum HRPublishThrottle {
        static let interval: TimeInterval = 60
        private static var lastPublishedAt: Date = .distantPast
        /// True (and stamps `now`) when at least `interval` has elapsed since the last HR-driven publish;
        /// false to skip this HR change. The first call always admits (`.distantPast`).
        static func admit(now: Date = Date()) -> Bool {
            guard now.timeIntervalSince(lastPublishedAt) >= interval else { return false }
            lastPublishedAt = now
            return true
        }
    }
}
#endif
