import Foundation

/// The weight page, its widgets, the Today tile and the coach read ONE derivation of the scale history: this one.
/// Pure (no store, no clock, no formatting): callers pass the weigh-ins, the goal, the diet plan's pace, the
/// wearer's settings and events, and the instant. Each platform words the result; none computes a figure itself,
/// so the page and a widget can never disagree about the same morning (owner decisions, 2026-11-26).
///
/// What is measured and what is derived stay apart: the latest reading is the scale, the trend is the smoothed
/// centre (`WeightTrendSummary.smoothedSeries`, the same fold the goals judge on), and a forecast is arithmetic on
/// a chosen rate, never more. A forecast whose rate points away from the goal, or would need years, says so
/// instead of printing a date.
public enum WeightTracker {

    // MARK: - Settings and events (stored by the host under `storageKey`, backed up with the goals)

    /// What a forecast starts from. The trend is the default; the ten-day low filters water swings and is offered
    /// as a start point only, never as the number goals or changes are judged on.
    public enum TrendBasis: String, Codable, CaseIterable, Sendable { case trend, tenDayLow }

    /// Which rate a forecast runs at.
    public enum RateMode: String, Codable, CaseIterable, Sendable {
        /// The measured trend over the chosen window.
        case current
        /// The average since the goal began, or since the first weigh-in without a goal.
        case overall
        /// The planned rate: the diet plan's pace, else the goal's own plan, else the wearer's figure. A plan,
        /// not a prediction, and the screens say so.
        case wish
    }

    /// Where the planned rate came from.
    public enum WishSource: String, Codable, Sendable { case dietPlan, goal, manual }

    public struct Settings: Codable, Equatable, Sendable {
        public var basis: TrendBasis
        public var rateMode: RateMode
        /// Days the current rate is fitted over: 14, 28 or 56.
        public var rateWindowDays: Int
        /// Fixed milestone spacing in kilograms; nil leaves the round-number route of the goal.
        public var milestoneStepKg: Double?
        /// The wearer's own planned rate in kg a week, negative for losing; used when neither a diet plan nor a
        /// dated goal gives one.
        public var manualWishKgPerWeek: Double?
        /// Card keys the wearer switched off on the page (`Card`).
        public var hiddenCards: [String]

        public static let rateWindows = [14, 28, 56]
        public static let milestoneSteps: [Double] = [2, 5, 10]
        public static let standard = Settings()

        public init(basis: TrendBasis = .trend, rateMode: RateMode = .current, rateWindowDays: Int = 28,
                    milestoneStepKg: Double? = nil, manualWishKgPerWeek: Double? = nil, hiddenCards: [String] = []) {
            self.basis = basis; self.rateMode = rateMode
            self.rateWindowDays = Settings.rateWindows.contains(rateWindowDays) ? rateWindowDays : 28
            self.milestoneStepKg = milestoneStepKg.flatMap { Settings.milestoneSteps.contains($0) ? $0 : nil }
            self.manualWishKgPerWeek = manualWishKgPerWeek; self.hiddenCards = hiddenCards
        }

