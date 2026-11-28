import Foundation

// MARK: - One morning advice for every surface
//
// Before phase 2 the morning had three rules for one statement: the Effort target came from Charge alone
// (three fixed bands in app code on each platform), the coach's prompt mapped the readiness level to a
// prescription of its own, and the coach's suggestion chips had their own Charge cut-offs. They could
// disagree: Charge 80 said "plenty of room" while the cardio lane sat well above usual.
//
// `MorningAdvice.resolve` is now the one decision (Training Load plan, §8, Q22 to Q24). Today, the Effort
// target, the Training tab, the coach and the morning notification only show what it says. It needs no
// language model, so it works without a coach key (Q29).

/// The four ways a day can lean (Q4, Q32).
public enum AdviceStance: String, Sendable, Codable, Equatable, CaseIterable {
    /// "Gas geben" / Push.
    case push
    /// "Normal" / Steady.
    case steady
    /// "Locker" / Easy.
    case easy
    /// "Schonen" / Rest.
    case rest
}

/// The rule that decided the advice, so every surface can give the same reason.
public enum AdviceReason: String, Sendable, Codable, Equatable {
    case illness
    case strainedRecovery
    case lowCharge
    case strengthWellAbove
    case cardioWellAbove
    case planned
    case plannedShorter
    case behindGoal
    case steady
    /// No night was measured: the advice reads the week alone and never pushes.
    case noNight
}

/// Whether the advice can be given yet.
public enum AdviceState: String, Sendable, Codable, Equatable {
    /// Last night is not scored yet ("wartet auf die Nacht").
    case waitingForNight
    case ready
    /// A session is already done today: the advice stays, the room left is what changes (Q15).
    case done
}

/// The night behind today's Charge.
public enum AdviceNight: String, Sendable, Codable, Equatable {
    case scored
    /// Not synced or not scored yet.
    case pending
    /// Nothing was measured (the strap was off).
    case missing
}

public struct MorningAdviceInput: Equatable, Sendable {
    public var charge: Double?
    public var night: AdviceNight
    /// The illness signal is raised, the wearer set themselves sick or injured, or a goal is paused for
    /// illness or pain (Q22 rule 1).
    public var unwell: Bool
    public var recovery: RecoveryState
    public var strengthBand: RelativeLoadBand?
    public var cardioBand: RelativeLoadBand?
    /// A session the plan has for today, hard or not.
    public var plannedToday: Bool
    /// This week is behind the goal's minutes (`EnoughWeek.minutesToGo > 0` past the middle of the week).
    public var behindGoal: Bool
    /// Complete food days well under plan during a heavy week (Q38): never push.
    public var ateTooLittle: Bool
    public var trainedToday: Bool

    public init(charge: Double?, night: AdviceNight, unwell: Bool = false, recovery: RecoveryState = .unknown,
                strengthBand: RelativeLoadBand? = nil, cardioBand: RelativeLoadBand? = nil,
                plannedToday: Bool = false, behindGoal: Bool = false, ateTooLittle: Bool = false,
                trainedToday: Bool = false) {
        self.charge = charge; self.night = night; self.unwell = unwell; self.recovery = recovery
        self.strengthBand = strengthBand; self.cardioBand = cardioBand; self.plannedToday = plannedToday
        self.behindGoal = behindGoal; self.ateTooLittle = ateTooLittle; self.trainedToday = trainedToday
    }
}

public struct MorningAdviceReading: Equatable, Sendable {
    public let stance: AdviceStance
    public let reason: AdviceReason
    public let state: AdviceState
    /// A lane held back on its own while the other stays free (rule 4). Nil when the stance holds for both.
    public let limitedLane: TrainingLaneKind?
    /// Today's Effort target on the stored 0 to 100 axis: Charge's band, capped by the advice (Q14).
    public let effortTarget: ClosedRange<Double>?
    /// A short food hint went with the advice (Q38).
    public let ateTooLittle: Bool

