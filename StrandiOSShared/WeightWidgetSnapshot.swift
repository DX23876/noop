import Foundation

/// What the weight widgets draw (owner decisions 2026-11-26): already worded and formatted by the app from the one
/// `WeightTracker` snapshot, so the extension never links the analytics, opens the database or does arithmetic of
/// its own. A tiny App-Group payload beside `WidgetSnapshot`.
public struct WeightWidgetSnapshot: Codable, Equatable {
    public struct Figure: Codable, Equatable {
        public var label: String
        public var value: String
        public init(label: String, value: String) { self.label = label; self.value = value }
    }

    public struct Event: Codable, Equatable, Identifiable {
        public var id: String
        public var name: String
        public var date: Date
        /// "94.9" in the wearer's unit, or nil when no rate exists.
        public var expected: String?
        /// "at −0.5 kg a week".
        public var rateLine: String?
        public init(id: String, name: String, date: Date, expected: String?, rateLine: String?) {
            self.id = id; self.name = name; self.date = date; self.expected = expected; self.rateLine = rateLine
        }
    }

    public var unit: String
    /// The trend, "96.1".
    public var trend: String
    public var trendSettled: Bool
    /// "−0.5 kg a week", nil without a rate.
    public var rateLine: String?
    /// "96.8", the newest weigh-in.
    public var latest: String
    public var latestDate: Date
    /// The month the month card describes, "November 2026".
    public var monthLabel: String
    public var month: [Figure]
    /// The key figures card, in order.
    public var figures: [Figure]
    /// The trend over the last 30 days, oldest first, for the line.
    public var line: [Double]
    public var events: [Event]
    public var updated: Date

    public init(unit: String, trend: String, trendSettled: Bool, rateLine: String?, latest: String, latestDate: Date,
                monthLabel: String, month: [Figure], figures: [Figure], line: [Double], events: [Event], updated: Date) {
        self.unit = unit; self.trend = trend; self.trendSettled = trendSettled; self.rateLine = rateLine
        self.latest = latest; self.latestDate = latestDate; self.monthLabel = monthLabel; self.month = month
        self.figures = figures; self.line = line; self.events = events; self.updated = updated
    }

    public static let storageKey = "noop.widget.weight"
    public static let kinds = ["NOOPWeightTrendWidget", "NOOPWeightMonthWidget", "NOOPWeightFiguresWidget",
                               "NOOPWeightEventWidget"]

    public static func load() -> WeightWidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(WeightWidgetSnapshot.self, from: data)
    }

    /// Writes the snapshot; false when nothing the widgets draw changed.
    @discardableResult
    public func save() -> Bool {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) else { return false }
        if var previous = WeightWidgetSnapshot.load() {
            previous.updated = updated
            if previous == self { return false }
        }
        guard let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: WeightWidgetSnapshot.storageKey)
        return true
    }

    /// The widget gallery's stand-in.
    public static var placeholder: WeightWidgetSnapshot {
        WeightWidgetSnapshot(
            unit: "kg", trend: "86.4", trendSettled: true, rateLine: "−0.5 kg a week", latest: "86.1",
            latestDate: Date(), monthLabel: "November",
            month: [Figure(label: "Lowest", value: "85.9"), Figure(label: "Average", value: "86.6"),
                    Figure(label: "vs October", value: "−1.8")],
            figures: [Figure(label: "Latest", value: "86.1"), Figure(label: "Trend", value: "86.4"),
                      Figure(label: "Per week", value: "−0.5"), Figure(label: "10-day low", value: "85.9"),
                      Figure(label: "Progress", value: "62 %"), Figure(label: "Next stop", value: "85.0")],
            line: [88.4, 88.1, 87.9, 87.8, 87.5, 87.3, 87.2, 86.9, 86.8, 86.6, 86.4],
            events: [Event(id: "p", name: "Holiday", date: Date().addingTimeInterval(30 * 86_400), expected: "84.3",
                           rateLine: "at −0.5 kg a week")],
            updated: Date())
    }
}
