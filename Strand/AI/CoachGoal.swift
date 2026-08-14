import Foundation
import StrandAnalytics

/// The user's training goal, as a REAL goal rather than a sentence.
///
/// The predecessor was a bare `ai.trainingGoal` string pasted into the prompt — the app had no idea
/// that "October" was a date, that a half marathon was 21.1 km, or that it was three months out. This
/// carries the structure the coach needs to actually reason about time and progress: a starting point,
/// a target, a unit, and a deadline.
///
/// Everything here is on-device (JSON in UserDefaults, same posture as `CoachMemory`), and only the
/// parts the coach genuinely needs cross the `dataConsent` boundary. `motivation` is deliberately NOT
/// among them by default — see `shareMotivation`.
struct CoachGoal: Codable, Identifiable, Equatable {

    /// What kind of goal this is. Drives which evidence the feasibility check looks for and which
    /// safety rate (if any) applies. `custom` is the honest escape hatch: a goal NOOP can hold and
    /// frame advice around, but cannot measure.
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case run          // a distance/time running goal, measured in km
        case consistency  // sessions per week
        case sleep        // average nightly hours
        case strength     // strength work — NOOP has no load tracking, so it is held, not measured
        case weight       // body weight — TRACKED only; the coach never plans nutrition (see below)
        case stress       // reduce stress — held, not measured (no target rate to judge)
        case recovery     // recover better — held, not measured
        case custom       // free text; no measurement

        var id: String { rawValue }

        var label: String {
            switch self {
            case .run:         return "Running"
            case .consistency: return "Train regularly"
            case .sleep:       return "Sleep better"
            case .strength:    return "Build strength"
            case .weight:      return "Body weight"
            case .stress:      return "Reduce stress"
            case .recovery:    return "Recover better"
            case .custom:      return "Something else"
            }
        }

        /// A short line under the label on the goal cards — what this goal is, in the user's terms.
        var blurb: String {
            switch self {
            case .run:         return "A distance or time you're building toward."
            case .consistency: return "Show up a set number of times a week."
            case .sleep:       return "More, or steadier, nightly sleep."
            case .strength:    return "Get stronger over time."
            case .weight:      return "Move your body weight toward a target."
            case .stress:      return "Bring your daily load down."
            case .recovery:    return "Give your body more room to bounce back."
            case .custom:      return "Anything else — the coach will hold it."
            }
        }

        /// SF Symbol for the goal cards (8.3 — visual, not a bare dropdown).
        var icon: String {
            switch self {
            case .run:         return "figure.run"
            case .consistency: return "calendar.badge.checkmark"
            case .sleep:       return "bed.double.fill"
            case .strength:    return "dumbbell.fill"
            case .weight:      return "scalemass.fill"
            case .stress:      return "wind"
            case .recovery:    return "heart.fill"
            case .custom:      return "sparkles"
            }
        }

        /// The unit a quantified goal of this kind is measured in. Empty when the kind isn't quantified.
        var unit: String {
            switch self {
            case .run:         return "km"
            case .consistency: return "sessions/week"
            case .sleep:       return "h"
            case .weight:      return "kg"
            // Strength is measured as ACTIVITY TIME (no load tracking exists to claim anything else).
            case .strength:    return "min/week"
            // Derived 0-100 scores: a bare number, deliberately not dressed up as a percentage or a
            // clinical unit.
            case .stress, .recovery, .custom: return ""
            }
        }