    public init(stance: AdviceStance, reason: AdviceReason, state: AdviceState, limitedLane: TrainingLaneKind?,
                effortTarget: ClosedRange<Double>?, ateTooLittle: Bool) {
        self.stance = stance; self.reason = reason; self.state = state; self.limitedLane = limitedLane
        self.effortTarget = effortTarget; self.ateTooLittle = ateTooLittle
    }
}

/// Charge's Effort band, on WHOOP's 0 to 21 day scale: the rule that sat in `CoupledView.optimalStrainRange`
/// and its Kotlin copy, now in the core.
public enum EffortTargetBand {
    public static func forCharge(_ charge: Double?) -> ClosedRange<Int>? {
        guard let r = charge else { return nil }
        switch r {
        case 67...: return 14...18
        case 34..<67: return 10...14
        default: return 4...10
        }
    }

    /// A 0 to 21 band on the stored 0 to 100 axis.
    public static func stored(_ band: ClosedRange<Int>) -> ClosedRange<Double> {
        (Double(band.lowerBound) * 100 / 21)...(Double(band.upperBound) * 100 / 21)
    }
}

public enum MorningAdvice {
    /// Charge below this is a red morning (rule 3).
    public static let lowCharge = 34.0
    /// Charge from this on may push (rule 6).
    public static let highCharge = 67.0

    /// The day's advice. The first rule that applies decides (Q22):
    /// 1. unwell: rest; 2. recovery strained while a lane is well above usual: rest; 3. Charge under 34: easy;
    /// 4. one lane well above usual: easy for that lane, the other stays free; 5. a planned session: steady,
    /// shorter or lighter at a middle Charge; 6. behind the goal with Charge from 67, recovery not strained:
    /// push; 7. otherwise steady. Without a measured night the advice never pushes.
    public static func resolve(_ input: MorningAdviceInput) -> MorningAdviceReading {
        let state: AdviceState = input.trainedToday ? .done : (input.night == .pending ? .waitingForNight : .ready)
        let anyWellAbove = input.strengthBand == .muchHigher || input.cardioBand == .muchHigher
        let chargeKnown = input.night == .scored ? input.charge : nil

        let stance: AdviceStance
        let reason: AdviceReason
        var limited: TrainingLaneKind? = nil
        if input.unwell {
            (stance, reason) = (.rest, .illness)
        } else if input.recovery == .strained && anyWellAbove {
            (stance, reason) = (.rest, .strainedRecovery)
        } else if let c = chargeKnown, c < lowCharge {
            (stance, reason) = (.easy, .lowCharge)
        } else if input.cardioBand == .muchHigher && input.strengthBand != .muchHigher {
            (stance, reason) = (.easy, .cardioWellAbove); limited = .cardio
        } else if input.strengthBand == .muchHigher && input.cardioBand != .muchHigher {
            (stance, reason) = (.easy, .strengthWellAbove); limited = .strength
        } else if anyWellAbove {
            (stance, reason) = (.easy, .cardioWellAbove)
        } else if input.plannedToday {
            if let c = chargeKnown, c < highCharge { (stance, reason) = (.steady, .plannedShorter) }
            else { (stance, reason) = (.steady, .planned) }
        } else if input.behindGoal, let c = chargeKnown, c >= highCharge, input.recovery != .strained,
                  !input.ateTooLittle {
            (stance, reason) = (.push, .behindGoal)
        } else if input.night == .missing {
            (stance, reason) = (.steady, .noNight)
        } else {
            (stance, reason) = (.steady, .steady)
        }
        return MorningAdviceReading(stance: stance, reason: reason, state: state, limitedLane: limited,
                                    effortTarget: effortTarget(stance: stance, charge: chargeKnown),
                                    ateTooLittle: input.ateTooLittle)
    }

