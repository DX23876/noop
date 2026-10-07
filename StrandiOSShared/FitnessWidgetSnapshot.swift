import Foundation

/// What the app publishes for the ten fitness widgets (sleep, HRV, resting HR, Charge and Effort weeks,
/// steps, weight, workouts, consistency, vitals). One small App-Group payload beside `WidgetSnapshot` and
/// `GoalWidgetSnapshot`: numbers already resolved by the app, names already localized, so the extension
/// never opens the database or links the analytics.
///
/// Every field a widget draws is optional or may be empty, and each widget says "no data yet" for its
/// own part rather than inventing a value.
public struct FitnessWidgetSnapshot: Codable, Equatable {

    /// A wearer's usual range for a metric: the middle of the last 30 days (mean ± one standard
    /// deviation), the band the HRV and resting-HR charts draw behind the line.
    public struct Usual: Codable, Equatable {
        public var low: Double
        public var high: Double
        public init(low: Double, high: Double) {
            self.low = low
            self.high = high
        }
        public func contains(_ value: Double) -> Bool { value >= low && value <= high }
    }

    /// Last night: how long, against the wearer's own need, and how it split into stages.
    public struct Sleep: Codable, Equatable {
        public var day: String
        public var totalMin: Double
        public var needMin: Double?
        public var deepMin: Double?
        public var remMin: Double?
        public var lightMin: Double?
        public var efficiency: Double?
        public init(day: String, totalMin: Double, needMin: Double?, deepMin: Double?, remMin: Double?,
                    lightMin: Double?, efficiency: Double?) {
            self.day = day
            self.totalMin = totalMin
            self.needMin = needMin
            self.deepMin = deepMin
            self.remMin = remMin
            self.lightMin = lightMin
            self.efficiency = efficiency
        }
    }

    /// The scale's own readings (never a smoothed trend), in the wearer's unit.
    public struct Weight: Codable, Equatable {
        public struct Reading: Codable, Equatable {
            public var day: String
            public var value: Double
            public init(day: String, value: Double) {
                self.day = day
                self.value = value
            }
        }
        /// "kg" or "lb".
        public var unit: String
        /// The last 30 days' weigh-ins, oldest first; the last one is the headline.
        public var readings: [Reading]
        /// Latest minus the first reading of the window, in `unit`; nil with a single reading.
        public var change: Double?
        public init(unit: String, readings: [Reading], change: Double?) {
            self.unit = unit
            self.readings = readings
            self.change = change
        }
        public var latest: Reading? { readings.last }
    }

    /// The running training week.
    public struct Workouts: Codable, Equatable {
        public var count: Int
        public var minutes: Int
        /// One flag per day of the training week, first weekday first.
        public var trainedDays: [Bool]
        /// One letter per day of the training week, localized.
        public var weekLetters: [String]
        /// Index of today in `trainedDays`.
        public var todayIndex: Int
        /// The last workout, any week: its sport as the app names it, its symbol, its day and length.
        public var lastName: String?
        public var lastSymbol: String?
        public var lastDay: String?
        public var lastMinutes: Int?
        public init(count: Int, minutes: Int, trainedDays: [Bool], weekLetters: [String], todayIndex: Int,
                    lastName: String?, lastSymbol: String?, lastDay: String?, lastMinutes: Int?) {
            self.count = count
            self.minutes = minutes
            self.trainedDays = trainedDays
            self.weekLetters = weekLetters
            self.todayIndex = todayIndex
            self.lastName = lastName
            self.lastSymbol = lastSymbol
            self.lastDay = lastDay
            self.lastMinutes = lastMinutes
        }
    }

    /// One overnight vital against the wearer's usual range.
    public struct Vital: Codable, Equatable, Identifiable {
        /// "spo2", "resp" or "skinTemp".
        public var id: String
        public var name: String
        public var symbol: String
        public var value: Double
        /// The value as the app writes it: "96 %", "14.6 rpm", "+0.3 °C".
        public var text: String
        public var usual: Usual?
        public init(id: String, name: String, symbol: String, value: Double, text: String, usual: Usual?) {
            self.id = id
            self.name = name
            self.symbol = symbol
            self.value = value
            self.text = text
            self.usual = usual
        }
        /// Nil while there is no usual range to judge against yet.
        public var inRange: Bool? { usual.map { $0.contains(value) } }
    }

    /// Day keys (yyyy-MM-dd) of the series below, oldest first: the last 14 local days, today last.
    public var days: [String]
    /// One localized letter per day ("M").
    public var dayLetters: [String]
    /// Charge 0…100 per day.
    public var charge: [Double?]
    /// Effort on NOOP's 0…100 axis per day, for the bar heights.
    public var effort: [Double?]
    /// Effort as the wearer reads it (0…21 or 0…100), per day.
    public var effortTexts: [String?]
    public var hrv: [Double?]
    public var rhr: [Double?]
    public var sleepHours: [Double?]
    public var steps: [Int?]
    public var hrvUsual: Usual?
    public var rhrUsual: Usual?
    public var sleep: Sleep?
    /// The wearer's daily step goal, when one is set.
    public var stepsGoal: Int?
    public var weight: Weight?
    public var workouts: Workouts?
    /// The last 84 days, oldest first: true when a workout was logged that day; nil before the wearer's
    /// first record of any kind.
    public var activeDays: [Bool?]
    public var vitals: [Vital]
    public var updated: Date

    public init(days: [String], dayLetters: [String], charge: [Double?], effort: [Double?],
                effortTexts: [String?], hrv: [Double?], rhr: [Double?], sleepHours: [Double?], steps: [Int?],
                hrvUsual: Usual?, rhrUsual: Usual?, sleep: Sleep?, stepsGoal: Int?, weight: Weight?,
                workouts: Workouts?, activeDays: [Bool?], vitals: [Vital], updated: Date) {
        self.days = days
        self.dayLetters = dayLetters
        self.charge = charge
        self.effort = effort
        self.effortTexts = effortTexts
        self.hrv = hrv
        self.rhr = rhr
        self.sleepHours = sleepHours
        self.steps = steps
        self.hrvUsual = hrvUsual
        self.rhrUsual = rhrUsual
        self.sleep = sleep
        self.stepsGoal = stepsGoal
        self.weight = weight
        self.workouts = workouts
        self.activeDays = activeDays
        self.vitals = vitals
        self.updated = updated
    }

    /// The last `count` values of a 14-day series.
    public static func tail<T>(_ series: [T], _ count: Int) -> [T] { Array(series.suffix(count)) }

    public static let storageKey = "noop.widget.fitness"

    /// The widget kinds reloaded after a publish.
    public static let widgetKinds = [
        "NOOPSleepWidget", "NOOPHrvWidget", "NOOPRestingHrWidget", "NOOPChargeWeekWidget",
        "NOOPEffortWeekWidget", "NOOPStepsWidget", "NOOPWeightWidget", "NOOPWorkoutsWidget",
        "NOOPConsistencyWidget", "NOOPVitalsWidget",
    ]

    public static func load() -> FitnessWidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName),
              let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(FitnessWidgetSnapshot.self, from: data)
    }

    /// Store the snapshot; false when it matches what is stored already (the time aside), so the
    /// widgets are not rebuilt for nothing.
    @discardableResult
    public func save() -> Bool {
        guard let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName) else { return false }
        if let previous = FitnessWidgetSnapshot.load() {
            var a = previous, b = self
            a.updated = .distantPast
            b.updated = .distantPast
            if a == b { return false }
        }
        guard let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: FitnessWidgetSnapshot.storageKey)
        return true
    }
}