        /// True when this kind carries a baseline/target pair worth doing arithmetic on — a progress
        /// fraction, a pace trend, a feasibility verdict and the safety gate all hang off this.
        ///
        /// Explicit rather than the `!unit.isEmpty` it used to be, because those are two different
        /// questions and conflating them is a trap: `strength` now HAS a display unit (min/week, what
        /// the tile shows) and is still deliberately **held, not judged** — the same honest handling
        /// `stress`, `recovery` and `custom` get. NOOP can show you a current number without claiming
        /// it knows what "on track" means for it (`CoachGoalMotivationTests` pins this).
        var isQuantified: Bool {
            switch self {
            case .run, .consistency, .sleep, .weight: return true
            case .strength, .stress, .recovery, .custom: return false
            }
        }
    }

    /// The user's WHY, as a structured pick (8.4) — coarse categories the coach can actually use to
    /// personalise, distinct from the intimate free-text `motivation`. These ride the coach context (they
    /// describe the goal, like `kind`/`target`) rather than being gated behind `shareMotivation`, which
    /// guards only the personal prose.
    enum MotivationTag: String, Codable, CaseIterable, Identifiable {
        case moreEnergy, feelHealthier, lessExhausted, buildRoutine, manageWeight, performBetter

        var id: String { rawValue }

        var label: String {
            switch self {
            case .moreEnergy:    return "More energy"
            case .feelHealthier: return "Feel healthier"
            case .lessExhausted: return "Less exhausted"
            case .buildRoutine:  return "Build a routine"
            case .manageWeight:  return "Manage my weight"
            case .performBetter: return "Perform better day to day"
            }
        }

        var icon: String {
            switch self {
            case .moreEnergy:    return "bolt.fill"
            case .feelHealthier: return "leaf.fill"
            case .lessExhausted: return "battery.75"
            case .buildRoutine:  return "repeat"
            case .manageWeight:  return "scalemass"
            case .performBetter: return "chart.line.uptrend.xyaxis"
            }
        }
    }

    enum Status: String, Codable, CaseIterable {
        case active, paused, achieved, abandoned, archived
    }

    enum PauseReason: String, Codable, CaseIterable, Identifiable {
        case illness, pain, travel, life, other

        var id: String { rawValue }

        var label: String {
            switch self {
            case .illness: return "Illness"
            case .pain:    return "Pain"
            case .travel:  return "Travel"
            case .life:    return "Life got busy"
            case .other:   return "Something else"
            }
        }
    }

    /// A structured pause interval. Unlike the prose history this remains machine-readable after a
    /// resume, which lets flexible goal-week streaks protect the right historical weeks.
    struct PauseInterval: Codable, Equatable {
        let startedAt: Date
        var endedAt: Date?
        let reason: PauseReason

        func intersects(_ interval: DateInterval) -> Bool {
            let end = endedAt ?? .distantFuture
            return startedAt < interval.end && end >= interval.start
        }
    }

    struct Closure: Codable, Equatable {
        enum Kind: String, Codable { case achieved, setAside, replaced }
        let kind: Kind
        let date: Date
        let reason: String?
    }

    /// The user's acknowledgement of a flagged goal rate. The gate WARNS and asks for a reason — it
    /// never blocks. Legitimate exceptions exist (a cut phase, a high starting body weight, medical
    /// supervision), and refusing them outright would be both paternalistic and wrong. Recording the
    /// reason keeps the decision the user's, visible, and revisitable.
    struct RiskAcknowledgement: Codable, Equatable {
        /// The gate verdict at the time of acknowledgement, so a later change of plan is auditable.
        let verdict: String
        /// Why the user is going ahead anyway — a preset or their own words.
        let reason: String
        let date: Date
    }

    /// One entry in the goal's change log, so the coach (and the Journey page) can say what changed
    /// and when, rather than presenting the current state as if it had always been the plan.
    struct Event: Codable, Equatable {
        let date: Date
        let what: String
    }

    let id: UUID
    var kind: Kind
    /// Free-text name — "Half marathon", "5k under 25 min", "Back to 3 sessions a week".
    var title: String
    /// Where the user is starting from, in `unit`. nil when unknown/not applicable.
    var baseline: Double?
    /// Where they want to get to, in `unit`. nil for unquantified goals.
    var target: Double?
    var targetDate: Date?
    var status: Status
    /// Why this matters to them. The most personal line in the app — held locally and NOT sent to any
    /// provider unless `shareMotivation` is explicitly turned on.
    var motivation: String
    /// The user's WHY as structured tags (8.4) — coarse categories the coach uses for personalisation.
    /// Unlike the free-text `motivation`, these describe the goal and ride the context by default (within
    /// the standing `dataConsent` gate), so the coach can act on them without the user opting into
    /// sharing their private prose.
    var motivationTags: [MotivationTag]
    /// Explicit opt-in to include the free-text `motivation` in the coach context. Off by default.
    var shareMotivation: Bool
    var acknowledgedRisk: RiskAcknowledgement?
    let createdAt: Date
    var history: [Event]
    var pauseIntervals: [PauseInterval]
    var closure: Closure?
    /// The route from `baseline` to `target`: round-number waypoints with the date the PLANNED rate
    /// reaches them. Suggested once by `GoalMilestones` and then owned by the user — a waypoint they
    /// edited carries `isCustom` and survives a re-suggest when the target or date changes.
    ///
    /// Waypoints, not rewards: no streak, no score. See `GoalMilestones` for why.
    var milestones: [Milestone]

    /// One waypoint on the route. `achievedAt` is set when the measured value first passes it, so the
    /// list reads as a record of what happened rather than a checklist to keep up.
    struct Milestone: Codable, Equatable, Identifiable {
        var id: UUID = UUID()
        var value: Double
        var expectedDate: Date
        var achievedAt: Date?
        /// True once the user has moved this waypoint. Re-suggesting leaves those alone.
        var isCustom: Bool = false
    }

    init(id: UUID = UUID(),
         kind: Kind = .custom,
         title: String = "",
         baseline: Double? = nil,
         target: Double? = nil,
         targetDate: Date? = nil,
         status: Status = .active,
         motivation: String = "",
         motivationTags: [MotivationTag] = [],
         shareMotivation: Bool = false,
         acknowledgedRisk: RiskAcknowledgement? = nil,
         createdAt: Date = Date(),
         history: [Event] = [],
         pauseIntervals: [PauseInterval] = [],
         closure: Closure? = nil,
         milestones: [Milestone] = []) {
        self.id = id
        self.kind = kind
        self.title = title
        self.baseline = baseline
        self.target = target
        self.targetDate = targetDate
        self.status = status
        self.motivation = motivation
        self.motivationTags = motivationTags
        self.shareMotivation = shareMotivation
        self.acknowledgedRisk = acknowledgedRisk
        self.createdAt = createdAt
        self.history = history
        self.pauseIntervals = pauseIntervals
        self.closure = closure
        self.milestones = milestones
    }

    // Back-compat: every field added after the first ship decodes with a default, so a stored goal
    // never fails to load and silently vanish.
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, baseline, target, targetDate, status
        case motivation, motivationTags, shareMotivation, acknowledgedRisk, createdAt, history
        case pauseIntervals, closure, milestones
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .custom
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        baseline = try c.decodeIfPresent(Double.self, forKey: .baseline)
        target = try c.decodeIfPresent(Double.self, forKey: .target)
        targetDate = try c.decodeIfPresent(Date.self, forKey: .targetDate)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .active
        motivation = try c.decodeIfPresent(String.self, forKey: .motivation) ?? ""
        motivationTags = try c.decodeIfPresent([MotivationTag].self, forKey: .motivationTags) ?? []
        shareMotivation = try c.decodeIfPresent(Bool.self, forKey: .shareMotivation) ?? false
        acknowledgedRisk = try c.decodeIfPresent(RiskAcknowledgement.self, forKey: .acknowledgedRisk)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        history = try c.decodeIfPresent([Event].self, forKey: .history) ?? []
        pauseIntervals = try c.decodeIfPresent([PauseInterval].self, forKey: .pauseIntervals) ?? []
        closure = try c.decodeIfPresent(Closure.self, forKey: .closure)
        // Added after first ship: a goal stored before the route existed decodes with none, and gets
        // one suggested on the next tracking refresh.
        milestones = try c.decodeIfPresent([Milestone].self, forKey: .milestones) ?? []
    }

    // MARK: - Derived

    /// Whole weeks from `now` until the target date, or nil without one. Negative once the date passes,
    /// so the coach can say "that date has passed" rather than silently pretending it hasn't.
    func weeksRemaining(from now: Date = Date()) -> Double? {
        guard let targetDate else { return nil }
        return targetDate.timeIntervalSince(now) / (7 * 24 * 3600)
    }

    /// The signed change still required, in `unit`. nil unless both ends are known.
    func remainingChange() -> Double? {
        guard let baseline, let target else { return nil }
        return target - baseline
    }

    /// A COARSE training-phase label from the weeks left. This is a conventional block shape, not a
    /// prescription and not periodisation science — it exists so the coach knows roughly where in the
    /// runway it is instead of treating week 1 and week 11 identically. Only meaningful for a
    /// performance goal with an event date, so it's nil for everything else.
    func phase(from now: Date = Date()) -> String? {
        guard kind == .run || kind == .strength, let weeks = weeksRemaining(from: now), weeks > 0
        else { return nil }
        switch weeks {
        case ..<2:  return "taper"
        case ..<4:  return "peak"
        case ..<12: return "build"
        default:    return "base"
        }
    }
}

