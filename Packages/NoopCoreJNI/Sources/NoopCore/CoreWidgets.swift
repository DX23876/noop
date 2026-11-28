import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// `widgets.fitness`: what Android's fitness widgets draw, read as the iPhone's `FitnessWidgetPublisher` reads it
/// (`StrandiOS/Widgets/FitnessWidgetPublish.swift`), from the same daily rows, workouts, weigh-ins, sleep need and
/// step goal. Numbers only: the phone words them, in its own language and units. Android had none of the iPhone's
/// ten fitness widgets (found 2026-11-28).
enum CoreWidgets {
    struct Usual: Encodable, Equatable { var low: Double; var high: Double }
    struct Sleep: Encodable {
        var day: String; var totalMin: Double; var needMin: Double?
        var deepMin: Double?; var remMin: Double?; var lightMin: Double?; var efficiency: Double?
    }
    struct Reading: Encodable { var day: String; var kg: Double }
    struct Workouts: Encodable {
        var count: Int; var minutes: Int; var weekDays: [String]; var trainedDays: [Bool]; var todayIndex: Int
        var lastSport: String?; var lastDay: String?; var lastMinutes: Int?
    }
    struct Vital: Encodable { var id: String; var value: Double; var usual: Usual? }
    struct Fitness: Encodable {
        var days: [String]
        var charge: [Double?]; var effort: [Double?]; var hrv: [Double?]; var rhr: [Double?]
        var sleepHours: [Double?]; var steps: [Int?]
        var hrvUsual: Usual?; var rhrUsual: Usual?
        var sleep: Sleep?; var stepsGoal: Int?
        var weight: [Reading]; var workouts: Workouts
        var activeDays: [Bool?]; var activeFirstDay: String
        var vitals: [Vital]
    }

