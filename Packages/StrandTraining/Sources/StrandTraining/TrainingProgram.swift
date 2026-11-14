import Foundation

/// What a plan is for. The kind decides what may run beside what: a wearer follows at most one
/// strength plan at a time, and may pair it with at most one plan of another kind.
public enum TrainingProgramKind: String, Codable, CaseIterable, Sendable {
    case strength
    case conditioning
    case mobility
}

/// What a plan asks of a week, beyond which routine falls on which day. These belong to the plan:
/// they arrive when it is activated and leave with it, so nothing survives a plan the wearer drops.
public struct TrainingProgramTargets: Codable, Equatable, Sendable {
    public var sessionsPerWeek: Int?
    public var cardioMinutesPerWeek: Int?
    /// An effort window for the week's sessions, as the lower and upper bound of the scale in use.
    public var effortLow: Double?
    public var effortHigh: Double?

    public var isEmpty: Bool {
        sessionsPerWeek == nil && cardioMinutesPerWeek == nil && effortLow == nil && effortHigh == nil
    }

    public init(sessionsPerWeek: Int? = nil, cardioMinutesPerWeek: Int? = nil,
                effortLow: Double? = nil, effortHigh: Double? = nil) {
        self.sessionsPerWeek = sessionsPerWeek.map { max(0, $0) }
        self.cardioMinutesPerWeek = cardioMinutesPerWeek.map { max(0, $0) }
        // A window with its bounds the wrong way round is a typing slip, not a window; order them.
        let bounds = [effortLow, effortHigh].compactMap { $0 }.sorted()
        self.effortLow = bounds.count == 2 ? bounds[0] : effortLow ?? effortHigh
        self.effortHigh = bounds.count == 2 ? bounds[1] : nil
    }
}

/// Where a plan came from. Flat on purpose: it is one stored column, and a published programme has
/// to carry its source wherever the plan travels, including through an export file.
public struct TrainingProgramOrigin: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Built by the wearer, routine by routine.
        case own
        /// Composed by `PlanBuilder` from the wearer's answers.
        case builder
        /// A named published programme, reproduced with its source named.
        case published
        /// Brought in from another app's file or account.
        case imported
    }

    public let kind: Kind
    /// The programme's or source's name, for `published` and `imported`.
    public var name: String?
    /// Who the work belongs to, shown wherever the plan is. Only `published` carries one.
    public var attribution: String?

    public static let own = TrainingProgramOrigin(kind: .own)
    public static let builder = TrainingProgramOrigin(kind: .builder)

    public init(kind: Kind, name: String? = nil, attribution: String? = nil) {
        self.kind = kind
        self.name = name
        self.attribution = attribution
    }
}

/// How a plan's prescriptions move from week to week inside a block.
///
/// This is deliberately exclusive with the per-exercise `ProgressionConfiguration`: two mechanisms
/// writing the same target weight is the shape that produces two readouts which disagree. A routine
/// under a block policy keeps `ProgressionEngine` only for missed sets and its deload.
public enum BlockProgressionPolicy: String, Codable, CaseIterable, Sendable {
    /// Nothing is added by the week. Prescriptions move only as `ProgressionEngine` earns it from
    /// what was actually logged, which is how every plan behaved before blocks existed.
    case none
    /// Each week of the block adds one weight step to the working sets of loaded movements.
    case weeklyLoad
    /// Each week of the block adds one working set, up to a ceiling.
    case weeklyVolume
}

/// A plan with a run time: so many weeks, with a lighter week in it, and an end that reports itself.
///
/// A plan without a block simply runs on, which is what every existing plan does.
public struct TrainingProgramBlock: Codable, Equatable, Sendable {
    public var weeks: Int
    /// A lighter final week. The common shape, and the default.
    public var deloadInFinalWeek: Bool
    /// A lighter week at a fixed interval, counted from the first week. Nil means none.
    public var deloadEveryWeeks: Int?
    /// What a lighter week does to the prescription: the share of the load that is kept.
    public var deloadFactor: Double
    public var progression: BlockProgressionPolicy
    /// The local day the block started, which is the day the plan was activated. Nil until then.
    public var startedOn: String?

    public init(weeks: Int = 8, deloadInFinalWeek: Bool = true, deloadEveryWeeks: Int? = nil,
                deloadFactor: Double = 0.9, progression: BlockProgressionPolicy = .none,
                startedOn: String? = nil) {
        self.weeks = min(52, max(1, weeks))
        self.deloadInFinalWeek = deloadInFinalWeek
        self.deloadEveryWeeks = deloadEveryWeeks.map { max(2, $0) }
        // The same bounds `ProgressionConfiguration` uses for its own deload, for the same reason:
        // below half is a different session, above 0.95 is not a lighter week.
        self.deloadFactor = min(0.95, max(0.5, deloadFactor))
        self.progression = progression
        self.startedOn = startedOn
    }
}