    /// Whether a session planned for the advice's day goes against it (Q28): anything above easy on a rest day, a
    /// hard session or an Effort above the target on an easy day. The app marks it and the wearer decides;
    /// nothing is blocked.
    public static func conflicts(_ advice: MorningAdviceReading, hard: Bool, moderate: Bool, targetEffort: Double?) -> Bool {
        switch advice.stance {
        case .rest:
            return hard || moderate || (targetEffort.map { $0 > (advice.effortTarget?.upperBound ?? 48) } ?? false)
        case .easy:
            if hard { return true }
            guard let effort = targetEffort, let upper = advice.effortTarget?.upperBound else { return false }
            return effort > upper
        case .steady, .push:
            return false
        }
    }

    /// Charge's band capped by the advice: rest keeps to the red band, easy to the middle one at most.
    public static func effortTarget(stance: AdviceStance, charge: Double?) -> ClosedRange<Double>? {
        let band = EffortTargetBand.forCharge(charge)
        switch stance {
        case .rest:
            return EffortTargetBand.stored(4...10)
        case .easy:
            guard let band else { return EffortTargetBand.stored(10...14) }
            return EffortTargetBand.stored(band.upperBound > 14 ? 10...14 : band)
        case .steady, .push:
            return band.map(EffortTargetBand.stored)
        }
    }
}

// MARK: - Offers in everyday units

/// One thing the wearer could do today (Q26). The plan's own session always comes first.
public enum TrainingOffer: Equatable, Sendable {
    case planned(title: String)
    /// Minutes of the wearer's own typical session of `sport`.
    case cardio(sport: String, minutes: Int)
    /// Hard sets for a muscle group that still has room.
    case strength(group: String, sets: Int)
    /// No room or a rest day: walk easily or stretch, with no number.
    case easyMovement
    /// No typical session yet: 30 minutes of brisk walking.
    case startWalk(minutes: Int)
}

public enum TrainingOffers {
    public static let roundingMinutes = 5
    public static let minimumMinutes = 10
    public static let startWalkMinutes = 30
    public static let maximumOffers = 3

    /// The wearer's typical cardio, as the room is converted: the sport's median load per minute.
    public struct Typical: Equatable, Sendable {
        public let sport: String
        public let loadPerMinute: Double
        public init(sport: String, loadPerMinute: Double) { self.sport = sport; self.loadPerMinute = loadPerMinute }
    }

    /// Minutes of `typical` that fit into `room` load units, rounded down to five, nil under ten.
    public static func minutes(room: Double, typical: Typical) -> Int? {
        guard room.isFinite, room > 0, typical.loadPerMinute > 0 else { return nil }
        let raw = Int(room / typical.loadPerMinute)
        let rounded = raw / roundingMinutes * roundingMinutes
        return rounded >= minimumMinutes ? rounded : nil
    }

    /// The day's offers: the planned session first, then cardio and strength sized to the room left, at
    /// most three. A rest day offers easy movement only; a lane held back offers nothing of its own.
    public static func build(advice: MorningAdviceReading, plannedTitle: String?, cardioRoom: Double?,
                             typical: Typical?, strengthGroups: [(group: String, sets: Int)]) -> [TrainingOffer] {
        var out: [TrainingOffer] = []
        if let plannedTitle { out.append(.planned(title: plannedTitle)) }
        if advice.stance == .rest {
            out.append(.easyMovement)
            return Array(out.prefix(maximumOffers))
        }
        let cardioFree = advice.limitedLane != .cardio && !(advice.stance == .easy && advice.limitedLane == nil)
        if cardioFree {
            if let typical {
                if let room = cardioRoom, let m = minutes(room: room, typical: typical) {
                    out.append(.cardio(sport: typical.sport, minutes: m))
                }
            } else {
                out.append(.startWalk(minutes: startWalkMinutes))
            }
        }
        if advice.limitedLane != .strength && !(advice.stance == .easy && advice.limitedLane == nil),
           let best = strengthGroups.filter({ $0.sets > 0 }).max(by: { $0.sets < $1.sets }) {
            out.append(.strength(group: best.group, sets: best.sets))
        }
        if !out.contains(where: { if case .planned = $0 { return false }; return true }) {
            out.append(.easyMovement)
        }
        return Array(out.prefix(maximumOffers))
    }
}