/// Multiple simultaneous goals (#R-multi-goal), persisted on-device: one active goal per `Kind`, up to
/// `maxActiveGoals` active at once — enough for the common combinations (a run goal + a sleep goal + a
/// consistency goal, say) without turning into an unmanageable list.
///
/// Shared instance so the engine (reader) and the settings UI (editor) observe the same state, exactly
/// like `CoachMemory.shared`.
@MainActor
final class CoachGoalStore: ObservableObject {

    static let shared = CoachGoalStore()

    /// Upper bound on simultaneously ACTIVE (active/paused) goals. `CoachGoal.Kind` has 8 cases, so the
    /// one-per-kind rule alone would allow more than this — the real ceiling is this ceiling, not the kind
    /// count, so the limit message should say "N active goals", never imply "one of each kind".
    static let maxActiveGoals = 5

    @Published var goals: [CoachGoal] = [] { didSet { save() } }

    private let d: UserDefaults
    private static let goalsKey = "ai.goals"
    /// The OLD singular-goal key, from before multiple goals existed. Read once for migration into
    /// `goals` as a one-element array, then left alone (never deleted, so downgrading to an older build
    /// still finds its single goal).
    private static let legacySingularGoalKey = "ai.goal"
    /// The even OLDER free-text goal this replaces. Read once for migration, then left alone (never
    /// deleted, so downgrading to an older build doesn't lose the user's sentence).
    static let legacyGoalKey = "ai.trainingGoal"

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        if let data = defaults.data(forKey: Self.goalsKey),
           let decoded = try? JSONDecoder().decode([CoachGoal].self, from: data) {
            self.goals = decoded
        } else if let seeded = Self.migrateSingular(defaults: defaults) {
            self.goals = [seeded]
        } else if let legacy = Self.migrateLegacy(defaults: defaults) {
            self.goals = [legacy]
        } else {
            self.goals = []
        }
    }

    /// One-time migration: a user already on the single-goal model keeps their one goal, seeded as a
    /// one-element array. Takes priority over `migrateLegacy` below — a real structured goal beats the
    /// pre-structured free-text fallback.
    private static func migrateSingular(defaults: UserDefaults) -> CoachGoal? {
        guard let data = defaults.data(forKey: legacySingularGoalKey),
              let decoded = try? JSONDecoder().decode(CoachGoal.self, from: data) else { return nil }
        return decoded
    }

    /// One-time migration: a user who typed "Half marathon in October" into the old free-text field
    /// keeps it, as a `.custom` goal's title. We deliberately do NOT try to parse a date out of the
    /// sentence — guessing wrong would be worse than leaving `targetDate` nil and letting them set it.
    private static func migrateLegacy(defaults: UserDefaults) -> CoachGoal? {
        let legacy = (defaults.string(forKey: legacyGoalKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacy.isEmpty else { return nil }
        return CoachGoal(kind: .custom, title: legacy,
                         history: [.init(date: Date(), what: "Carried over from your previous goal note")])
    }

    // MARK: Lookup

    /// Goals actually in play right now — everything else (achieved/abandoned/archived) is history.
    var activeGoals: [CoachGoal] { goals.filter { $0.status == .active || $0.status == .paused } }

    func goal(id: UUID) -> CoachGoal? { goals.first(where: { $0.id == id }) }

    /// The active goal of this `Kind`, if any — at most one can exist at a time (`canAdd` enforces it).
    func activeGoal(for kind: CoachGoal.Kind) -> CoachGoal? {
        activeGoals.first(where: { $0.kind == kind })
    }

    /// Why a new/edited goal of `kind` can't be added right now, or nil when it's fine. `replacing`
    /// excludes that goal's own id from the checks (editing a goal in place, or deliberately replacing
    /// it, is never blocked by itself).
    enum GoalLimitError: Equatable {
        /// An active goal of the same kind already exists (`existingId`) — the caller should offer to
        /// replace it (see `commit(_:editingId:replacing:...)`) rather than silently stacking a second.
        case kindAlreadyActive(existingId: UUID)
        /// `maxActiveGoals` are already active; nothing more can be added until one closes or is removed.
        case tooManyActive
    }

    func canAdd(kind: CoachGoal.Kind, replacing: UUID? = nil) -> GoalLimitError? {
        let others = activeGoals.filter { $0.id != replacing }
        if let existing = others.first(where: { $0.kind == kind }) {
            return .kindAlreadyActive(existingId: existing.id)
        }
        if others.count >= Self.maxActiveGoals { return .tooManyActive }
        return nil
    }

    /// Record a change on one goal's log. Kept small (most recent 20) — this is a story, not an audit DB.
    func note(_ id: UUID, _ what: String) {
        guard let idx = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[idx].history.append(.init(date: Date(), what: what))
        if goals[idx].history.count > 20 { goals[idx].history.removeFirst(goals[idx].history.count - 20) }
    }

    // MARK: Lifecycle

    /// Close a goal as reached. It STAYS in the store — the Journey page shows the closure and the coach
    /// gets to congratulate — freeing up its `Kind` for a new goal. Only an open goal can be closed.
    func markAchieved(_ id: UUID, on date: Date = Date()) {
        guard let idx = goals.firstIndex(where: { $0.id == id }),
              goals[idx].status == .active || goals[idx].status == .paused else { return }
        closeOpenPause(at: idx, on: date)
        goals[idx].status = .achieved
        goals[idx].closure = .init(kind: .achieved, date: date, reason: nil)
        goals[idx].history.append(.init(date: date, what: "Goal achieved"))
    }

    /// Set a goal aside without shame — injuries, life, changed priorities are all legitimate ends. The
    /// one-tap reason lands in the history so the story stays honest, never as a debt to explain.
    func setAside(_ id: UUID, reason: String, on date: Date = Date()) {
        guard let idx = goals.firstIndex(where: { $0.id == id }),
              goals[idx].status == .active || goals[idx].status == .paused else { return }
        closeOpenPause(at: idx, on: date)
        goals[idx].status = .abandoned
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        goals[idx].closure = .init(kind: .setAside, date: date, reason: why.isEmpty ? nil : why)
        goals[idx].history.append(.init(date: date, what: why.isEmpty ? "Goal set aside" : "Goal set aside — \(why)"))
    }

    /// Pausing protects intersecting goal weeks but deliberately leaves scheduled plan rows untouched.
    /// A goal lifecycle decision must not silently rewrite calendar commitments.
    func pause(_ id: UUID, reason: CoachGoal.PauseReason, on date: Date = Date()) {
        guard let idx = goals.firstIndex(where: { $0.id == id }), goals[idx].status == .active else { return }
        goals[idx].status = .paused
        goals[idx].pauseIntervals.append(.init(startedAt: date, endedAt: nil, reason: reason))
        goals[idx].history.append(.init(date: date, what: "Goal paused — \(reason.label)"))
        trimHistory(at: idx)
    }

    func resume(_ id: UUID, on date: Date = Date()) {
        guard let idx = goals.firstIndex(where: { $0.id == id }), goals[idx].status == .paused else { return }
        closeOpenPause(at: idx, on: date)
        goals[idx].status = .active
        goals[idx].history.append(.init(date: date, what: "Goal resumed"))
        trimHistory(at: idx)
    }

    /// Delete a goal and its history entirely — the only irreversible one. Unlike `setAside`, nothing of
    /// it survives.
    func remove(_ id: UUID) {
        goals.removeAll { $0.id == id }
        // Nothing else can reach this goal's proactive repeat-guards once it is gone, so they would
        // otherwise sit in UserDefaults for the life of the install.
        CoachGoalNudgeStamps.clear(goalId: id, defaults: d)
    }

    /// Commit an edited or freshly-added goal (#R12, extended #R-multi-goal) — the identity-preserving,
    /// history-appending save shared by the one-page editor and the guided onboarding flow, so the two
    /// paths can never drift on how a goal is persisted.
    ///
    /// - `editingId` nil = ADD a brand-new goal (own id + history). Non-nil = edit THAT goal in place,
    ///   preserving its id/history/creation date.
    /// - `replacing` = a DIFFERENT existing goal (of the same `Kind`, already active) that the user chose
    ///   to replace rather than keep — closed out with its own history event ("Replaced by a new goal")
    ///   before the new one is added. Distinct from `editingId`: replacing is conceptually a new pursuit,
    ///   not a continuation, so it always mints a fresh id even though an old goal is being closed.
    /// - `acknowledgedRisk` non-nil records a pace acknowledgement; `clearStaleAck` drops an existing
    ///   acknowledgement when the pace is no longer flagged. When both are nil/false, an edit keeps the
    ///   existing acknowledgement (carried by the identity-preserving copy below).
    func commit(_ draft: CoachGoal, editingId: UUID? = nil, replacing: UUID? = nil,
                acknowledgedRisk: CoachGoal.RiskAcknowledgement? = nil, clearStaleAck: Bool = false) {
        if let replacing, let idx = goals.firstIndex(where: { $0.id == replacing }) {
            let replacedAt = Date()
            closeOpenPause(at: idx, on: replacedAt)
            goals[idx].status = .abandoned
            goals[idx].closure = .init(kind: .replaced, date: replacedAt, reason: nil)
            goals[idx].history.append(.init(date: replacedAt, what: "Replaced by a new goal"))
        }

        var g = draft
        g.status = .active
        if let editingId, let existing = goal(id: editingId) {
            g = CoachGoal(id: existing.id, kind: g.kind, title: g.title,
                          baseline: g.baseline, target: g.target, targetDate: g.targetDate,
                          status: .active, motivation: g.motivation,
                          motivationTags: g.motivationTags,
                          shareMotivation: g.shareMotivation,
                          acknowledgedRisk: existing.acknowledgedRisk,
                          createdAt: existing.createdAt, history: existing.history,
                          pauseIntervals: existing.pauseIntervals, closure: existing.closure,
                          // Carrying the route is not optional. Omitting it took the init default of
                          // `[]`, so every edit silently threw away both halves of what the route is
                          // FOR: the `achievedAt` stamps (a record of what actually happened) and the
                          // `isCustom` waypoints the user moved by hand. `ensureMilestones` then
                          // rebuilt a fresh, unreached route with new identities on the next refresh
                          // — the exact erasure its own doc comment rules out.
                          milestones: existing.milestones)
        }
        if let ack = acknowledgedRisk {
            g.acknowledgedRisk = ack
        } else if clearStaleAck {
            g.acknowledgedRisk = nil
        }
        g.history.append(.init(date: Date(), what: editingId == nil ? "Goal set" : "Goal updated"))
        if g.history.count > 20 { g.history.removeFirst(g.history.count - 20) }

        if let editingId, let idx = goals.firstIndex(where: { $0.id == editingId }) {
            goals[idx] = g
        } else {
            goals.insert(g, at: 0)
        }
    }

    /// Give every quantified, dated goal a route, and keep it in step with the goal without ever
    /// discarding the user's own edits.
    ///
    /// Runs on each tracking refresh and is a no-op in the ordinary case. Two things it deliberately
    /// does NOT do: overwrite a waypoint the user moved (`isCustom`), and forget that a waypoint was
    /// already reached — a route that renumbered itself after a target change would erase the record
    /// of what actually happened.
    func ensureMilestones(now: Date = Date()) {
        for index in goals.indices {
            let goal = goals[index]
            guard goal.status == .active || goal.status == .paused,
                  let baseline = goal.baseline, let target = goal.target,
                  let targetDate = goal.targetDate else { continue }

            let suggested = GoalMilestones.suggest(baseline: baseline, target: target,
                                                   createdAt: goal.createdAt, targetDate: targetDate)
            guard !suggested.isEmpty else { continue }

            // Match EXISTING waypoints by value and reuse them, identity included.
            //
            // This must be idempotent, and the first version was not: it only kept waypoints that were
            // custom or already reached, so an untouched route was rebuilt from scratch on every call
            // — with fresh UUIDs. `Milestone` is Equatable including `id`, so the "did anything
            // change?" guard was always true, which assigned, which fired `didSet`/`@Published`, which
            // re-rendered every observer and re-saved the goals JSON. `refresh()` runs from view
            // `.task`s, so that loop fed itself and the Today tile churned out of existence.
            func key(_ value: Double) -> Double { (value * 1000).rounded() }
            var byValue: [Double: CoachGoal.Milestone] = [:]
            for milestone in goal.milestones { byValue[key(milestone.value)] = milestone }

            var merged: [CoachGoal.Milestone] = suggested.map { suggestion in
                guard var existing = byValue[key(suggestion.value)] else {
                    return CoachGoal.Milestone(value: suggestion.value,
                                               expectedDate: suggestion.expectedDate)
                }
                // A waypoint the user moved keeps ITS date; an untouched one follows the plan when the
                // goal's target or date changes. `suggest` is deterministic, so this settles.
                if !existing.isCustom { existing.expectedDate = suggestion.expectedDate }
                return existing
            }
            // Custom or already-reached waypoints the suggestion no longer proposes still belong to
            // the route — they are the user's edits and the record of what happened.
            let suggestedValues = Set(suggested.map { key($0.value) })
            merged += goal.milestones.filter {
                ($0.isCustom || $0.achievedAt != nil) && !suggestedValues.contains(key($0.value))
            }
            merged.sort { lhs, rhs in baseline < target ? lhs.value < rhs.value : lhs.value > rhs.value }
            if merged != goal.milestones { goals[index].milestones = merged }
        }
    }

    /// Move a waypoint. Marks it `isCustom`, which is what protects it from the next re-suggest.
    func updateMilestone(goalId: UUID, milestoneId: UUID, value: Double, expectedDate: Date) {
        guard let g = goals.firstIndex(where: { $0.id == goalId }),
              let m = goals[g].milestones.firstIndex(where: { $0.id == milestoneId }),
              goals[g].milestones[m].achievedAt == nil,
              value.isFinite else { return }
        goals[g].milestones[m].value = value
        goals[g].milestones[m].expectedDate = expectedDate
        goals[g].milestones[m].isCustom = true
        let ascending = (goals[g].target ?? 0) > (goals[g].baseline ?? 0)
        goals[g].milestones.sort { ascending ? $0.value < $1.value : $0.value > $1.value }
    }

    /// Remove a waypoint. The goal, its target and its date are untouched — only the route changes.
    func removeMilestone(goalId: UUID, milestoneId: UUID) {
        guard let g = goals.firstIndex(where: { $0.id == goalId }) else { return }
        goals[g].milestones.removeAll { $0.id == milestoneId && $0.achievedAt == nil }
    }

    /// Throw the user's edits away and re-derive the suggested route. Reached waypoints survive —
    /// they record what happened and are not the app's to rewrite.
    func resetMilestones(goalId: UUID, now: Date = Date()) {
        guard let g = goals.firstIndex(where: { $0.id == goalId }) else { return }
        goals[g].milestones = goals[g].milestones.filter { $0.achievedAt != nil }
        ensureMilestones(now: now)
    }

    /// Mark every waypoint the measured value has now passed, once. Idempotent: a waypoint keeps the
    /// date it was FIRST reached, so a later wobble back across the line cannot rewrite history.
    func markMilestonesReached(goalId: UUID, current: Double, on date: Date = Date()) {
        guard let index = goals.firstIndex(where: { $0.id == goalId }),
              // Only a goal still being pursued can reach a waypoint. The status guard lives HERE
              // rather than at the call site — same as `ensureMilestones`' own — so it cannot be
              // bypassed: without it a goal set aside months ago kept collecting `achievedAt` stamps
              // from today's measurement, rewriting the record of a pursuit that had already ended.
              goals[index].status == .active || goals[index].status == .paused,
              let baseline = goals[index].baseline, let target = goals[index].target,
              baseline != target else { return }
        let ascending = target > baseline
        for m in goals[index].milestones.indices where goals[index].milestones[m].achievedAt == nil {
            let value = goals[index].milestones[m].value
            let reached = ascending ? current >= value : current <= value
            if reached { goals[index].milestones[m].achievedAt = date }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(goals) else { return }
        d.set(data, forKey: Self.goalsKey)
    }

    private func closeOpenPause(at index: Int, on date: Date) {
        guard let pauseIndex = goals[index].pauseIntervals.lastIndex(where: { $0.endedAt == nil }) else { return }
        goals[index].pauseIntervals[pauseIndex].endedAt = date
    }

    private func trimHistory(at index: Int) {
        if goals[index].history.count > 20 {
            goals[index].history.removeFirst(goals[index].history.count - 20)
        }
    }
}
