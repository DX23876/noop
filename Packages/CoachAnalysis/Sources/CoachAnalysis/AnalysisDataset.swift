import Foundation

/// Whether a series belongs to a calendar day or to a night.
public enum SeriesKind: String, Codable, Sendable {
    /// A value that belongs to the day it is keyed under (steps, strain, energy).
    case daily
    /// A value measured over a night, keyed under the day the wearer WOKE UP (sleep, overnight HRV,
    /// resting HR, respiration). This is the contract the app's dataset builder guarantees, and what gives
    /// `night_before` and `night_after` one meaning each.
    case nightly
}

/// One local metric, one value per day at most.
public struct DailySeries: Sendable, Equatable {
    public let key: String
    public let kind: SeriesKind
    public let unit: String?
    /// Values by `yyyy-MM-dd` day key.
    public var values: [String: Double]

    public init(key: String, kind: SeriesKind, unit: String? = nil, values: [String: Double]) {
        self.key = key
        self.kind = kind
        self.unit = unit
        self.values = values.filter { $0.value.isFinite }
    }
}

/// Something that happened on a day — today only workouts. Carries categories and numbers, never free
/// text, so nothing a wearer typed (or an import supplied) can reach the model through an analysis.
public struct AnalysisEvent: Sendable, Equatable {
    public let kind: String
    /// The local (logical) day the event STARTED on.
    public let day: String
    /// Local start time as fractional hours, 0 ..< 24.
    public let startHour: Double
    public let durationMin: Double?
    /// A category from a vocabulary the app owns (for workouts: the normalised sport).
    public let category: String?
    /// The app's effort figure for the event, when it has one.
    public let intensity: Double?

    public init(kind: String, day: String, startHour: Double, durationMin: Double? = nil,
                category: String? = nil, intensity: Double? = nil) {
        self.kind = kind
        self.day = day
        self.startHour = startHour
        self.durationMin = durationMin
        self.category = category
        self.intensity = intensity
    }
}

/// A yes/no fact about a day, such as a journal behaviour. `answered` is every day the question was
/// answered at all; `yes` is the subset answered yes. A day outside `answered` is unknown, not "no".
public struct DayTag: Sendable, Equatable {
    public let key: String
    public var answered: Set<String>
    public var yes: Set<String>

    public init(key: String, answered: Set<String>, yes: Set<String>) {
        self.key = key
        self.answered = answered.union(yes)
        self.yes = yes
    }
}

/// Everything an analysis may read, assembled by the app from the stores the wearer granted. The executor
/// never reaches past it.
public struct AnalysisDataset: Sendable {
    /// The logical today, `yyyy-MM-dd`. Windows count back from it.
    public let today: String
    public var series: [String: DailySeries]
    public var events: [AnalysisEvent]
    public var tags: [String: DayTag]
    /// Series and tag keys worth checking as confounders when two groups of days are compared (for
    /// example strain, sleep duration, alcohol). Missing keys are ignored.
    public var confounderKeys: [String]

    public init(today: String, series: [DailySeries], events: [AnalysisEvent] = [], tags: [DayTag] = [],
                confounderKeys: [String] = []) {
        self.today = today
        self.series = Dictionary(series.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        self.events = events
        self.tags = Dictionary(tags.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        self.confounderKeys = confounderKeys
    }

    /// Distinct event kinds present, for validation messages.
    var eventKinds: Set<String> { Set(events.map(\.kind)) }

    /// Distinct categories per event kind, for validation messages.
    func categories(of kind: String) -> Set<String> {
        Set(events.filter { $0.kind == kind }.compactMap(\.category))
    }
}
