import Foundation
import WhoopStore

// MARK: - How much training stimulus each muscle actually took
//
// Counting working sets treats every set as one set. Three sets of ten at 20 kg then count the same as
// three sets at the edge of what you can lift — and for someone who benches 100 kg the first is close
// to nothing, while for someone who benches 25 kg it is a hard day. A map coloured by set count says
// "trained = orange" and little else.
//
// This estimates the STIMULUS instead, from what the log already carries: how heavy the set was
// relative to that person's own strength at the time, and how close to failure it was taken.
//
// ## This is an estimate, and the numbers below are chosen anchors
//
// The thresholds here (30 % and 70 % of one-rep max, the RPE ramp, half credit for indirect work) are
// conventions taken from how training volume is usually counted. They are NOT measurements, and no
// claim is made that a given number of stimulus units means anything physiological. What they buy is a
// figure that separates a warmup-weight set from a hard one, which set counting cannot do at all.
//
// Two consequences the callers must respect:
//
//   • **Nothing downstream may be gated on this.** It does not feed Charge, recovery, illness
//     detection or a coach recommendation. That is the project's rule for derived physiological
//     signals, and this one has had no validation beyond arithmetic.
//   • **Stimulus is never labelled as sets.** Indirect work adds credit, so the totals here are larger
//     than the sets actually performed. Showing both under one heading would make the same word mean
//     two things on one screen.
public enum MuscleStimulus {

    // MARK: - The anchors

    /// Below this share of one-rep max a set contributes no stimulus. The conventional lower bound for
    /// load that drives adaptation; under it the set is essentially a warmup regardless of how it feels.
    public static let minimumRelativeLoad = 0.30
    /// At and above this share, the intensity term is at full weight.
    public static let fullRelativeLoad = 0.70
    /// Applied when a set carries no RPE. Deliberately mid-range rather than 1.0: an unrated set is
    /// unknown, not maximal, and defaulting it to maximal would make a light unrated session look like
    /// a brutal one. Callers report the rated share alongside, so the reader can see how much of the
    /// estimate is resting on this.
    public static let unratedProximity = 0.75
    /// Indirect work counts as half. The usual convention for crediting a secondary muscle — a bench
    /// press is not nothing for the triceps, and it is not a triceps session either.
    public static let secondaryShare = 0.5
    /// How far back the strength reference looks. Long enough to survive a light block, short enough
    /// that a year-old max no longer defines what is heavy today.
    public static let referenceWindowDays = 84

    // MARK: - The two factors

    /// How much the load itself contributes, from the share of one-rep max.
    public static func intensityFactor(relativeLoad r: Double) -> Double {
        guard r > minimumRelativeLoad else { return 0 }
        guard r < fullRelativeLoad else { return 1 }
        return (r - minimumRelativeLoad) / (fullRelativeLoad - minimumRelativeLoad)
    }

    /// How much proximity to failure contributes. RPE 10 is full; the ramp bottoms out at 0.2, because
    /// an easy set is not zero work — it is just not much.
    public static func proximityFactor(rpe: Double?) -> Double {
        guard let rpe else { return unratedProximity }
        if rpe >= 10 { return 1 }
        if rpe <= 5 { return 0.2 }
        // 5 -> 0.3, 10 -> 1.0, straight line between.
        return 0.3 + (rpe - 5) / 5 * 0.7
    }

    // MARK: - Strength reference

    /// The best estimated one-rep max per exercise, as of a moment in time.
    ///
    /// Built once per query and asked per set, because the alternative — recomputing a max for every
    /// set — is quadratic over a history that only grows.
    ///
    /// The reference is deliberately "as of the set", not the all-time best. Using the current max
    /// would make every old set look easier in hindsight than it was, purely because the lifter got
    /// stronger since, and the map's history would quietly re-colour itself after every PR.
    public struct StrengthReference {
        /// templateId -> (timestamp, best e1RM that day), ascending.
        private let points: [String: [(ts: Int, e1rm: Double)]]

