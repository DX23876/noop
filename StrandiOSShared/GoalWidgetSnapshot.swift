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
        /// "week" or "month".
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

        public init(id: String, name: String, title: String, symbol: String, period: String,
                    stateWord: String, stateSymbol: String, tone: String, progress: String,
                    remaining: String, headline: String, fraction: Double, paceFraction: Double?,
                    needsAttention: Bool) {
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
        }
    }

    /// Weekly goals first, in the wearer's order, then monthly ones.
    public var goals: [Goal]
    /// "This week · 4 days left".
    public var weekLabel: String
    /// "2 of 3 on course".
    public var summary: String
    public var updated: Date

    public init(goals: [Goal], weekLabel: String, summary: String, updated: Date) {
        self.goals = goals
        self.weekLabel = weekLabel
        self.summary = summary
        self.updated = updated
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
        return goals.first(where: \.needsAttention) ?? goals.first
    }

    public static var placeholder: GoalWidgetSnapshot {
        GoalWidgetSnapshot(goals: [
            .init(id: "a", name: "Runs", title: "4 runs a week", symbol: "figure.run", period: "week",
                  stateWord: "On track", stateSymbol: "circle.fill", tone: "positive", progress: "2/4",
                  remaining: "2 to go · 4 days left", headline: "2 to go", fraction: 0.5, paceFraction: 0.57,
                  needsAttention: false),
            .init(id: "b", name: "Nights of 7 h", title: "5 nights of 7 h a week", symbol: "moon.stars.fill",
                  period: "week", stateWord: "Close", stateSymbol: "exclamationmark", tone: "warning",
                  progress: "2/5", remaining: "3 to go · 4 days left", headline: "3 to go", fraction: 0.4,
                  paceFraction: 0.6, needsAttention: true),
            .init(id: "c", name: "Working sets", title: "60 sets a week", symbol: "dumbbell.fill", period: "week",
                  stateWord: "Achieved", stateSymbol: "checkmark.circle.fill", tone: "positive", progress: "64/60",
                  remaining: "4 over target", headline: "Achieved", fraction: 1.07, paceFraction: nil,
                  needsAttention: false),
        ], weekLabel: "This week · 4 days left", summary: "2 of 3 on course", updated: Date())
    }
}
