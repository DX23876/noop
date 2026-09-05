import Foundation
import WhoopStore

// MARK: - How different kinds of session sit with the next morning
//
// "Do leg days cost me more than push days?" is the question a lifter with a strap actually has, and
// it is answerable — but only as a statistical statement about this one person, with an effect size,
// a p-value and an honest count behind it.
//
// NO NEW STATISTICS ARE INVENTED HERE. `EffectRanker` already does exactly this shape of work for
// journal behaviours: it searches a small fixed lag set (same day, next morning, two mornings later),
// runs Welch's t-test through `BehaviorInsights`, reports Cohen's d, and attaches a `ScoreConfidence`
// from the smaller group's size. All this file does is turn sessions into the two things that engine
// takes — a set of behaviour days and a set of CONTROL days — and it is the second one that decides
// whether the answer means anything.
//
// ## The control group is the whole design
//
// The obvious control for "leg day" is "every other day". It is also wrong. Most other days are REST
// days, so that comparison measures training against not training, and hands the entire cost of having
// trained at all to the legs. A −13 Charge would be mostly "you went to the gym".
//
// The control here is therefore the user's OTHER TRAINING DAYS. That is a harder comparison, it needs
// more data before it says anything, and it is the only one whose answer is about legs.

/// What a session mostly trained, decided by where its working sets landed.
public enum StrengthSessionKind: String, Sendable, CaseIterable {
    case legs
    case upper
    /// Neither half took a clear majority — a full-body day. Counted as a training day for the CONTROL
    /// group, but never as evidence about legs or upper: attributing a mixed session to one of them is
    /// how a category quietly stops meaning what its label says.
    case mixed

    public var label: String {
        switch self {
        case .legs:  return "Legs"
        case .upper: return "Upper body"
        case .mixed: return "Full body"
        }
    }
}

public enum StrengthRecoveryResponse {

    /// Muscles that make a session a leg session.
    static let legGroups: Set<HevyMuscleGroup> = [.quadriceps, .hamstrings, .glutes, .calves,
                                                  .abductors, .adductors]
    /// Muscles that make it an upper-body session. Push and pull are ONE group here: splitting them
    /// halves both sample sizes, and with `minGroupForSignificance` at 5 that is usually the difference
    /// between an answer and "not enough data yet".
    static let upperGroups: Set<HevyMuscleGroup> = [.chest, .shoulders, .triceps, .lats,
                                                    .upperBack, .traps, .biceps]

    /// The share of working sets one half must hold for the session to count as that kind.
    static let majorityShare = 0.5

    /// Classify one session.
    public static func classify(_ workout: HevyWorkout,
                                templates: [String: HevyExerciseTemplate]) -> StrengthSessionKind {
        let summary = StrengthSession.summarize(workout, templates: templates)
        let attributed = summary.hardSetsByMuscle.values.reduce(0, +)
        guard attributed > 0 else { return .mixed }
        let legs = summary.hardSetsByMuscle
            .filter { legGroups.contains($0.key) }.values.reduce(0, +)
        let upper = summary.hardSetsByMuscle
            .filter { upperGroups.contains($0.key) }.values.reduce(0, +)
        if Double(legs) / Double(attributed) > majorityShare { return .legs }
        if Double(upper) / Double(attributed) > majorityShare { return .upper }
        return .mixed
    }

    /// One kind's measured relationship with one outcome, or the reason there isn't one yet.
    public struct Response: Equatable, Sendable {
        public let kind: StrengthSessionKind
        public let outcome: String
        /// The effect at its best lag, when the group gate cleared. Nil means not enough yet.
        public let effect: RankedEffect?
        /// Sessions of this kind in the window, and how many more are needed. Reported even on success,
        /// because "measured over 6 sessions" and "measured over 30" are different claims.
        public let sessionCount: Int
        public let controlCount: Int
        public let neededPerGroup: Int

        public var isReady: Bool { effect != nil }
        /// How many more sessions of this kind are needed before anything can be said.
        public var missingSessions: Int { max(0, neededPerGroup - sessionCount) }
        /// How many more OTHER training days are needed — the control side, which is the half people
        /// do not expect to be short.
        public var missingControls: Int { max(0, neededPerGroup - controlCount) }

        public init(kind: StrengthSessionKind, outcome: String, effect: RankedEffect?,
                    sessionCount: Int, controlCount: Int, neededPerGroup: Int) {
            self.kind = kind
            self.outcome = outcome
            self.effect = effect
            self.sessionCount = sessionCount
            self.controlCount = controlCount
            self.neededPerGroup = neededPerGroup
        }
    }

    /// Measure one session kind against one outcome series.
    ///
    /// `outcomeByDay` is any daily series — Charge, HRV, sleep need. The engine shifts it by the lag
    /// itself, so the caller passes it unshifted.
    public static func response(kind: StrengthSessionKind,
                                outcome: String,
                                workouts: [HevyWorkout],
                                templates: [String: HevyExerciseTemplate],
                                outcomeByDay: [String: Double],
                                tzOffsetSeconds: Int = 0) -> Response {
        let classified = Dictionary(grouping: workouts) { classify($0, templates: templates) }
        let dayKeys: (StrengthSessionKind) -> Set<String> = { k in
            StrengthSession.dayKeys(classified[k] ?? [], tzOffsetSeconds: tzOffsetSeconds)
        }

        let behaviourDays = dayKeys(kind)
        // THE control: every other training day, mixed sessions included. Never rest days — see the
        // note at the top of this file. A day that held both kinds belongs to neither side and is
        // removed from the control too, or the same morning would sit on both sides of the comparison.
        var controlDays = Set<String>()
        for other in StrengthSessionKind.allCases where other != kind {
            controlDays.formUnion(dayKeys(other))
        }
        controlDays.subtract(behaviourDays)

        let ranked = EffectRanker.bestLag(behaviorDays: behaviourDays,
                                          controlDays: controlDays,
                                          outcomeByDay: outcomeByDay,
                                          behavior: kind.label,
                                          outcome: outcome)
        return Response(kind: kind, outcome: outcome, effect: ranked,
                        sessionCount: behaviourDays.count,
                        controlCount: controlDays.count,
                        neededPerGroup: BehaviorInsights.minGroupForSignificance)
    }

    /// The comparison sentence the two cards sit under, or nil.
    ///
    /// Deliberately hard to produce. It needs BOTH kinds to have cleared the gate, the two effects to
    /// point the same way, and the gap between them to be more than a rounding difference. A headline
    /// that appears whenever two numbers differ at all would be a coin toss with a confident voice.
    ///
    /// The wording says "goes with", never "causes": these are paired observations, not an experiment,
    /// and the user chose which day to train legs.
    public static func comparison(legs: Response, upper: Response,
                                  minimumGap: Double = 3) -> String? {
        guard let legEffect = legs.effect?.effect, let upperEffect = upper.effect?.effect else {
            return nil
        }
        let legDelta = legEffect.delta
        let upperDelta = upperEffect.delta
        guard legDelta < 0, upperDelta < 0 else { return nil }
        guard abs(legDelta - upperDelta) >= minimumGap else { return nil }
        let heavier = legDelta < upperDelta ? StrengthSessionKind.legs : .upper
        let lighter = heavier == .legs ? StrengthSessionKind.upper : .legs
        return "\(heavier.label) sessions go with a bigger next-day drop than \(lighter.label.lowercased()) ones, on your own record."
    }
}