        public init(workouts: [HevyWorkout], templates: [String: HevyExerciseTemplate]) {
            var byTemplate: [String: [(ts: Int, e1rm: Double)]] = [:]
            for workout in workouts {
                for exercise in workout.exercises {
                    guard let id = exercise.templateId else { continue }
                    var best: Double?
                    for set in exercise.workingSets {
                        if let e = OneRepMax.forSet(set, template: templates[id]) {
                            best = max(best ?? 0, e)
                        }
                    }
                    if let best {
                        byTemplate[id, default: []].append((workout.startTs, best))
                    }
                }
            }
            points = byTemplate.mapValues { $0.sorted { $0.ts < $1.ts } }
        }

        /// The best estimate in the trailing window ending at `ts`, inclusive.
        public func best(templateId: String, asOf ts: Int) -> Double? {
            guard let series = points[templateId] else { return nil }
            let floor = ts - referenceWindowDays * 86_400
            var best: Double?
            for point in series where point.ts >= floor && point.ts <= ts {
                best = max(best ?? 0, point.e1rm)
            }
            return best
        }
    }

    // MARK: - Per set

    /// One set's stimulus, before it is shared out over muscles.
    ///
    /// When there is no usable strength reference — a plank, a bodyweight pull-up, a machine with its
    /// own scale, an exercise done for the first time — the intensity term cannot be computed and the
    /// set falls back to counting as ONE hard set, still scaled by proximity to failure. Falling back
    /// to the old behaviour is honest; scoring it zero would silently erase whole exercises from the
    /// map, and inventing an intensity would be worse.
    public static func setStimulus(_ set: HevySet,
                                   templateId: String?,
                                   template: HevyExerciseTemplate?,
                                   at ts: Int,
                                   reference: StrengthReference) -> Double {
        guard set.type.countsAsWork else { return 0 }
        let proximity = proximityFactor(rpe: set.rpe)
        guard let templateId,
              let weight = set.weightKg, weight > 0,
              let oneRepMax = reference.best(templateId: templateId, asOf: ts), oneRepMax > 0,
              template.map(\.isWeightAndReps) ?? true else {
            return proximity
        }
        return intensityFactor(relativeLoad: weight / oneRepMax) * proximity
    }

    // MARK: - Per muscle

    /// Stimulus per muscle group over a set of sessions, plus how much of it rested on rated sets.
    ///
    /// `ratedShare` is not decoration: without RPE the proximity term is a constant, so half the model
    /// is inert and the screen has to be able to say so.
    public struct Result: Equatable, Sendable {
        public let byMuscle: [HevyMuscleGroup: Double]
        public let workingSetCount: Int
        public let ratedSetCount: Int

        public var ratedShare: Double {
            workingSetCount > 0 ? Double(ratedSetCount) / Double(workingSetCount) : 0
        }

        public init(byMuscle: [HevyMuscleGroup: Double], workingSetCount: Int, ratedSetCount: Int) {
            self.byMuscle = byMuscle
            self.workingSetCount = workingSetCount
            self.ratedSetCount = ratedSetCount
        }
    }

    /// Spread one workout's sets over the muscles they trained.
    ///
    /// The primary muscle takes the whole stimulus; every secondary muscle takes `secondaryShare` of
    /// it — each one, not a share divided between them. That is what "indirect work counts as half a
    /// set" means, and it is why these totals exceed the sets performed.
    public static func stimulus(for workouts: [HevyWorkout],
                                templates: [String: HevyExerciseTemplate],
                                reference: StrengthReference) -> Result {
        var byMuscle: [HevyMuscleGroup: Double] = [:]
        var sets = 0
        var rated = 0
        for workout in workouts {
            let session = price(workout, templates: templates, reference: reference,
                                tzOffsetSeconds: 0)
            for (group, value) in session.byMuscle { byMuscle[group, default: 0] += value }
            sets += session.workingSetCount
            rated += session.ratedSetCount
        }
        return Result(byMuscle: byMuscle, workingSetCount: sets, ratedSetCount: rated)
    }

