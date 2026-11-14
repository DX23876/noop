import Foundation

/// One run of a plan's block: when it started, when it stopped, and the block as it stood that day.
///
/// Only facts are kept. Nothing derived from the run lives here, because a stored summary is a second
/// readout of the workout log and the two would eventually disagree. `BlockReport` computes the
/// figures from the log whenever they are shown.
public struct TrainingBlockRun: Identifiable, Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, CaseIterable, Sendable {
        /// Still being followed.
        case running
        /// Reached its last week.
        case finished
        /// The plan was stood down before the last week.
        case abandoned
    }

    public let id: UUID
    public let programId: UUID
    /// Local day keys, `yyyy-MM-dd`.
    public var startedOn: String
    public var endedOn: String?
    public var weeks: Int
    public var deloadInFinalWeek: Bool
    public var deloadEveryWeeks: Int?
    public var deloadFactor: Double
    public var progression: BlockProgressionPolicy
    public var outcome: Outcome

    public init(id: UUID = UUID(), programId: UUID, startedOn: String, endedOn: String? = nil,
                weeks: Int, deloadInFinalWeek: Bool = true, deloadEveryWeeks: Int? = nil,
                deloadFactor: Double = 0.9, progression: BlockProgressionPolicy = .none,
                outcome: Outcome = .running) {
        self.id = id
        self.programId = programId
        self.startedOn = startedOn
        self.endedOn = endedOn
        self.weeks = weeks
        self.deloadInFinalWeek = deloadInFinalWeek
        self.deloadEveryWeeks = deloadEveryWeeks
        self.deloadFactor = deloadFactor
        self.progression = progression
        self.outcome = outcome
    }
}

/// Where a plan stands in its block: the one answer to "which week is this, and is it a lighter one".
///
/// Every surface asks this resolver and none counts weeks itself, and the day it counts against is
/// passed in rather than read here. That is what stops two places on one screen from landing a tick
/// apart, which is how a countdown and its date stamp came to disagree once before.
public enum TrainingBlockState {

    public struct State: Equatable, Sendable {
        /// The week being trained, counted from one. Zero when the block has no start day yet.
        public let week: Int
        public let weeks: Int
        /// Whether this week's prescriptions are damped.
        public let isDeload: Bool
        /// Whether the last week is behind the wearer.
        public let isFinished: Bool
        /// The share of the load this week keeps, 1 outside a lighter week.
        public let loadFactor: Double

        public var weeksRemaining: Int { isFinished ? 0 : max(0, weeks - week + 1) }

        public init(week: Int, weeks: Int, isDeload: Bool, isFinished: Bool, loadFactor: Double) {
            self.week = week
            self.weeks = weeks
            self.isDeload = isDeload
            self.isFinished = isFinished
            self.loadFactor = loadFactor
        }
    }

    /// Nil when the plan has no block, or has one that has not started because the plan is resting.
    /// A caller that gets nil says nothing about weeks, which is the honest answer rather than
    /// "week 1 of 8" for a plan nobody is following.
    public static func resolve(block: TrainingProgramBlock?, today: String) -> State? {
        guard let block, let startedOn = block.startedOn,
              let elapsed = dayDifference(from: startedOn, to: today) else { return nil }
        // A day before the start reads as the first week: a plan activated with tomorrow's key, or a
        // device whose clock stepped back, should not report a week zero or a negative one.
        let week = max(1, elapsed / 7 + 1)
        let isFinished = week > block.weeks
        let deload = !isFinished && isDeloadWeek(week, block: block)
        return State(week: min(week, block.weeks + 1), weeks: block.weeks, isDeload: deload,
                     isFinished: isFinished, loadFactor: deload ? block.deloadFactor : 1)
    }

    /// Whether a given week of a block is a lighter one. Public so a screen naming the NEXT lighter
    /// week reads it from the same rule the state itself uses rather than counting again.
    public static func isDeloadWeek(_ week: Int, block: TrainingProgramBlock) -> Bool {
        if block.deloadInFinalWeek, week == block.weeks { return true }
        if let every = block.deloadEveryWeeks, week % every == 0 { return true }
        return false
    }

    /// Whole days between two local day keys, or nil when either is not a day key. Counted on a fixed
    /// calendar in UTC so that a clock change in between cannot add or drop a day.
    public static func dayDifference(from: String, to: String) -> Int? {
        guard let start = date(from), let end = date(to) else { return nil }
        return Int((end.timeIntervalSince(start) / 86_400).rounded())
    }

    static func date(_ key: String) -> Date? { formatter.date(from: key) }

    static func dayKey(_ date: Date) -> String { formatter.string(from: date) }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
