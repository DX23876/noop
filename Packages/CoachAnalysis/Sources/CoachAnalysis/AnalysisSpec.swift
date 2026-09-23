import Foundation

/// What the model asks for: one analysis over the wearer's local data. The operations are a closed set so
/// the model chooses WHAT to compute and the app decides HOW — the statistics are built and tested once
/// instead of being re-invented, differently, by every model on every question.
public struct AnalysisSpec: Codable, Equatable, Sendable {

    public enum Operation: String, Codable, CaseIterable, Sendable {
        /// Level and spread of one metric.
        case describe
        /// Is it rising or falling, and how fast.
        case trend
        /// One stretch of days against another.
        case comparePeriods = "compare_periods"
        /// Days meeting one condition against days meeting another (or not the first).
        case compareGroups = "compare_groups"
        /// Two metrics moving together, optionally with the second lagged.
        case correlate
        /// How a metric departs from normal in the days after an event.
        case eventResponse = "event_response"
        /// The highest or lowest days.
        case rankDays = "rank_days"
    }

    /// Which day's value a metric contributes for an anchor day D.
    public enum Align: String, Codable, CaseIterable, Sendable {
        /// Daily series: day D.
        case sameDay = "same_day"
        /// Daily series: day D + 1.
        case nextDay = "next_day"
        /// Nightly series: the night that ENDED on the morning of D (keyed D).
        case nightBefore = "night_before"
        /// Nightly series: the night that STARTED on the evening of D (keyed D + 1).
        case nightAfter = "night_after"
    }

    public enum Transform: String, Codable, CaseIterable, Sendable {
        case none
        /// Trailing 7-day mean ending on the day (needs 4 of the 7 days).
        case rollingMean7 = "rolling_mean_7"
        /// The value minus the median of the preceding 28 days (needs 14 of them): the wearer's own
        /// baseline, which is what makes values comparable across a long history.
        case deltaFromBaseline = "delta_from_baseline"
    }

    public struct MetricRef: Codable, Equatable, Sendable {
        public var series: String
        public var align: Align?
        public var transform: Transform?

        public init(series: String, align: Align? = nil, transform: Transform? = nil) {
            self.series = series
            self.align = align
            self.transform = transform
        }
    }

    public struct EventFilter: Codable, Equatable, Sendable {
        public var kind: String
        public var categories: [String]?
        public var startHourGte: Double?
        public var startHourLt: Double?
        public var minDurationMin: Double?
        public var minIntensity: Double?

        public init(kind: String, categories: [String]? = nil, startHourGte: Double? = nil,
                    startHourLt: Double? = nil, minDurationMin: Double? = nil, minIntensity: Double? = nil) {
            self.kind = kind
            self.categories = categories
            self.startHourGte = startHourGte
            self.startHourLt = startHourLt
            self.minDurationMin = minDurationMin
            self.minIntensity = minIntensity
        }
    }

    public struct Threshold: Codable, Equatable, Sendable {
        public var series: String
        public var gte: Double?
        public var lt: Double?

        public init(series: String, gte: Double? = nil, lt: Double? = nil) {
            self.series = series
            self.gte = gte
            self.lt = lt
        }
    }

    /// A condition on an anchor day. Every field given must hold.
    public struct Condition: Codable, Equatable, Sendable {
        /// ISO weekdays, 1 = Monday … 7 = Sunday.
        public var weekdays: [Int]?
        /// A tag key; with `tagValue` false it selects days answered NO. Days never answered never match.
        public var tag: String?
        public var tagValue: Bool?
        /// At least one matching event on the day.
        public var event: EventFilter?
        /// No matching event on the day.
        public var noEvent: EventFilter?
        /// The day's own value of a series lies in [gte, lt).
        public var threshold: Threshold?

        public init(weekdays: [Int]? = nil, tag: String? = nil, tagValue: Bool? = nil, event: EventFilter? = nil,
                    noEvent: EventFilter? = nil, threshold: Threshold? = nil) {
            self.weekdays = weekdays
            self.tag = tag
            self.tagValue = tagValue
            self.event = event
            self.noEvent = noEvent
            self.threshold = threshold
        }
    }

    public struct Group: Codable, Equatable, Sendable {
        public var label: String
        public var when: Condition

        public init(label: String, when: Condition) {
            self.label = label
            self.when = when
        }
    }