        /// Tolerant of a newer build's keys and of missing ones: anything unreadable falls back to the default.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(basis: (try? c.decodeIfPresent(TrendBasis.self, forKey: .basis)) ?? .trend,
                      rateMode: (try? c.decodeIfPresent(RateMode.self, forKey: .rateMode)) ?? .current,
                      rateWindowDays: (try? c.decodeIfPresent(Int.self, forKey: .rateWindowDays)) ?? 28,
                      milestoneStepKg: (try? c.decodeIfPresent(Double.self, forKey: .milestoneStepKg)) ?? nil,
                      manualWishKgPerWeek: (try? c.decodeIfPresent(Double.self, forKey: .manualWishKgPerWeek)) ?? nil,
                      hiddenCards: (try? c.decodeIfPresent([String].self, forKey: .hiddenCards)) ?? [])
        }
    }

    /// The page's cards the wearer can switch off. The headline and the log are always shown.
    public enum Card: String, CaseIterable, Sendable {
        case milestones, forecast, events, changes, week, chart, reports
    }

    /// A date the wearer wants a forecast for ("Wedding", 18 May). Separate from goals: it asks a question, it
    /// sets no target.
    public struct Event: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var name: String
        /// Local day key, yyyy-MM-dd.
        public var day: String
        public var createdAt: Date
        public init(id: String = UUID().uuidString, name: String, day: String, createdAt: Date = Date()) {
            self.id = id; self.name = name; self.day = day; self.createdAt = createdAt
        }
    }

    /// Settings and events as one stored value.
    public struct Stored: Codable, Equatable, Sendable {
        public var settings: Settings
        public var events: [Event]
        public init(settings: Settings = .standard, events: [Event] = []) {
            self.settings = settings; self.events = events
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            settings = (try? c.decodeIfPresent(Settings.self, forKey: .settings)) ?? .standard
            events = (try? c.decodeIfPresent([Event].self, forKey: .events)) ?? []
        }
        public func encoded() -> String? {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
        }
        public static func decode(_ raw: String?) -> Stored {
            guard let data = raw?.data(using: .utf8) else { return Stored() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return (try? decoder.decode(Stored.self, from: data)) ?? Stored()
        }
    }

    /// The goal-preferences key. Under `goals.`, so `GoalBackupBundle` carries it in every backup on both
    /// platforms without a whitelist entry of its own.
    public static let storageKey = "goals.weightTracker"

    // MARK: - Inputs

    public struct Reading: Equatable, Sendable {
        public var date: Date
        public var kg: Double
        public var note: String?
        /// The weigh-in's id when NOOP owns it (editable here); nil for an imported reading.
        public var id: String?
        public var source: String
        public init(date: Date, kg: Double, note: String? = nil, id: String? = nil, source: String = "") {
            self.date = date; self.kg = kg; self.note = note; self.id = id; self.source = source
        }
    }

    public struct Goal: Equatable, Sendable {
        public var baseline: Double
        public var target: Double
        public var createdAt: Date
        public var targetDate: Date?
        /// Half-width of the band for a maintain goal; nil for a goal that moves.
        public var band: Double?
        /// The goal's own stored waypoints, along the direction of travel.
        public var storedMilestones: [Double]
        public init(baseline: Double, target: Double, createdAt: Date, targetDate: Date? = nil, band: Double? = nil,
                    storedMilestones: [Double] = []) {
            self.baseline = baseline; self.target = target; self.createdAt = createdAt; self.targetDate = targetDate
            self.band = band; self.storedMilestones = storedMilestones
        }
        public var isMaintain: Bool { band != nil || baseline == target }
    }

    public struct Inputs: Sendable {
        public var readings: [Reading]
        public var goal: Goal?
        /// The active diet plan's pace in kg a week, signed (negative = losing); nil without a plan.
        public var planKgPerWeek: Double?
        public var settings: Settings
        public var events: [Event]
        public var now: Date
        public var calendar: Calendar
        public init(readings: [Reading], goal: Goal? = nil, planKgPerWeek: Double? = nil, settings: Settings = .standard,
                    events: [Event] = [], now: Date = Date(), calendar: Calendar = .current) {
            self.readings = readings; self.goal = goal; self.planKgPerWeek = planKgPerWeek; self.settings = settings
            self.events = events; self.now = now; self.calendar = calendar
        }
    }

    // MARK: - Output

    public struct Point: Equatable, Sendable {
        public var date: Date
        public var kg: Double
    }

    public struct Change: Equatable, Sendable {
        /// 7, 30 or 90; nil for "since the first weigh-in".
        public var days: Int?
        public var kg: Double
    }

    /// The last seven days: highest and lowest reading, the latest, and the trend.
    public struct Week: Equatable, Sendable {
        public var high: Point
        public var low: Point
        public var latest: Point
        public var trendKg: Double
        public var readings: [Point]
        public var trend: [Point]
    }

    public struct Rates: Equatable, Sendable {
        public var currentKgPerWeek: Double?
        public var overallKgPerWeek: Double?
        public var wishKgPerWeek: Double?
        public var wishSource: WishSource?
        /// The planned rate asks for more than about 1 % of body weight a week.
        public var wishIsSteep: Bool
    }

    public enum ForecastState: String, Equatable, Sendable {
        /// The rate reaches the goal; `targetDate` says when.
        case arriving
        /// The goal is already reached on the trend.
        case reached
        /// The rate points away from the goal: no date exists.
        case movingAway
        /// Right direction, but the date would lie years out.
        case tooSlow
        /// Too few weigh-ins for the chosen rate.
        case notEnoughData
        /// A maintain goal and the trend is inside the band.
        case withinBand
        /// A maintain goal and the trend is outside the band.
        case outsideBand
        /// No goal: only the rate and the events are forecast.
        case noGoal
    }

    public struct Forecast: Equatable, Sendable {
        /// The value the forecast starts from, and what it is.
        public var startKg: Double
        public var basis: TrendBasis
        /// When the ten-day low was weighed; the latest reading for the trend basis.
        public var startDate: Date
        public var rateMode: RateMode
        /// The rate in use, kg a week; nil when the chosen rate cannot be computed.
        public var rateKgPerWeek: Double?
        public var state: ForecastState
        public var targetDate: Date?
    }

    public enum EventPhase: String, Equatable, Sendable { case upcoming, passed, archived }

    public struct EventForecast: Equatable, Sendable, Identifiable {
        public var event: Event
        public var phase: EventPhase
        public var daysAway: Int
        /// The expected weight on the day, for an upcoming event; nil when the rate cannot be computed.
        public var predictedKg: Double?
        /// For a passed event: what the forecast said the day before, and what the scale said on the day (the
        /// nearest weigh-in within two days).
        public var predictedBeforeKg: Double?
        public var measuredKg: Double?
        public var id: String { event.id }
    }

    public struct Milestone: Equatable, Sendable {
        public var kg: Double
        /// The day a weigh-in first passed it since the goal began; nil while ahead.
        public var reachedDay: String?
    }

    public struct Milestones: Equatable, Sendable {
        public var route: [Milestone]
        public var reachedCount: Int
        public var next: Double?
        /// Kilograms from the trend to the next milestone, positive.
        public var toNextKg: Double?
        /// Share of the way from baseline to target on the trend, 0 to 1.
        public var progress: Double
    }

    public struct LogRow: Equatable, Sendable, Identifiable {
        public var reading: Reading
        public var day: String
        public var trendKg: Double
        /// The trend's change over the seven days up to this reading; nil until a week of history exists.
        public var weeklyRateKg: Double?
        /// The milestone this weigh-in reached first, if any.
        public var milestoneKg: Double?
        public var id: String { reading.id ?? "\(reading.source)-\(reading.date.timeIntervalSince1970)" }
    }

    public enum Period: String, Equatable, Sendable { case month, year }

    public struct Report: Equatable, Sendable, Identifiable {
        public var period: Period
        /// "2026-11" or "2026".
        public var key: String
        public var start: Date
        public var count: Int
        /// At least `minimumReportReadings` weigh-ins; below that the screens say there were too few.
        public var enough: Bool
        public var low: Point?
        public var averageKg: Double?
        public var trendChangeKg: Double?
        public var ratePerWeekKg: Double?
        /// This period's average against the previous one's, when both had enough weigh-ins.
        public var vsPreviousKg: Double?
        public var readings: [Point]
        public var trend: [Point]
        public var id: String { "\(period.rawValue)-\(key)" }
    }

    public struct Snapshot: Equatable, Sendable {
        public var latest: Point
        public var trendKg: Double
        /// False while the smoothing is still cold-starting.
        public var trendSettled: Bool
        public var readingCount: Int
        public var changes: [Change]
        public var week: Week?
        public var rates: Rates
        public var forecast: Forecast
        public var events: [EventForecast]
        public var milestones: Milestones?
        public var goal: Goal?
        /// Newest first.
        public var log: [LogRow]
        /// Newest first.
        public var months: [Report]
        public var years: [Report]
        public var readings: [Point]
        public var trend: [Point]
    }

    // MARK: - Constants

    public static let minimumReportReadings = 4
    /// How long a passed event stays on the page before it moves to the archive.
    public static let passedEventDays = 14
    /// A forecast further out than this says "too slow" rather than print a date.
    public static let horizonDays = 3 * 365
    /// Above about 1 % of body weight a week a planned rate is flagged.
    public static let steepShareOfBodyWeight = 0.01
    /// The ten-day low looks back this far.
    public static let lowWindowDays = 10
    /// The overall rate needs this span and these readings.
    public static let overallMinimumDays = 14
    public static let overallMinimumReadings = 8

    // MARK: - Derivation

    public static func snapshot(_ inputs: Inputs) -> Snapshot? {
        let usable = inputs.readings
            .filter { GoalMeasure.isPlausible($0.kg, cfg: GoalMeasure.weightTrend) && $0.date <= inputs.now }
            .sorted { $0.date < $1.date }
        guard let newest = usable.last else { return nil }
        let centres = GoalMeasure.smoothedSeries(dated: usable.map { (date: $0.date, value: $0.kg) },
                                                 cfg: GoalMeasure.weightTrend)
        guard centres.count == usable.count, let trendNow = centres.last else { return nil }
        let trend = zip(usable, centres).map { Point(date: $0.date, kg: $1) }
        let raw = usable.map { Point(date: $0.date, kg: $0.kg) }
        let cal = inputs.calendar
        let now = inputs.now

        func centre(atOrBefore date: Date) -> Double? { trend.last(where: { $0.date <= date })?.kg }
        func daysAgo(_ d: Int) -> Date { now.addingTimeInterval(-Double(d) * 86_400) }

        // Changes on the trend: 7, 30, 90 days and since the first weigh-in.
        var changes: [Change] = []
        for d in [7, 30, 90] {
            if let then = centre(atOrBefore: daysAgo(d)) { changes.append(Change(days: d, kg: trendNow - then)) }
        }
        if let first = trend.first, trend.count > 1 { changes.append(Change(days: nil, kg: trendNow - first.kg)) }

        let week = weekCard(raw: raw, trend: trend, now: now, trendNow: trendNow)
        let rates = rates(inputs: inputs, trend: trend, trendNow: trendNow)
        let forecast = forecast(inputs: inputs, raw: raw, trendNow: trendNow, latest: raw.last!, rates: rates)
        let events = eventForecasts(inputs: inputs, readings: usable, forecast: forecast, cal: cal)
        let milestones = inputs.goal.flatMap { milestoneRoute(goal: $0, settings: inputs.settings, readings: usable,
                                                              trendNow: trendNow, cal: cal) }
        let log = logRows(readings: usable, trend: trend, milestones: milestones, cal: cal)
        let months = reports(.month, readings: usable, trend: trend, cal: cal)
        let years = reports(.year, readings: usable, trend: trend, cal: cal)

        return Snapshot(latest: Point(date: newest.date, kg: newest.kg), trendKg: trendNow,
                        trendSettled: centres.count >= GoalMeasure.trendReliableAfter, readingCount: usable.count,
                        changes: changes, week: week, rates: rates, forecast: forecast, events: events,
                        milestones: milestones, goal: inputs.goal, log: log, months: months, years: years,
                        readings: raw, trend: trend)
    }

    static func weekCard(raw: [Point], trend: [Point], now: Date, trendNow: Double) -> Week? {
        let cutoff = now.addingTimeInterval(-7 * 86_400)
        let inWeek = raw.filter { $0.date > cutoff }
        guard let high = inWeek.max(by: { $0.kg < $1.kg }), let low = inWeek.min(by: { $0.kg < $1.kg }),
              let latest = inWeek.last else { return nil }
        return Week(high: high, low: low, latest: latest, trendKg: trendNow, readings: inWeek,
                    trend: trend.filter { $0.date > cutoff })
    }

    static func rates(inputs: Inputs, trend: [Point], trendNow: Double) -> Rates {
        let samples = trend.map { GoalMilestones.Sample(date: $0.date, value: $0.kg) }
        let current = GoalMilestones.observedRatePerDay(series: samples, now: inputs.now,
                                                        windowDays: inputs.settings.rateWindowDays).map { $0 * 7 }
        // Overall: since the goal began, or since the first weigh-in without one.
        let from = inputs.goal?.createdAt ?? trend.first?.date ?? inputs.now
        let span = trend.filter { $0.date >= from }
        var overall: Double?
        if let first = span.first, let last = span.last, span.count >= overallMinimumReadings {
            let days = last.date.timeIntervalSince(first.date) / 86_400
            if days >= Double(overallMinimumDays) { overall = (last.kg - first.kg) / days * 7 }
        }
        var wish: Double?
        var source: WishSource?
        if let plan = inputs.planKgPerWeek {
            wish = plan; source = .dietPlan
        } else if let goal = inputs.goal, !goal.isMaintain, let end = goal.targetDate, end > goal.createdAt {
            let weeks = end.timeIntervalSince(goal.createdAt) / (7 * 86_400)
            wish = (goal.target - goal.baseline) / weeks; source = .goal
        } else if let manual = inputs.settings.manualWishKgPerWeek {
            wish = manual; source = .manual
        }
        let steep = wish.map { abs($0) > trendNow * steepShareOfBodyWeight } ?? false
        return Rates(currentKgPerWeek: current, overallKgPerWeek: overall, wishKgPerWeek: wish, wishSource: source,
                     wishIsSteep: steep)
    }

    static func forecast(inputs: Inputs, raw: [Point], trendNow: Double, latest: Point, rates: Rates) -> Forecast {
        let settings = inputs.settings
        var start = Point(date: latest.date, kg: trendNow)
        var basis = TrendBasis.trend
        if settings.basis == .tenDayLow {
            // No weigh-in in the last ten days leaves no low to start from: the trend stands in, and says so.
            let cutoff = inputs.now.addingTimeInterval(-Double(lowWindowDays) * 86_400)
            if let low = raw.filter({ $0.date > cutoff }).min(by: { $0.kg < $1.kg }) { start = low; basis = .tenDayLow }
        }
        let rate: Double? = switch settings.rateMode {
        case .current: rates.currentKgPerWeek
        case .overall: rates.overallKgPerWeek
        case .wish: rates.wishKgPerWeek
        }
        var state = ForecastState.noGoal
        var arrival: Date?
        if let goal = inputs.goal {
            if goal.isMaintain {
                state = abs(trendNow - goal.target) <= (goal.band ?? 0) ? .withinBand : .outsideBand
            } else {
                let toward = goal.target > goal.baseline ? 1.0 : -1.0
                let remaining = goal.target - start.kg
                if remaining * toward <= 0 {
                    state = .reached
                } else if let r = rate {
                    let perDay = r / 7
                    if perDay * toward <= 1e-9 {
                        state = .movingAway
                    } else {
                        let days = remaining / perDay
                        if days > Double(horizonDays) { state = .tooSlow } else {
                            state = .arriving
                            arrival = inputs.now.addingTimeInterval(days * 86_400)
                        }
                    }
                } else {
                    state = .notEnoughData
                }
            }
        }
        return Forecast(startKg: start.kg, basis: basis,
                        startDate: start.date, rateMode: settings.rateMode, rateKgPerWeek: rate, state: state,
                        targetDate: arrival)
    }

    static func dayKey(_ date: Date, _ cal: Calendar) -> String {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(forDay day: String, _ cal: Calendar) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    static func eventForecasts(inputs: Inputs, readings: [Reading], forecast: Forecast, cal: Calendar) -> [EventForecast] {
        let today = cal.startOfDay(for: inputs.now)
        return inputs.events.compactMap { event -> EventForecast? in
            guard let day = date(forDay: event.day, cal) else { return nil }
            let daysAway = cal.dateComponents([.day], from: today, to: day).day ?? 0
            if daysAway >= 0 {
                let predicted = forecast.rateKgPerWeek.map { forecast.startKg + $0 / 7 * Double(daysAway) }
                return EventForecast(event: event, phase: .upcoming, daysAway: daysAway, predictedKg: predicted)
            }
            // Passed: what the forecast said the day before, against the scale on the day.
            var before = inputs
            before.now = day.addingTimeInterval(-1)
            before.events = []
            before.readings = readings.filter { $0.date < day }
            let earlier = before.readings.isEmpty ? nil : snapshot(before)
            let predictedBefore = earlier.flatMap { s in s.forecast.rateKgPerWeek.map { s.forecast.startKg + $0 / 7 } }
            let window = readings.filter { abs($0.date.timeIntervalSince(day.addingTimeInterval(12 * 3_600))) <= 2.5 * 86_400 }
            let measured = window.min { abs($0.date.timeIntervalSince(day)) < abs($1.date.timeIntervalSince(day)) }?.kg
            let phase: EventPhase = -daysAway > passedEventDays ? .archived : .passed
            return EventForecast(event: event, phase: phase, daysAway: daysAway, predictedKg: nil,
                                 predictedBeforeKg: predictedBefore, measuredKg: measured)
        }
        .sorted { a, b in
            if a.phase != b.phase { return a.phase == .upcoming || (a.phase == .passed && b.phase == .archived) }
            return a.phase == .upcoming ? a.daysAway < b.daysAway : a.daysAway > b.daysAway
        }
    }

    static func milestoneRoute(goal: Goal, settings: Settings, readings: [Reading], trendNow: Double,
                               cal: Calendar) -> Milestones? {
        guard !goal.isMaintain else { return nil }
        let values: [Double]
        if let step = settings.milestoneStepKg {
            values = GoalMilestones.values(baseline: goal.baseline, target: goal.target, step: step)
        } else if !goal.storedMilestones.isEmpty {
            values = goal.storedMilestones
        } else {
            values = GoalMilestones.values(baseline: goal.baseline, target: goal.target)
        }
        guard !values.isEmpty else { return nil }
        let toward = goal.target > goal.baseline ? 1.0 : -1.0
        let since = readings.filter { $0.date >= goal.createdAt }
        let route = values.map { value -> Milestone in
            let first = since.first { ($0.kg - value) * toward >= -1e-9 }
            return Milestone(kg: value, reachedDay: first.map { dayKey($0.date, cal) })
        }
        let reached = route.filter { $0.reachedDay != nil }.count
        let next = route.first { $0.reachedDay == nil }?.kg
        let span = goal.target - goal.baseline
        let progress = span == 0 ? 1 : min(1, max(0, (trendNow - goal.baseline) / span))
        return Milestones(route: route, reachedCount: reached, next: next,
                          toNextKg: next.map { abs($0 - trendNow) }, progress: progress)
    }

    static func logRows(readings: [Reading], trend: [Point], milestones: Milestones?, cal: Calendar) -> [LogRow] {
        var rows: [LogRow] = []
        var claimed = Set<Double>()
        for (i, r) in readings.enumerated() {
            let t = trend[i].kg
            let weekAgo = r.date.addingTimeInterval(-7 * 86_400)
            let then = trend[..<i].last(where: { $0.date <= weekAgo })?.kg
            let day = dayKey(r.date, cal)
            var reachedHere: Double?
            for m in milestones?.route ?? [] where m.reachedDay == day && !claimed.contains(m.kg) {
                reachedHere = m.kg   // the furthest waypoint first passed on this day
            }
            if let m = reachedHere {
                // Only the first weigh-in of that day carries the mark.
                claimed.formUnion(milestones?.route.filter { $0.reachedDay == day }.map(\.kg) ?? [m])
            }
            rows.append(LogRow(reading: r, day: day, trendKg: t, weeklyRateKg: then.map { t - $0 }, milestoneKg: reachedHere))
        }
        return rows.reversed()
    }

    static func reports(_ period: Period, readings: [Reading], trend: [Point], cal: Calendar) -> [Report] {
        func key(_ d: Date) -> String {
            let c = cal.dateComponents([.year, .month], from: d)
            return period == .month ? String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0) : String(format: "%04d", c.year ?? 0)
        }
        func start(_ d: Date) -> Date {
            let c = cal.dateComponents(period == .month ? [.year, .month] : [.year], from: d)
            return cal.date(from: c) ?? d
        }
        var order: [String] = []
        var groups: [String: [Int]] = [:]
        for (i, r) in readings.enumerated() {
            let k = key(r.date)
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(i)
        }
        func previousKey(_ k: String) -> String {
            let parts = k.split(separator: "-").compactMap { Int($0) }
            if period == .year { return String(format: "%04d", (parts.first ?? 0) - 1) }
            let (y, m) = (parts[0], parts[1])
            return m == 1 ? String(format: "%04d-12", y - 1) : String(format: "%04d-%02d", y, m - 1)
        }
        var result: [Report] = []
        var averages: [String: Double] = [:]
        for k in order {
            let idx = groups[k] ?? []
            guard let firstIndex = idx.first, let lastIndex = idx.last else { continue }
            let pts = idx.map { Point(date: readings[$0].date, kg: readings[$0].kg) }
            let trendPts = idx.map { trend[$0] }
            let enough = pts.count >= minimumReportReadings
            let average = pts.map(\.kg).reduce(0, +) / Double(pts.count)
            // The change runs from the trend before the period (or its first reading) to its last reading.
            let from = firstIndex > 0 ? trend[firstIndex - 1] : trend[firstIndex]
            let to = trend[lastIndex]
            let days = to.date.timeIntervalSince(from.date) / 86_400
            let change = enough ? to.kg - from.kg : nil
            let rate = (enough && days >= 7) ? (to.kg - from.kg) / days * 7 : nil
            result.append(Report(period: period, key: k, start: start(readings[firstIndex].date), count: pts.count,
                                 enough: enough, low: enough ? pts.min(by: { $0.kg < $1.kg }) : nil,
                                 averageKg: enough ? average : nil, trendChangeKg: change, ratePerWeekKg: rate,
                                 vsPreviousKg: enough ? averages[previousKey(k)].map { average - $0 } : nil,
                                 readings: pts, trend: trendPts))
            if enough { averages[k] = average }
        }
        return result.reversed()
    }
}