    @MainActor
    static func fitness(_ args: [String: Any], reader: StoreReader, now: Date = Date()) async -> String {
        let calendar = Calendar.current
        let dismissed = args["dismissedWorkouts"] as? [String] ?? []
        let keys = dayKeys(endingAt: now, count: 14, calendar: calendar)
        let month = dayKeys(endingAt: now, count: 30, calendar: calendar)
        let longest = dayKeys(endingAt: now, count: 84, calendar: calendar)
        let rowsAll = await CoreRead.dailyRows(from: longest.first ?? "", to: keys.last ?? "", reader: reader)
        let byDay = Dictionary(rowsAll.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        let rows = keys.map { byDay[$0] }
        let monthRows = month.map { byDay[$0] }

        let apple = (try? await reader.store.appleDaily(deviceId: MetricResolver.appleHealthSource,
                                                        from: keys.first ?? "", to: keys.last ?? "")) ?? []
        let stepsByDay = GoalMotivationBuilder.stepsByDay(days: rowsAll, apple: apple)

        // The most recent night of the last two days, with the need the Sleep screen uses.
        var sleep: Sleep?
        if let index = rows.indices.suffix(2).last(where: { (rows[$0]?.totalSleepMin ?? 0) > 0 }),
           let row = rows[index], let total = row.totalSleepMin {
            let need = await reader.exploreSeries(key: "sleep_need_min", source: MetricResolver.whoopSource,
                                                  from: month.first ?? "", to: keys.last ?? "", dailyRows: rowsAll,
                                                  suppressedSleepWakeDays: [])
            sleep = Sleep(day: keys[index], totalMin: total, needMin: need.last(where: { $0.day <= keys[index] })?.value,
                          deepMin: row.deepMin, remMin: row.remMin, lightMin: row.lightMin, efficiency: row.efficiency)
        }

        let weight = await WeightSeries.series(reader: reader, from: month.first ?? "", to: keys.last ?? "")
            .filter { $0.value > 10 }.map { Reading(day: $0.day, kg: $0.value) }

        // The list without its heart-rate overlay: the widgets need starts, lengths and sports, and the overlay
        // reads every session's samples, which held the core for seconds while the app waited behind it.
        let nowTs = Int(now.timeIntervalSince1970)
        let workoutRows = WorkoutSource.dedupCrossSource(
            await reader.rawWorkoutRows(from: nowTs - 90 * 86_400, to: nowTs + 86_400, dismissedDetectedSpans: dismissed))
        let weekCalendar = TrainingPreferences.weekCalendar
        let week = trainingWeek(containing: now, calendar: weekCalendar)
        let keyOf = { (row: WorkoutRow) in key(Date(timeIntervalSince1970: TimeInterval(row.startTs)), calendar: weekCalendar) }
        let inWeek = workoutRows.filter { week.keys.contains(keyOf($0)) }
        let trained = Set(inWeek.map(keyOf))
        let minutes = inWeek.reduce(0.0) { $0 + ($1.durationS ?? Double($1.endTs - $1.startTs)) } / 60
        let last = workoutRows.max { $0.startTs < $1.startTs }
        let workouts = Workouts(count: inWeek.count, minutes: Int(minutes.rounded()), weekDays: week.keys,
                                trainedDays: week.keys.map { trained.contains($0) }, todayIndex: week.todayIndex,
                                lastSport: last.map { CoreSportName.name($0.sport) }, lastDay: last.map(keyOf),
                                lastMinutes: last.map { Int((($0.durationS ?? Double($0.endTs - $0.startTs)) / 60).rounded()) })

        // Active days: a workout logged that day, from any source; a day before any record is not a rest day.
        let trainedDays = Set(workoutRows.map { key(Date(timeIntervalSince1970: TimeInterval($0.startTs)), calendar: calendar) })
        let firstRecord = min(rowsAll.first?.day ?? "9999", trainedDays.min() ?? "9999")
        let activeDays: [Bool?] = longest.map { day in
            if trainedDays.contains(day) { return true }
            return day < firstRecord ? nil : false
        }

        let today = keys.last ?? ""
        let actions = (try? await CoreGoalState.read(store: reader.store) { $0.actions.actions }) ?? []
        let stepsGoal = actions.filter { $0.isActive && !$0.hasEnded(today: today) }
            .compactMap { action -> Int? in
                if case .steps(let minimum) = action.requirement { return minimum }
                return nil
            }.max()

        var vitals: [Vital] = []
        if let night = rows.last(where: { $0?.spo2Pct != nil || $0?.respRateBpm != nil || $0?.skinTempDevC != nil }) ?? nil {
            if let v = night.spo2Pct { vitals.append(Vital(id: "spo2", value: v, usual: usual(monthRows.map { $0?.spo2Pct }))) }
            if let v = night.respRateBpm { vitals.append(Vital(id: "resp", value: v, usual: usual(monthRows.map { $0?.respRateBpm }))) }
            if let v = night.skinTempDevC { vitals.append(Vital(id: "skinTemp", value: v, usual: usual(monthRows.map { $0?.skinTempDevC }))) }
        }

        return CoreRead.json(Fitness(
            days: keys, charge: rows.map { $0?.recovery }, effort: rows.map { $0?.strain },
            hrv: rows.map { $0?.avgHrv }, rhr: rows.map { $0?.restingHr.map(Double.init) },
            sleepHours: rows.map { $0?.totalSleepMin.map { $0 / 60 } }, steps: keys.map { stepsByDay[$0] },
            hrvUsual: usual(monthRows.map { $0?.avgHrv }), rhrUsual: usual(monthRows.map { $0?.restingHr.map(Double.init) }),
            sleep: sleep, stepsGoal: stepsGoal, weight: weight, workouts: workouts,
            activeDays: activeDays, activeFirstDay: longest.first ?? "", vitals: vitals))
    }

    // MARK: - The iPhone's `FitnessWidgetMath`, the same arithmetic

    /// Mean ± one standard deviation of the non-nil values; nil below `minimum` values.
    static func usual(_ values: [Double?], minimum: Int = 7) -> Usual? {
        let xs = values.compactMap { $0 }
        guard xs.count >= minimum else { return nil }
        let mean = xs.reduce(0, +) / Double(xs.count)
        let sd = (xs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(xs.count)).squareRoot()
        return Usual(low: mean - sd, high: mean + sd)
    }

    /// The day keys of the `count` days ending at `today`, oldest first.
    static func dayKeys(endingAt today: Date, count: Int, calendar: Calendar) -> [String] {
        let start = calendar.startOfDay(for: today)
        return (0..<count).reversed().compactMap { back in
            calendar.date(byAdding: .day, value: -back, to: start).map { key($0, calendar: calendar) }
        }
    }

    static func key(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.gregorianForDayKeys.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The training week containing `today` (first weekday first) as day keys, and today's index in it.
    static func trainingWeek(containing today: Date, calendar: Calendar) -> (keys: [String], todayIndex: Int) {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: today) else { return ([], 0) }
        let keys = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
            .map { key($0, calendar: calendar) }
        return (keys, keys.firstIndex(of: key(today, calendar: calendar)) ?? 0)
    }
}