    /// ONE session, priced and spread over its muscles.
    ///
    /// The single place the spreading rule is written. `stimulus(for:)` and `SessionStimulusIndex` both
    /// go through it, so the map and the index cannot drift into two different ideas of what a set is
    /// worth — which is exactly how the secondary-muscle double count survived on one side of the line
    /// and not the other.
    static func price(_ workout: HevyWorkout,
                      templates: [String: HevyExerciseTemplate],
                      reference: StrengthReference,
                      tzOffsetSeconds: Int) -> SessionStimulusIndex.Session {
        var byMuscle: [HevyMuscleGroup: Double] = [:]
        var sets = 0
        var rated = 0
        for exercise in workout.exercises {
            let template = exercise.templateId.flatMap { templates[$0] }
            for set in exercise.workingSets {
                sets += 1
                if set.rpe != nil { rated += 1 }
                let value = setStimulus(set, templateId: exercise.templateId, template: template,
                                        at: workout.startTs, reference: reference)
                guard value > 0, let template else { continue }
                byMuscle[template.primaryMuscleGroup, default: 0] += value
                // De-duplicated for the same reason `StrengthSession.summarize` de-duplicates its
                // secondary tally: a template that lists a group twice in `secondary_muscle_groups`
                // would otherwise be credited twice for one set.
                for secondary in Set(template.secondaryMuscleGroups) {
                    byMuscle[secondary, default: 0] += value * secondaryShare
                }
            }
        }
        return SessionStimulusIndex.Session(
            workoutId: workout.id,
            startTs: workout.startTs,
            day: AnalyticsEngine.dayString(workout.startTs, offsetSec: tzOffsetSeconds),
            byMuscle: byMuscle, workingSetCount: sets, ratedSetCount: rated)
    }

    // MARK: - Every session, priced once

    /// The whole history, priced ONE time.
    ///
    /// ## Why this type exists
    ///
    /// Building a `StrengthReference` costs a pass over every set in the history, and pricing the
    /// sessions against it costs another. The Strength screen used to pay both inside loops: the usual
    /// week rebuilt a reference per week (eight of them), and the time-constant fit rebuilt two per
    /// muscle group (twenty groups, so forty) — roughly fifty full passes over the same sessions to
    /// draw one screen, and the whole lot again on every tap of the week stepper.
    ///
    /// Priced once, every question downstream — what is still outstanding right now, what a week held,
    /// what a usual week looks like, which time constant fits the wearer's answers — becomes a sum over
    /// a few hundred small dictionaries, which is what those questions actually are.
    ///
    /// The index is a VIEW OF ONE HISTORY at one timezone offset. It is not a cache with a lifetime:
    /// rebuild it when the sessions change, and never keep one across a data reload.
    public struct SessionStimulusIndex: Sendable {

        /// One priced session.
        public struct Session: Equatable, Sendable {
            public let workoutId: String
            public let startTs: Int
            /// Local day key, at the offset the index was built with.
            public let day: String
            public let byMuscle: [HevyMuscleGroup: Double]
            public let workingSetCount: Int
            public let ratedSetCount: Int

            public init(workoutId: String, startTs: Int, day: String,
                        byMuscle: [HevyMuscleGroup: Double],
                        workingSetCount: Int, ratedSetCount: Int) {
                self.workoutId = workoutId
                self.startTs = startTs
                self.day = day
                self.byMuscle = byMuscle
                self.workingSetCount = workingSetCount
                self.ratedSetCount = ratedSetCount
            }
        }

        /// Ascending by start, so a window is a contiguous run and the last write of a day wins in the
        /// same order every other derivation here uses.
        public let sessions: [Session]

        public init(workouts: [HevyWorkout],
                    templates: [String: HevyExerciseTemplate],
                    tzOffsetSeconds: Int = 0) {
            let reference = StrengthReference(workouts: workouts, templates: templates)
            sessions = workouts
                .map { MuscleStimulus.price($0, templates: templates, reference: reference,
                                            tzOffsetSeconds: tzOffsetSeconds) }
                .sorted { $0.startTs < $1.startTs }
        }

