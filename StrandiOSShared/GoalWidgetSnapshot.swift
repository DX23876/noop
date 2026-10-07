import Foundation

/// The goals the app publishes for the goal widget, the lock-screen goal accessories and Siri. A tiny
/// App-Group payload of its own (beside `WidgetSnapshot`), already worded and coloured by the app, so the
/// extension never links the analytics or opens the database.
public struct GoalWidgetSnapshot: Codable, Equatable {

    public struct Goal: Codable, Equatable, Identifiable {
        public var id: String
        /// "Runs", "Nights of 7 h".
        public var name: String
        /// "4 workouts a week".
        public var title: String
        public var symbol: String
        /// "week", "month" or "longTerm".
        public var period: String
        /// The state word, already localized ("On track").
        public var stateWord: String
        public var stateSymbol: String
        /// positive · warning · critical · neutral · accent — mapped to colours by the widget.
        public var tone: String
        /// "2/4".
        public var progress: String
        /// "2 to go · 4 days left".
        public var remaining: String
        /// The big line on the small widget: "2 to go", or the state when there is nothing left.
        public var headline: String
        public var fraction: Double
        public var paceFraction: Double?
        public var needsAttention: Bool
        /// The goal drawn in its own shape. Nil in an older payload, where the widget falls back to the
        /// pace track from `fraction` and `paceFraction`.
        public var glyph: Glyph?
        /// The identity colour key (`AppleInspiredColors`) the shape is drawn in; empty or nil draws the
        /// state's tone, as before.
        public var colorKey: String?

        /// A long-term goal: its page is not one of the routes a widget link can open, so its tap opens
        /// the goals overview.
        public var isLongTerm: Bool { period == "longTerm" }

        public init(id: String, name: String, title: String, symbol: String, period: String,
                    stateWord: String, stateSymbol: String, tone: String, progress: String,
                    remaining: String, headline: String, fraction: Double, paceFraction: Double?,
                    needsAttention: Bool, glyph: Glyph? = nil, colorKey: String? = nil) {
            self.id = id
            self.name = name
            self.title = title
            self.symbol = symbol
            self.period = period
            self.stateWord = stateWord
            self.stateSymbol = stateSymbol
            self.tone = tone
            self.progress = progress
            self.remaining = remaining
            self.headline = headline
            self.fraction = fraction
            self.paceFraction = paceFraction
            self.needsAttention = needsAttention
            self.glyph = glyph
            self.colorKey = colorKey
        }
    }

    /// A measured daily goal (steps, active kcal, sleep) as a ring: today's reading against the target.
    public struct Daily: Codable, Equatable, Identifiable {
        public var id: String
        /// "Steps".
        public var name: String
        public var symbol: String
        /// The identity colour key (`AppleInspiredColors`); empty draws the accent.
        public var colorKey: String
        /// "7,328".
        public var value: String
        /// "of 10,000 steps".
        public var target: String
        public var fraction: Double
        public var done: Bool

        public init(id: String, name: String, symbol: String, colorKey: String, value: String, target: String,
                    fraction: Double, done: Bool) {
            self.id = id
            self.name = name
            self.symbol = symbol
            self.colorKey = colorKey
            self.value = value
            self.target = target
            self.fraction = fraction
            self.done = done
        }
    }

    /// Weekly goals first, in the wearer's order, then monthly ones.
    public var goals: [Goal]
    /// "This week · 4 days left".
    public var weekLabel: String
    /// "2 of 3 on course".
    public var summary: String
    public var updated: Date
    /// Today's measured daily goals in ring order. Optional so a payload from before it still decodes.
    public var daily: [Daily]?
    /// The weekly and monthly goals worth a line today, most urgent first (the app's `GoalSpotlight`).
    public var spotlightIds: [String]?
    /// All of today's daily goals and how many are done, rings or not ("6 of 10").
    public var dailyTotal: Int?
    public var dailyDone: Int?
    /// The start of the day after the training week ends, so the widget can count the days left at the
    /// moment it draws instead of showing the count from the last publish. Nil in an older payload.
    public var weekEnd: Date?

