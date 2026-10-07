#if os(iOS)
import Foundation
import WidgetKit
import StrandDesign
import WhoopStore

/// Publishes the fitness widgets' payload from what the app already holds: the daily metrics, the
/// scale's weigh-ins, the workout log and the step goal. Called with the main glance publish (app
/// active, after a sync); writes and reloads only when something a widget draws changed.
@MainActor
enum FitnessWidgetPublisher {

    static func publish(from model: AppModel, now: Date = Date()) async {
        let calendar = Calendar.current
        let repo = model.repo
        let byDay = Dictionary(repo.days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        let keys = FitnessWidgetMath.dayKeys(endingAt: now, count: 14, calendar: calendar)
        let rows = keys.map { byDay[$0] }
        let letters = keys.map { key -> String in
            guard let date = dayDate(key, calendar: calendar) else { return "" }
            let symbols = calendar.veryShortStandaloneWeekdaySymbols
            return symbols[calendar.component(.weekday, from: date) - 1]
        }

        // Effort in the wearer's scale (0…21 or 0…100), as the main widget writes it (#313).
        let effortScale = UnitPrefs.resolveEffortScale(
            UserDefaults.standard.string(forKey: UnitPrefs.effortScaleKey) ?? "")
        let effortTexts: [String?] = rows.map { row in
            row?.strain.map { stored in
                effortScale == .whoop ? String(format: "%.1f", UnitFormatter.effortValue(stored, scale: .whoop))
                                      : "\(Int(stored.rounded()))"
            }
        }

        // The usual range is read from the last 30 days, not only the 14 the charts draw.
        let month = FitnessWidgetMath.dayKeys(endingAt: now, count: 30, calendar: calendar).map { byDay[$0] }
        let hrvUsual = FitnessWidgetMath.usual(month.map { $0?.avgHrv })
        let rhrUsual = FitnessWidgetMath.usual(month.map { $0?.restingHr.map(Double.init) })

        // Steps the way the goals read them: the strap's count, else Apple Health's for that day.
        let stepsByDay = GoalMotivationBuilder.stepsByDay(days: repo.days, apple: await repo.appleDailyRows(days: 20))
        let sleep = await lastNight(rows: rows, keys: keys, repo: repo)
        let weight = await weightReadings(repo: repo, now: now, calendar: calendar)
        let workoutRows = await repo.workoutRows(days: 90)
        let workouts = workoutWeek(workoutRows, now: now, calendar: calendar)

        // Active days: a workout logged that day, from any source. Strap-detected movement alone does not
        // count, or nearly every day would (a walk to the shop is a bout). A day before the wearer had any
        // data at all has no record, which is not a rest day.
        let trainedDays = Set(workoutRows.map { FitnessWidgetMath.key(Date(timeIntervalSince1970: TimeInterval($0.startTs)),
                                                                        calendar: calendar) })
        let firstRecord = min(repo.days.first?.day ?? "9999", trainedDays.min() ?? "9999")
        let activeKeys = FitnessWidgetMath.dayKeys(endingAt: now, count: 84, calendar: calendar)
        let activeDays: [Bool?] = activeKeys.map { key in
            if trainedDays.contains(key) { return true }
            return key < firstRecord ? nil : false
        }

        let snapshot = FitnessWidgetSnapshot(
            days: keys, dayLetters: letters,
            charge: rows.map { $0?.recovery },
            effort: rows.map { $0?.strain },
            effortTexts: effortTexts,
            hrv: rows.map { $0?.avgHrv },
            rhr: rows.map { $0?.restingHr.map(Double.init) },
            sleepHours: rows.map { $0?.totalSleepMin.map { $0 / 60 } },
            steps: keys.map { stepsByDay[$0] },
            hrvUsual: hrvUsual, rhrUsual: rhrUsual,
            sleep: sleep,
            stepsGoal: stepsGoal(today: keys.last ?? ""),
            weight: weight,
            workouts: workouts,
            activeDays: activeDays,
            vitals: vitals(rows: rows, month: month),
            updated: now)
        if snapshot.save() {
            for kind in FitnessWidgetSnapshot.widgetKinds {
                WidgetCenter.shared.reloadTimelines(ofKind: kind)
            }
        }
    }

    // MARK: - Pieces

    private static func dayDate(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// The most recent night of the last two days, with the need the Sleep screen uses.
    private static func lastNight(rows: [DailyMetric?], keys: [String], repo: Repository) async
        -> FitnessWidgetSnapshot.Sleep? {
        guard let index = rows.indices.suffix(2).last(where: { (rows[$0]?.totalSleepMin ?? 0) > 0 }),
              let row = rows[index], let total = row.totalSleepMin else { return nil }
        let needSeries = await repo.exploreSeries(key: "sleep_need_min", source: "my-whoop")
        let need = needSeries.last(where: { $0.day <= keys[index] })?.value
        return .init(day: keys[index], totalMin: total, needMin: need, deepMin: row.deepMin, remMin: row.remMin,
                     lightMin: row.lightMin, efficiency: row.efficiency)
    }

    /// The last 30 days' weigh-ins in the wearer's unit; nil without any.
    private static func weightReadings(repo: Repository, now: Date, calendar: Calendar) async
        -> FitnessWidgetSnapshot.Weight? {
        let system = UnitSystem(rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        let since = FitnessWidgetMath.dayKeys(endingAt: now, count: 30, calendar: calendar).first ?? ""
        let readings = await repo.weightDailyValues(days: 31)
            .filter { $0.day >= since && $0.value > 10 }
            .map { FitnessWidgetSnapshot.Weight.Reading(
                day: $0.day, value: system == .imperial ? UnitFormatter.kgToPounds($0.value) : $0.value) }
        guard !readings.isEmpty else { return nil }
        return .init(unit: UnitFormatter.massUnit(system), readings: readings,
                     change: FitnessWidgetMath.change(readings.map(\.value)))
    }

    /// The running training week and the last workout.
    private static func workoutWeek(_ rows: [WorkoutRow], now: Date, calendar: Calendar)
        -> FitnessWidgetSnapshot.Workouts {
        let weekCalendar = TrainingPreferences.weekCalendar
        let week = FitnessWidgetMath.week(containing: now, calendar: weekCalendar)
        let keyOf = { (row: WorkoutRow) in
            FitnessWidgetMath.key(Date(timeIntervalSince1970: TimeInterval(row.startTs)), calendar: weekCalendar)
        }
        let inWeek = rows.filter { week.keys.contains(keyOf($0)) }
        let trained = Set(inWeek.map(keyOf))
        let minutes = inWeek.reduce(0.0) { $0 + ($1.durationS ?? Double($1.endTs - $1.startTs)) } / 60
        let letters = week.keys.map { key -> String in
            guard let date = dayDate(key, calendar: weekCalendar) else { return "" }
            return weekCalendar.veryShortStandaloneWeekdaySymbols[weekCalendar.component(.weekday, from: date) - 1]
        }
        let last = rows.max { $0.startTs < $1.startTs }
        return .init(count: inWeek.count, minutes: Int(minutes.rounded()),
                     trainedDays: week.keys.map { trained.contains($0) }, weekLetters: letters,
                     todayIndex: week.todayIndex,
                     lastName: last.map { WorkoutSource.displaySport($0.sport) },
                     lastSymbol: last.map { sportSymbol($0.sport) },
                     lastDay: last.map(keyOf),
                     lastMinutes: last.map { Int((($0.durationS ?? Double($0.endTs - $0.startTs)) / 60).rounded()) })
    }

    /// The step target of an active daily step goal, if the wearer set one.
    private static func stepsGoal(today: String) -> Int? {
        GoalActionStore.shared.actions
            .filter { $0.isActive && !$0.hasEnded(today: today) }
            .compactMap { action -> Int? in
                if case .steps(let minimum) = action.requirement { return minimum }
                return nil
            }
            .max()
    }

    /// Last night's SpO₂, respiratory rate and skin temperature against the last 30 nights.
    private static func vitals(rows: [DailyMetric?], month: [DailyMetric?]) -> [FitnessWidgetSnapshot.Vital] {
        guard let night = rows.last(where: { $0?.spo2Pct != nil || $0?.respRateBpm != nil || $0?.skinTempDevC != nil })
            ?? nil else { return [] }
        let system = UnitSystem(rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        var out: [FitnessWidgetSnapshot.Vital] = []
        if let spo2 = night.spo2Pct {
            out.append(.init(id: "spo2", name: String(localized: "Blood Oxygen"), symbol: "drop",
                             value: spo2, text: "\(Int(spo2.rounded())) %",
                             usual: FitnessWidgetMath.usual(month.map { $0?.spo2Pct })))
        }
        if let resp = night.respRateBpm {
            out.append(.init(id: "resp", name: String(localized: "Respiratory Rate"), symbol: "lungs",
                             value: resp, text: String(localized: "\(resp.formatted(.number.precision(.fractionLength(1)))) rpm"),
                             usual: FitnessWidgetMath.usual(month.map { $0?.respRateBpm })))
        }
        if let skin = night.skinTempDevC {
            // A deviation, so Fahrenheit is the difference scaled, without the 32 offset.
            let shown = system == .imperial ? skin * 1.8 : skin
            let unit = system == .imperial ? "°F" : "°C"
            let sign = shown > 0.05 ? "+" : (shown < -0.05 ? "−" : "±")
            out.append(.init(id: "skinTemp", name: String(localized: "Skin Temperature"), symbol: "thermometer",
                             value: skin,
                             text: "\(sign)\(abs(shown).formatted(.number.precision(.fractionLength(1)))) \(unit)",
                             usual: FitnessWidgetMath.usual(month.map { $0?.skinTempDevC })))
        }
        return out
    }
}
#endif