        /// Sum of the sessions `include` accepts. The one aggregation everything else is phrased in.
        public func total(where include: (Session) -> Bool = { _ in true }) -> Result {
            var byMuscle: [HevyMuscleGroup: Double] = [:]
            var sets = 0
            var rated = 0
            for session in sessions where include(session) {
                for (group, value) in session.byMuscle { byMuscle[group, default: 0] += value }
                sets += session.workingSetCount
                rated += session.ratedSetCount
            }
            return Result(byMuscle: byMuscle, workingSetCount: sets, ratedSetCount: rated)
        }

        /// The Monday–Sunday week containing `anchorDay`, cut on the day keys the index already carries.
        public func week(containing anchorDay: String) -> Result {
            guard let monday = WeeklyDigestEngine.mondayOfWeek(containing: anchorDay) else {
                return Result(byMuscle: [:], workingSetCount: 0, ratedSetCount: 0)
            }
            let sunday = WeeklyDigestEngine.addDays(monday, 6)
            return total { $0.day >= monday && $0.day <= sunday }
        }
    }

    /// One calendar week's stimulus, for the week containing `anchorDay`.
    ///
    /// Convenience for a caller with exactly one week to draw. A screen that also wants the usual week,
    /// the outstanding load or a fitted time constant should build a `SessionStimulusIndex` once and ask
    /// it — that is the whole reason the index exists.
    public static func weeklyStimulus(containing anchorDay: String,
                                      workouts: [HevyWorkout],
                                      templates: [String: HevyExerciseTemplate],
                                      tzOffsetSeconds: Int = 0) -> Result {
        SessionStimulusIndex(workouts: workouts, templates: templates,
                             tzOffsetSeconds: tzOffsetSeconds)
            .week(containing: anchorDay)
    }

    // MARK: - What "usual" means for this person

    /// The median weekly stimulus per muscle over the last `weeks` TRAINING weeks — the anchor the map
    /// calls 100 %.
    ///
    /// Weeks with no training are skipped rather than counted as zero. A fortnight of illness is not
    /// evidence about someone's usual volume, and averaging it in would drag the anchor down and then
    /// report the return to normal training as an unusually heavy week.
    ///
    /// Fewer than three training weeks yields nothing: three points is the least that can pretend to be
    /// a typical value, and below that the caller is expected to say it has no reference rather than
    /// draw one.
    public static func typicalWeeklyStimulus(index: SessionStimulusIndex,
                                             endingBefore anchorDay: String,
                                             weeks: Int = 8) -> [HevyMuscleGroup: Double] {
        guard var monday = WeeklyDigestEngine.mondayOfWeek(containing: anchorDay) else { return [:] }
        monday = WeeklyDigestEngine.addDays(monday, -7)

        var byGroup: [HevyMuscleGroup: [Double]] = [:]
        for _ in 0..<max(weeks, 1) {
            let week = index.week(containing: monday)
            if week.workingSetCount > 0 {
                for group in HevyMuscleGroup.allCases {
                    byGroup[group, default: []].append(week.byMuscle[group] ?? 0)
                }
            }
            monday = WeeklyDigestEngine.addDays(monday, -7)
        }

        var out: [HevyMuscleGroup: Double] = [:]
        for (group, values) in byGroup where values.count >= 3 {
            let median = median(values)
            // A group never trained has a median of zero, which is not a reference anyone can be
            // measured against; omit it rather than divide by it.
            if median > 0 { out[group] = median }
        }
        return out
    }