    public init(goals: [Goal], weekLabel: String, summary: String, updated: Date,
                daily: [Daily]? = nil, spotlightIds: [String]? = nil, dailyTotal: Int? = nil, dailyDone: Int? = nil,
                weekEnd: Date? = nil) {
        self.goals = goals
        self.weekLabel = weekLabel
        self.summary = summary
        self.updated = updated
        self.daily = daily
        self.spotlightIds = spotlightIds
        self.dailyTotal = dailyTotal
        self.dailyDone = dailyDone
        self.weekEnd = weekEnd
    }

    /// Whole days from `date`'s day to the end of the week, today included; nil without a stored end.
    public func daysLeft(at date: Date, calendar: Calendar = .current) -> Int? {
        guard let weekEnd else { return nil }
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: weekEnd).day
    }

    /// "6 of 10" when there are daily goals beyond the rings; nil otherwise.
    public var dailyTally: (done: Int, total: Int)? {
        guard let total = dailyTotal, let done = dailyDone, total > dailyGoals.count else { return nil }
        return (done, total)
    }

    public var dailyGoals: [Daily] { daily ?? [] }

    /// The goals worth showing today, most urgent first. Without a stored choice (an older app), the
    /// ones needing attention.
    public var spotlight: [Goal] {
        guard let ids = spotlightIds else { return goals.filter(\.needsAttention) }
        return ids.compactMap { id in goals.first { $0.id == id } }
    }

    public static let storageKey = "noop.widget.goals"
    public static let widgetKind = "NOOPGoalWidget"

    public static func load() -> GoalWidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(GoalWidgetSnapshot.self, from: data)
    }

    /// Writes the snapshot; returns false when nothing the widget renders changed.
    @discardableResult
    public func save() -> Bool {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) else { return false }
        if let previous = GoalWidgetSnapshot.load() {
            var a = previous, b = self
            a.updated = .distantPast
            b.updated = .distantPast
            if a == b { return false }
        }
        guard let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: GoalWidgetSnapshot.storageKey)
        return true
    }

    /// The goal a widget configured with `id` shows: that goal, or the most important one (the first
    /// needing attention, else the first) when `id` is nil or no longer exists.
    public func goal(for id: String?) -> Goal? {
        if let id, let match = goals.first(where: { $0.id == id }) { return match }
        return spotlight.first ?? goals.first(where: \.needsAttention) ?? goals.first
    }

    /// The gallery preview: one goal of each common shape, so the picker shows what the widget draws.
    public static var placeholder: GoalWidgetSnapshot {
        GoalWidgetSnapshot(goals: [
            .init(id: "w", name: "Lose weight", title: "Lose weight", symbol: "scalemass.fill", period: "longTerm",
                  stateWord: "On track", stateSymbol: "checkmark.circle", tone: "positive", progress: "92.4 kg",
                  remaining: "target 85 kg", headline: "92.4 kg", fraction: 0.38, paceFraction: nil,
                  needsAttention: false, glyph: Glyph(kind: "way", fraction: 0.38, marks: [0.25, 0.5, 0.75]),
                  colorKey: "coach.goal.weight"),
            .init(id: "d", name: "Run 500 km", title: "Run 500 km", symbol: "figure.run", period: "longTerm",
                  stateWord: "Behind", stateSymbol: "arrow.down.right", tone: "warning", progress: "312 km",
                  remaining: "of 500 km", headline: "312 km", fraction: 0.62, paceFraction: nil,
                  needsAttention: true, glyph: Glyph(kind: "track", fraction: 0.62, paceFraction: 0.7),
                  colorKey: "coach.goal.run"),
            .init(id: "b", name: "Nights of 7 h", title: "5 nights of 7 h a week", symbol: "moon.stars.fill",
                  period: "week", stateWord: "Close", stateSymbol: "exclamationmark", tone: "warning",
                  progress: "2/5", remaining: "3 to go · 4 days left", headline: "3 to go", fraction: 0.4,
                  paceFraction: 0.6, needsAttention: true,
                  glyph: Glyph(kind: "days", states: ["met", "missed", "met", "today", "future", "future", "future"]),
                  colorKey: "coach.goal.sleep"),
        ], weekLabel: "This week · 4 days left", summary: "2 of 3 on course", updated: Date(),
           daily: [], spotlightIds: ["d", "b", "w"], dailyTotal: 3, dailyDone: 1)
    }
}
