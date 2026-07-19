import Foundation

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
            case .strength, .stress, .recovery, .custom: return ""
            }
        }

        /// True when this kind can carry a baseline/target pair worth doing arithmetic on.
        var isQuantified: Bool { !unit.isEmpty }
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
         history: [Event] = []) {
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
    }

    // Back-compat: every field added after the first ship decodes with a default, so a stored goal
    // never fails to load and silently vanish.
    private enum CodingKeys: String, CodingKey {
        case id, kind, title, baseline, target, targetDate, status
        case motivation, motivationTags, shareMotivation, acknowledgedRisk, createdAt, history
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

/// The single active goal, persisted on-device. One goal for now: the roadmap deliberately defers
/// multiple parallel goals (and the conflict resolution they'd need) until one goal works well.
///
/// Shared instance so the engine (reader) and the settings UI (editor) observe the same state, exactly
/// like `CoachMemory.shared`.
@MainActor
final class CoachGoalStore: ObservableObject {

    static let shared = CoachGoalStore()

    @Published var goal: CoachGoal? { didSet { save() } }

    private let d: UserDefaults
    private static let goalKey = "ai.goal"
    /// The legacy free-text goal this replaces. Read once for migration, then left alone (never
    /// deleted, so downgrading to an older build doesn't lose the user's sentence).
    static let legacyGoalKey = "ai.trainingGoal"

    init(defaults: UserDefaults = .standard) {
        self.d = defaults
        if let data = defaults.data(forKey: Self.goalKey),
           let decoded = try? JSONDecoder().decode(CoachGoal.self, from: data) {
            self.goal = decoded
        } else {
            self.goal = Self.migrateLegacy(defaults: defaults)
        }
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

    /// Record a change on the goal's log. Kept small (most recent 20) — this is a story, not an audit DB.
    func note(_ what: String) {
        guard var g = goal else { return }
        g.history.append(.init(date: Date(), what: what))
        if g.history.count > 20 { g.history.removeFirst(g.history.count - 20) }
        goal = g
    }

    // MARK: Lifecycle

    /// Close the goal as reached. It STAYS in the store — the Journey page shows the closure and the
    /// coach gets to congratulate — until a new goal replaces it. Only an open goal can be closed.
    func markAchieved(on date: Date = Date()) {
        guard var g = goal, g.status == .active || g.status == .paused else { return }
        g.status = .achieved
        g.history.append(.init(date: date, what: "Goal achieved"))
        goal = g
    }

    /// Set the goal aside without shame — injuries, life, changed priorities are all legitimate ends.
    /// The one-tap reason lands in the history so the story stays honest, never as a debt to explain.
    func setAside(reason: String, on date: Date = Date()) {
        guard var g = goal, g.status == .active || g.status == .paused else { return }
        g.status = .abandoned
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        g.history.append(.init(date: date, what: why.isEmpty ? "Goal set aside" : "Goal set aside — \(why)"))
        goal = g
    }

    func clear() { goal = nil }

    private func save() {
        guard let goal else { d.removeObject(forKey: Self.goalKey); return }
        if let data = try? JSONEncoder().encode(goal) { d.set(data, forKey: Self.goalKey) }
    }
}