/// One training plan: its routines' schedule, what it asks of a week, and whether it is the plan
/// being followed right now.
///
/// The routines themselves stay in the routine store and name their plan, so a routine is never
/// stored twice. What is active decides what the rest of the app sees: `TrainingPlan` resolves to
/// the active plans only, so a plan the wearer has prepared but not started cannot be begun by
/// accident from Today, the week or the quick start.
public struct TrainingProgram: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var kind: TrainingProgramKind
    public var notes: String?
    public var targets: TrainingProgramTargets
    public var block: TrainingProgramBlock?
    public var schedule: [TrainingWeekday: [UUID]]
    public var isActive: Bool
    public var origin: TrainingProgramOrigin
    public var createdAt: Int
    public var updatedAt: Int

    public init(id: UUID = UUID(), title: String, kind: TrainingProgramKind = .strength,
                notes: String? = nil, targets: TrainingProgramTargets = .init(),
                block: TrainingProgramBlock? = nil,
                schedule: [TrainingWeekday: [UUID]] = [:], isActive: Bool = false,
                origin: TrainingProgramOrigin = .own,
                createdAt: Int = Int(Date().timeIntervalSince1970),
                updatedAt: Int = Int(Date().timeIntervalSince1970)) {
        self.id = id
        self.title = title
        self.kind = kind
        self.notes = notes
        self.targets = targets
        self.block = block
        self.schedule = schedule
        self.isActive = isActive
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Which plans may be active at once, as one tested function rather than a rule repeated at every
/// call site.
///
/// The rule the wearer chose: at most one strength plan, and at most one plan of each other kind
/// beside it. Activating a plan therefore stands down whatever plan of the same kind was active,
/// and nothing else.
public enum TrainingProgramActivation {

    /// The plans as they stand after activating `id`, and the day that activation happened, which a
    /// block counts from.
    ///
    /// Only plans whose state actually changes come back, so a caller writes the fewest rows it can
    /// and an unchanged plan keeps its `updatedAt`.
    public static func activate(_ id: UUID, in programs: [TrainingProgram],
                                day: String, now: Int) -> [TrainingProgram] {
        guard let target = programs.first(where: { $0.id == id }) else { return [] }
        var changed: [TrainingProgram] = []
        for program in programs where program.kind == target.kind {
            let shouldBeActive = program.id == id
            var updated = program
            updated.isActive = shouldBeActive
            // A block counts from the day its plan started, so taking a plan up stamps that day and
            // standing it down clears it: a plan taken up again begins a new block rather than
            // resuming a run it was not doing. Activating a plan that is already active leaves its
            // start alone, or every visit to the button would reset the block to week one.
            if updated.block != nil {
                if shouldBeActive, !program.isActive { updated.block?.startedOn = day }
                if !shouldBeActive { updated.block?.startedOn = nil }
            }
            guard updated != program else { continue }
            updated.updatedAt = now
            changed.append(updated)
        }
        return changed
    }

    /// The plans as they stand after standing `id` down. Empty when it was not active anyway.
    public static func deactivate(_ id: UUID, in programs: [TrainingProgram],
                                  now: Int) -> [TrainingProgram] {
        guard var program = programs.first(where: { $0.id == id }), program.isActive else { return [] }
        program.isActive = false
        if program.block != nil { program.block?.startedOn = nil }
        program.updatedAt = now
        return [program]
    }

    /// The active plan of a kind, which is at most one by construction. Where stored data somehow
    /// holds two, the most recently updated one wins and the other reads as inactive, so a readout
    /// can never show two plans of one kind at once.
    public static func active(_ kind: TrainingProgramKind,
                              in programs: [TrainingProgram]) -> TrainingProgram? {
        programs.filter { $0.isActive && $0.kind == kind }
            .max { ($0.updatedAt, $0.createdAt, $0.id.uuidString)
                 < ($1.updatedAt, $1.createdAt, $1.id.uuidString) }
    }

    /// Every plan that counts as active, one per kind, in a stable order.
    public static func activePlans(in programs: [TrainingProgram]) -> [TrainingProgram] {
        TrainingProgramKind.allCases.compactMap { active($0, in: programs) }
    }
}