    /// Convenience for a caller with no index. Builds one — a full pass over the history — so prefer
    /// the index form whenever the same screen also asks any other question of the same sessions.
    public static func typicalWeeklyStimulus(_ workouts: [HevyWorkout],
                                             templates: [String: HevyExerciseTemplate],
                                             endingBefore anchorDay: String,
                                             weeks: Int = 8,
                                             tzOffsetSeconds: Int = 0) -> [HevyMuscleGroup: Double] {
        typicalWeeklyStimulus(index: SessionStimulusIndex(workouts: workouts, templates: templates,
                                                          tzOffsetSeconds: tzOffsetSeconds),
                              endingBefore: anchorDay, weeks: weeks)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

// MARK: - How long the load stays around
//
// The stimulus above is estimated from what was logged. How fast it fades is NOT in the log, and it is
// the one number here that has to be assumed rather than measured — which is exactly the assumption
// that turns a training record into somebody's universal model. Fitbod's "94 % recovered" is that
// assumption with a percentage sign on it.
//
// So the assumption is made explicit, kept small, and made CORRECTABLE. The defaults below are the
// conventional 48-to-72-hour range. When the wearer says how a muscle actually feels, those answers —
// not the default — decide the curve for that muscle.
public enum MuscleRecovery {

    /// Rating a person can give a muscle, coarsest useful scale. Four options, because a finer one asks
    /// for a precision nobody has about their own triceps.
    public enum Feeling: Int, Sendable, CaseIterable, Codable {
        case fresh = 0
        case slightlyTired = 1
        case clearlyTired = 2
        case stillWrecked = 3

        /// Where this answer sits on the model's own 0...1 fatigue scale, so the two can be compared.
        var fatigueLevel: Double { Double(rawValue) / 3.0 }
    }

    /// One answer, exactly as given. Deliberately does NOT carry the fatigue the model predicted at the
    /// time: that number depends on the very time constant being fitted, so storing it would bake
    /// today's model into tomorrow's evidence. The prediction is recomputed from the training log for
    /// whichever constant is being tested.
    public struct Observation: Equatable, Sendable {
        public let group: HevyMuscleGroup
        public let ts: Int
        public let feeling: Feeling

        public init(group: HevyMuscleGroup, ts: Int, feeling: Feeling) {
            self.group = group
            self.ts = ts
            self.feeling = feeling
        }
    }

    /// Larger muscles are conventionally given the longer end of the 48-72 hour range. An assumption,
    /// stated as one, and the starting point the wearer's own answers pull away from.
    public static func defaultTauSeconds(for group: HevyMuscleGroup) -> Double {
        switch group {
        case .quadriceps, .hamstrings, .glutes, .lats, .upperBack, .lowerBack, .chest:
            return 72 * 3600
        default:
            return 48 * 3600
        }
    }

    /// Candidate time constants the fit searches, 12 hours to a week.
    static let tauGridSeconds: [Double] = stride(from: 12.0, through: 168.0, by: 6.0).map { $0 * 3600 }

    /// Answers needed before the fit is trusted at all; below it the default dominates.
    public static let observationsForFullTrust = 8

    /// Load still outstanding per muscle, decaying exponentially from each session.
    ///
    /// Sessions are counted from when they STARTED, matching every other date on the screen. A session
    /// in the future contributes nothing rather than a value greater than its own stimulus.
    public static func fatigue(index: MuscleStimulus.SessionStimulusIndex,
                               now: Int,
                               tau: (HevyMuscleGroup) -> Double = defaultTauSeconds)
        -> [HevyMuscleGroup: Double] {
        var out: [HevyMuscleGroup: Double] = [:]
        for session in index.sessions where session.startTs <= now {
            let age = Double(now - session.startTs)
            for (group, value) in session.byMuscle {
                out[group, default: 0] += value * exp(-age / tau(group))
            }
        }
        return out
    }

    /// Convenience for a caller with no index; builds one over the whole history.
    public static func fatigue(workouts: [HevyWorkout],
                               templates: [String: HevyExerciseTemplate],
                               now: Int,
                               tau: (HevyMuscleGroup) -> Double = defaultTauSeconds)
        -> [HevyMuscleGroup: Double] {
        fatigue(index: MuscleStimulus.SessionStimulusIndex(workouts: workouts, templates: templates),
                now: now, tau: tau)
    }

    /// The typical stimulus ONE session puts on a muscle — the yardstick the "right now" view divides
    /// by, so full colour means "about as much as a normal session of yours leaves behind".
    ///
    /// Median over the sessions that actually trained the muscle. Sessions that did not touch it are
    /// not evidence about what a session for it looks like.
    public static func typicalSessionStimulus(index: MuscleStimulus.SessionStimulusIndex)
        -> [HevyMuscleGroup: Double] {
        var byGroup: [HevyMuscleGroup: [Double]] = [:]
        for session in index.sessions {
            for (group, value) in session.byMuscle where value > 0 {
                byGroup[group, default: []].append(value)
            }
        }
        return byGroup.compactMapValues { values in
            let m = MuscleStimulus.median(values)
            return m > 0 ? m : nil
        }
    }

    /// Convenience for a caller with no index; builds one over the whole history.
    public static func typicalSessionStimulus(_ workouts: [HevyWorkout],
                                              templates: [String: HevyExerciseTemplate])
        -> [HevyMuscleGroup: Double] {
        typicalSessionStimulus(index: MuscleStimulus.SessionStimulusIndex(workouts: workouts,
                                                                          templates: templates))
    }

    /// Fit one muscle's time constant to what the wearer said, pulled toward the default.
    ///
    /// A grid search rather than anything cleverer: the search space is one bounded parameter, the
    /// objective is not convex in any useful sense, and a closed form would be false precision on top
    /// of eight subjective ratings.
    ///
    /// The shrinkage matters more than the search. With two answers the fit is almost entirely the
    /// default; only at `observationsForFullTrust` does it become mostly the wearer's. Without that, a
    /// single "still wrecked" typed on a bad evening would redraw the curve — and the whole reason this
    /// feature is honest is that it treats those answers as evidence, not as commands.
    public static func fittedTauSeconds(for group: HevyMuscleGroup,
                                        observations: [Observation],
                                        index: MuscleStimulus.SessionStimulusIndex,
                                        typicalSession: [HevyMuscleGroup: Double]) -> Double {
        let fallback = defaultTauSeconds(for: group)
        let mine = observations.filter { $0.group == group }.sorted { $0.ts < $1.ts }
        guard mine.count >= 2 else { return fallback }

        guard let scale = typicalSession[group], scale > 0 else { return fallback }

        // What each answer is looking back at: the age and size of every session that had touched this
        // muscle by then. The grid search then costs a handful of exponentials per candidate rather
        // than a re-scoring of the history — and the sessions themselves arrive already priced, so
        // fitting twenty muscle groups reads the same index twenty times instead of rebuilding it.
        let sessions: [(ts: Int, load: Double)] = index.sessions.compactMap { session in
            let value = session.byMuscle[group] ?? 0
            return value > 0 ? (session.startTs, value) : nil
        }
        let lookbacks: [(ages: [Double], loads: [Double], target: Double)] = mine.map { observation in
            let past = sessions.filter { $0.ts <= observation.ts }
            return (past.map { Double(observation.ts - $0.ts) },
                    past.map(\.load),
                    observation.feeling.fatigueLevel)
        }

        func error(_ tau: Double) -> Double {
            lookbacks.reduce(0.0) { sum, item in
                var predicted = 0.0
                for (age, load) in zip(item.ages, item.loads) {
                    predicted += load * exp(-age / tau)
                }
                let delta = min(1, predicted / scale) - item.target
                return sum + delta * delta
            }
        }

        // Scored once per candidate. `min(by:)` would call the comparator — and therefore the error
        // function — twice for every step through the grid.
        let best = tauGridSeconds
            .map { (tau: $0, error: error($0)) }
            .min { $0.error < $1.error }?.tau ?? fallback

        // Straight-line shrinkage: no answers means the default, `observationsForFullTrust` answers
        // means the fit, and the trust in between is proportional to how much was actually said.
        let trust = min(1, Double(mine.count) / Double(observationsForFullTrust))
        return fallback + (best - fallback) * trust
    }

    /// Convenience for a caller with no index. Builds one and derives the scale from it — two full
    /// passes over the history, so a screen fitting every muscle group must use the index form instead:
    /// twenty groups through here is forty passes, which is what it used to cost.
    public static func fittedTauSeconds(for group: HevyMuscleGroup,
                                        observations: [Observation],
                                        workouts: [HevyWorkout],
                                        templates: [String: HevyExerciseTemplate]) -> Double {
        let index = MuscleStimulus.SessionStimulusIndex(workouts: workouts, templates: templates)
        return fittedTauSeconds(for: group, observations: observations, index: index,
                                typicalSession: typicalSessionStimulus(index: index))
    }
}