    /// Days ago are counted back from today: 0 is today, 6 is a week ago. Both ends inclusive.
    public struct Period: Codable, Equatable, Sendable {
        public var label: String?
        public var fromDaysAgo: Int
        public var toDaysAgo: Int

        public init(label: String? = nil, fromDaysAgo: Int, toDaysAgo: Int) {
            self.label = label
            self.fromDaysAgo = fromDaysAgo
            self.toDaysAgo = toDaysAgo
        }
    }

    public enum RankOrder: String, Codable, Sendable { case highest, lowest }

    public var operation: Operation
    public var windowDays: Int
    public var metric: MetricRef?
    /// The second metric of `correlate`.
    public var metric2: MetricRef?
    /// `correlate`: metric2 is read `lagDays` after metric (0 … 3).
    public var lagDays: Int?
    /// `compare_groups`: one or two groups; a single group is compared against every other day.
    public var groups: [Group]?
    /// `compare_periods`: exactly two, the first normally the more recent.
    public var periods: [Period]?
    /// `event_response`: the events whose aftermath is measured.
    public var event: EventFilter?
    /// `event_response`: how many days after the event to follow (1 … 3).
    public var responseDays: Int?
    /// Restricts every day considered, before anything else.
    public var filter: Condition?
    /// `rank_days`.
    public var order: RankOrder?
    public var limit: Int?

    public init(operation: Operation, windowDays: Int, metric: MetricRef? = nil, metric2: MetricRef? = nil,
                lagDays: Int? = nil, groups: [Group]? = nil, periods: [Period]? = nil, event: EventFilter? = nil,
                responseDays: Int? = nil, filter: Condition? = nil, order: RankOrder? = nil, limit: Int? = nil) {
        self.operation = operation
        self.windowDays = windowDays
        self.metric = metric
        self.metric2 = metric2
        self.lagDays = lagDays
        self.groups = groups
        self.periods = periods
        self.event = event
        self.responseDays = responseDays
        self.filter = filter
        self.order = order
        self.limit = limit
    }

    /// Decodes the `spec` object of a tool call. Keys are snake_case on the wire. A decoding failure is
    /// returned as a message the model can act on, not a Swift error description.
    public static func decode(toolInput spec: Any) -> Result<AnalysisSpec, AnalysisIssue> {
        guard JSONSerialization.isValidJSONObject(spec),
              let data = try? JSONSerialization.data(withJSONObject: spec) else {
            return .failure(.init(field: "spec", message: "spec must be a JSON object"))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return .success(try decoder.decode(AnalysisSpec.self, from: data))
        } catch let DecodingError.keyNotFound(key, context) {
            return .failure(.init(field: path(context.codingPath + [key]), message: "is required"))
        } catch let DecodingError.typeMismatch(_, context) {
            return .failure(.init(field: path(context.codingPath), message: "has the wrong type"))
        } catch let DecodingError.dataCorrupted(context) {
            let allowed = allowedValues(for: context.codingPath.last?.stringValue)
            return .failure(.init(field: path(context.codingPath),
                                  message: allowed.map { "must be one of: \($0)" } ?? "is not valid"))
        } catch {
            return .failure(.init(field: "spec", message: "could not be read"))
        }
    }

    private static func path(_ keys: [CodingKey]) -> String {
        let parts = keys.map { key -> String in
            if let index = key.intValue { return "[\(index)]" }
            // Report the wire (snake_case) name the model wrote.
            return key.stringValue.reduce(into: "") { out, ch in
                if ch.isUppercase { out += "_" + ch.lowercased() } else { out.append(ch) }
            }
        }
        return parts.reduce("spec") { $1.hasPrefix("[") ? $0 + $1 : $0 + "." + $1 }
    }

    private static func allowedValues(for key: String?) -> String? {
        switch key {
        case "operation": return Operation.allCases.map(\.rawValue).joined(separator: ", ")
        case "align": return Align.allCases.map(\.rawValue).joined(separator: ", ")
        case "transform": return Transform.allCases.map(\.rawValue).joined(separator: ", ")
        case "order": return "highest, lowest"
        default: return nil
        }
    }
}

/// One thing wrong with a spec, phrased so the model can fix it on its next attempt.
public struct AnalysisIssue: Error, Equatable, Sendable, CustomStringConvertible {
    public let field: String
    public let message: String

    public init(field: String, message: String) {
        self.field = field
        self.message = message
    }

    public var description: String { "\(field) \(message)" }
}
