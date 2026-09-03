import Foundation

/// A session the coach PROPOSED — and what the user decided about it.
///
/// The central rule of this file: **nothing the model says becomes a plan on its own.** The coach can
/// only ever `propose`; the transition to `accepted` requires a deliberate user action in the UI. That
/// is why there is no `set_plan` tool and no way for `runCoachTool` to reach `accept`. A coach that
/// quietly writes down what it decided for you isn't a coach, it's a boss.
struct PlanProposal: Codable, Identifiable, Equatable {

    /// The workout evidence behind a completed plan. Manual completion deliberately carries no
    /// fabricated workout; automatic and user-confirmed completion keep a compact immutable snapshot so
    /// a later source re-import/relabel cannot rewrite the plan's history.
    struct CompletionEvidence: Codable, Equatable {
        enum Method: String, Codable { case automatic, confirmed }

        let workoutKey: String
        let startTs: Int
        let endTs: Int
        let sport: String
        let source: String
        let durationS: Double?
        let strain: Double?
        let distanceM: Double?
        let method: Method
        let matchedAt: Date
    }

    /// What kind of session this is. Deliberately coarse — NOOP prescribes intent and rough load, not
    /// sets and reps, because intent is what its data can actually speak to.
    enum Intent: String, Codable, CaseIterable {
        case rest, easy, moderate, hard, mobility

        var label: String {
            switch self {
            case .rest:     return "Rest"
            case .easy:     return "Easy"
            case .moderate: return "Moderate"
            case .hard:     return "Hard"
            case .mobility: return "Mobility"
            }
        }
    }

    /// The lifecycle. `proposed` is where every coach suggestion starts and where it STAYS until the
    /// user does something. Everything after `accepted` describes what actually happened, which is what
    /// makes honest adherence possible later.
    enum Status: String, Codable, Equatable {
        /// The coach suggested it. Not a plan yet.
        case proposed
        /// The user said yes. Only reachable from a UI action.
        case accepted
        /// The user said no. Kept (not deleted) — a decline is information, and the filter-bubble floor
        /// needs to know it happened.
        case declined
        /// The user accepted but changed it (swapped the sport, moved the time).
        case modifiedByUser
        /// It happened.
        case completed
        /// It didn't happen. `skipReason` says why — see the note there.
        case skipped
        /// Deliberately parked (illness, travel) rather than skipped in place.
        case paused
        /// The user MOVED it to another day/time — still intends to do it, just not when first committed.
        /// Distinct from `skipped` (didn't happen) so adherence reads a move as a move, not a miss.
        /// `rescheduledFrom` keeps the original day for the story.
        case rescheduled

        /// True once the user has engaged with the proposal at all.
        var isDecided: Bool { self != .proposed }
        /// True when this counts as a commitment we can later measure against — a session the user still
        /// intends to do (accepted, modified, or moved), or one they already did.
        var isCommitment: Bool {
            self == .accepted || self == .modifiedByUser || self == .completed || self == .rescheduled
        }
    }

    /// Why a session didn't happen. Captured as ONE TAP, because a reason you have to type is a reason
    /// that never gets recorded — and without it "didn't train" silently reads as a discipline problem
    /// when it was usually a calendar, a cold, or a sore knee.
    enum SkipReason: String, Codable, CaseIterable {
        case noTime, tired, pain, notFeelingIt, ill, travel

        var label: String {
            switch self {
            case .noTime:       return "No time"
            case .tired:        return "Too tired"
            case .pain:         return "Pain"
            case .notFeelingIt: return "Not feeling it"
            case .ill:          return "Ill"
            case .travel:       return "Travelling"
            }
        }

        /// Reasons that must soften the next suggestion rather than push through it. Pain and illness
        /// are a body telling you something; the coach doesn't get to argue with that.
        var triggersCaution: Bool { self == .pain || self == .ill }
    }

    /// Where the session came from — so the Journey page can be honest about who decided what.
    enum Source: String, Codable {
        case coachProposed, userCreated, userSwapped
    }

    /// What the person experienced after following a recommendation. Completion alone says only that
    /// it happened; this separates useful adaptation from a session that did nothing or felt harmful.
    enum EffectFeedback: String, Codable, CaseIterable {
        case helpful
        case noEffect
        case negativeEffect

        var label: String {
            switch self {
            case .helpful: return "Helpful"
            case .noEffect: return "No noticeable effect"
            case .negativeEffect: return "Felt worse"
            }
        }
    }

    let id: UUID
    /// The day it's for, "yyyy-MM-dd".
    var day: String
    /// The time the user pinned it to, if they did. A plan with a time is a plan you keep.
    var time: Date?
    /// The activity, free text ("Zone 2 ride", "CrossFit"). Free rather than an enum because the sport
    /// vocabulary comes from the user's own history, not from us.
    var sport: String
    var intent: Intent
    /// Optional target Effort (0–100) for the session.
    ///
    /// When `zone` and `durationMin` are both known this is COMPUTED by the app from the wearer's own
    /// bands (`EffortFeasibility`), not taken from the model. The coach used to be free to name any
    /// number, and named some that its own arithmetic could not produce — "20 min in Zone 2, effort 15"
    /// for a session worth about 34.
    var targetEffort: Double?
    /// The HR zone (1–5) the session is meant to be held in, when it has one.
    var zone: Int?
    /// How long the session should last, in minutes.
    var durationMin: Int?
    /// The coach's one-line reasoning, so an accepted plan still explains itself weeks later.
    var rationale: String
    var status: Status
    var source: Source
    /// What this replaced, when the user swapped it.
    var swappedFrom: String?
    /// The day this session was originally on, when the user rescheduled it to another day.
    var rescheduledFrom: String?
    var skipReason: SkipReason?
    /// Goals this session supports. Empty remains a legitimate general session. One activity is stored
    /// once and may contribute to several goals; this avoids cloning a walk merely because it supports
    /// movement, weight management and wellbeing at the same time.
    var goalIds: [UUID]
    /// Source-compatible bridge for older call sites and stored data. New UI uses `goalIds` and the
    /// multi-select store API; assigning here deliberately replaces the selection with zero or one goal.
    var goalId: UUID? {
        get { goalIds.first }
        set { goalIds = newValue.map { [$0] } ?? [] }
    }
    let createdAt: Date
    var decidedAt: Date?
    var effectFeedback: EffectFeedback?
    var feedbackNote: String?
    var completionEvidence: CompletionEvidence?
    /// Workout candidates the user explicitly rejected for this plan. Capped by the store; without this
    /// memory the same ambiguous import would ask again on every foreground reconciliation.
    var rejectedWorkoutKeys: [String]

    init(id: UUID = UUID(),
         day: String,
         time: Date? = nil,
         sport: String,
         intent: Intent,
         targetEffort: Double? = nil,
         zone: Int? = nil,
         durationMin: Int? = nil,
         rationale: String = "",
         status: Status = .proposed,
         source: Source = .coachProposed,
         swappedFrom: String? = nil,
         rescheduledFrom: String? = nil,
         skipReason: SkipReason? = nil,
         goalId: UUID? = nil,
         goalIds: [UUID]? = nil,
         createdAt: Date = Date(),
         decidedAt: Date? = nil,
         effectFeedback: EffectFeedback? = nil,
         feedbackNote: String? = nil,
         completionEvidence: CompletionEvidence? = nil,
         rejectedWorkoutKeys: [String] = []) {
        self.id = id
        self.day = day
        self.time = time
        self.sport = sport
        self.intent = intent
        self.targetEffort = targetEffort
        self.zone = zone
        self.durationMin = durationMin
        self.rationale = rationale
        self.status = status
        self.source = source
        self.swappedFrom = swappedFrom
        self.rescheduledFrom = rescheduledFrom
        self.skipReason = skipReason
        self.goalIds = Self.uniqueGoalIds(goalIds ?? goalId.map { [$0] } ?? [])
        self.createdAt = createdAt
        self.decidedAt = decidedAt
        self.effectFeedback = effectFeedback
        self.feedbackNote = feedbackNote
        self.completionEvidence = completionEvidence
        self.rejectedWorkoutKeys = rejectedWorkoutKeys
    }

    // Back-compat: fields added later decode with defaults so a stored plan never fails to load.
    private enum CodingKeys: String, CodingKey {
        case id, day, time, sport, intent, targetEffort, zone, durationMin, rationale, status
        case source, swappedFrom, rescheduledFrom, skipReason, goalId, goalIds, createdAt, decidedAt
        case effectFeedback, feedbackNote
        case completionEvidence, rejectedWorkoutKeys
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        day = try c.decodeIfPresent(String.self, forKey: .day) ?? ""
        time = try c.decodeIfPresent(Date.self, forKey: .time)
        sport = try c.decodeIfPresent(String.self, forKey: .sport) ?? ""
        intent = try c.decodeIfPresent(Intent.self, forKey: .intent) ?? .easy
        targetEffort = try c.decodeIfPresent(Double.self, forKey: .targetEffort)
        zone = try c.decodeIfPresent(Int.self, forKey: .zone)
        durationMin = try c.decodeIfPresent(Int.self, forKey: .durationMin)
        rationale = try c.decodeIfPresent(String.self, forKey: .rationale) ?? ""
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .proposed
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .coachProposed
        swappedFrom = try c.decodeIfPresent(String.self, forKey: .swappedFrom)
        rescheduledFrom = try c.decodeIfPresent(String.self, forKey: .rescheduledFrom)
        skipReason = try c.decodeIfPresent(SkipReason.self, forKey: .skipReason)
        let modern = try c.decodeIfPresent([UUID].self, forKey: .goalIds)
        let legacy = try c.decodeIfPresent(UUID.self, forKey: .goalId)
        goalIds = Self.uniqueGoalIds(modern ?? legacy.map { [$0] } ?? [])
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        decidedAt = try c.decodeIfPresent(Date.self, forKey: .decidedAt)
        effectFeedback = try c.decodeIfPresent(EffectFeedback.self, forKey: .effectFeedback)
        feedbackNote = try c.decodeIfPresent(String.self, forKey: .feedbackNote)
        completionEvidence = try c.decodeIfPresent(CompletionEvidence.self, forKey: .completionEvidence)
        rejectedWorkoutKeys = try c.decodeIfPresent([String].self, forKey: .rejectedWorkoutKeys) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(day, forKey: .day)
        try c.encodeIfPresent(time, forKey: .time)
        try c.encode(sport, forKey: .sport)
        try c.encode(intent, forKey: .intent)
        try c.encodeIfPresent(targetEffort, forKey: .targetEffort)
        try c.encodeIfPresent(zone, forKey: .zone)
        try c.encodeIfPresent(durationMin, forKey: .durationMin)
        try c.encode(rationale, forKey: .rationale)
        try c.encode(status, forKey: .status)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(swappedFrom, forKey: .swappedFrom)
        try c.encodeIfPresent(rescheduledFrom, forKey: .rescheduledFrom)
        try c.encodeIfPresent(skipReason, forKey: .skipReason)
        try c.encode(goalIds, forKey: .goalIds)
        try c.encodeIfPresent(goalIds.first, forKey: .goalId)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(decidedAt, forKey: .decidedAt)
        try c.encodeIfPresent(effectFeedback, forKey: .effectFeedback)
        try c.encodeIfPresent(feedbackNote, forKey: .feedbackNote)
        try c.encodeIfPresent(completionEvidence, forKey: .completionEvidence)
        try c.encode(rejectedWorkoutKeys, forKey: .rejectedWorkoutKeys)
    }

    func serves(_ goalId: UUID) -> Bool { goalIds.contains(goalId) }

    private static func uniqueGoalIds(_ values: [UUID]) -> [UUID] {
        var seen = Set<UUID>()
        return values.filter { seen.insert($0).inserted }
    }

    /// The parts of the one-line description that do not depend on who is reading it.
    /// e.g. "Zone 2 ride (easy), 20 min in Zone 2 at 10:00".
    private func summaryStem() -> String {
        var s = "\(sport) (\(intent.rawValue))"
        if let durationMin { s += ", \(durationMin) min" }
        if let zone { s += " in Zone \(zone)" }
        if let time {
            let df = DateFormatter(); df.dateFormat = "HH:mm"
            s += " at \(df.string(from: time))"
        }
        return s
    }

    /// One-line description FOR THE USER — plan cards, the morning suggestion, notification bodies.
    ///
    /// `targetEffort` is stored on NOOP's canonical 0–100 axis (the coach's tools, its context and
    /// `EffortFeasibility` all work there, and the WHOOP 0–21 setting is display-only, #268). So this is
    /// the boundary where it must be converted: a proposal read "target effort 63" on every surface,
    /// whatever the wearer had chosen, and 63 is not a number the 0–21 axis can produce. The figure also
    /// carries its axis, because a lone number in a sentence has no ring or "of N" caption beside it to
    /// be read against.
    ///
    /// Callers writing for the MODEL or for stored memory want `contextSummary()` instead — the split is
    /// deliberate, so neither can be reached by forgetting an argument.
    func summary(effortScale: EffortScale) -> String {
        var s = summaryStem()
        if let targetEffort {
            s += ", target effort " + UnitFormatter.effortWithScale(targetEffort, scale: effortScale)
        }
        return s
    }

    /// One-line description FOR THE MODEL and for semantic memory: Effort stays on the canonical 0–100
    /// axis, unconverted and unlabelled, exactly as the tool schema (`target_effort`, "0–100") and the
    /// day context (`effort(0-100)`) describe it. Rendering the wearer's display axis here would feed the
    /// coach numbers on a scale its own tools cannot accept.
    func contextSummary() -> String {
        var s = summaryStem()
        if let targetEffort { s += String(format: ", target effort %.0f", targetEffort) }
        return s
    }
}

/// The plan book: what was proposed, what you agreed to, and what actually happened.
///
/// On-device JSON in Application Support, same pattern and location as `CoachConversationStore`.
@MainActor
final class CoachPlanStore: ObservableObject {

    static let shared = CoachPlanStore()

    /// Newest first. Capped — this is a working plan, not an archive.
    @Published private(set) var proposals: [PlanProposal] = [] { didSet { save() } }
    /// Transient reconciliation questions, rebuilt from the current workouts. They are not another
    /// source of truth: proposal decisions and rejected workout keys are the persisted state.
    @Published private(set) var reconciliationResolutions: [PlanReconciliationResolution] = []

    // A few thousand compact JSON rows are still small, while 200 recommendations can represent only
    // months for an active user and would make the "all available" habit window silently forget years.
    static let maxProposals = 5_000
    /// After this many consecutive declines, the coach is told to stop softening and re-offer real work.
    /// Without a floor, a few "not today"s would train it into permanent wet-lettuce mode — the filter
    /// bubble, applied to training.
    static let declineStreakFloor = 3

    private static var fileURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("com.noopapp.noop", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("coach-plans.json")
    }

    init(loading: Bool = true) {
        guard loading else { return }
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([PlanProposal].self, from: data) {
            proposals = decoded
        }
    }

    // MARK: - Reads

    /// Everything for a given day, newest first.
    func proposals(forDay day: String) -> [PlanProposal] {
        proposals.filter { $0.day == day }
    }

    /// The still-undecided proposals — what the UI must ask the user about.
    var pending: [PlanProposal] { proposals.filter { $0.status == .proposed } }

    /// Sessions the user actually committed to, on or after `day`.
    func commitments(fromDay day: String) -> [PlanProposal] {
        proposals.filter { $0.status.isCommitment && $0.day >= day }
    }

    /// How many of the most recent DECIDED proposals in a row were declined. Drives the filter-bubble
    /// floor: a run of declines means the coach should ask what's actually wrong, not just keep
    /// shrinking the session until something sticks.
    var declineStreak: Int {
        var streak = 0
        for p in proposals.filter({ $0.status.isDecided }).sorted(by: { ($0.decidedAt ?? $0.createdAt) > ($1.decidedAt ?? $1.createdAt) }) {
            if p.status == .declined { streak += 1 } else { break }
        }
        return streak
    }

    /// The most recent caution-triggering skip (pain / illness) within `days`, if any. A soft gate: the
    /// coach must not propose an escalation on the back of one.
    func recentCautionSkip(withinDays days: Int = 7, now: Date = Date()) -> PlanProposal? {
        let cutoff = now.addingTimeInterval(-Double(days) * 24 * 3600)
        return proposals
            .filter { $0.status == .skipped && ($0.skipReason?.triggersCaution ?? false) }
            .filter { ($0.decidedAt ?? $0.createdAt) >= cutoff }
            .max { ($0.decidedAt ?? $0.createdAt) < ($1.decidedAt ?? $1.createdAt) }
    }

    // MARK: - Writes

    /// Record a coach suggestion. It lands as `.proposed` and stays there — this is the ONLY entry point
    /// the model can reach, and it deliberately cannot set any other status.
    ///
    /// Deduped on `(day, sport)`: a re-proposal of the SAME session on the SAME day replaces the pending
    /// row IN PLACE (keeping its id + createdAt, so the card doesn't flicker and a mid-flight tap can't
    /// hit a dead row) rather than stacking a second card. Scoped to `.proposed` ONLY, and that scoping
    /// is load-bearing: a decided proposal is the user's answer, and re-proposing must never reach it —
    /// it must not silently rewrite an accepted commitment, nor erase a decline (`declineStreak` depends
    /// on the decline surviving). Deduping on `(day, sport)` and not `day` alone keeps a legitimate
    /// AM-ride + PM-mobility on one day as two separate proposals.
    @discardableResult
    func propose(_ proposal: PlanProposal) -> Bool {
        var p = proposal
        p.status = .proposed
        p.source = .coachProposed
        let key = Self.dedupKey(day: p.day, sport: p.sport)

        // Don't re-pitch what the user already has (#P7 9.8 / 10.5): if a same-(day, sport) COMMITMENT
        // already exists — whether the coach proposed it and the user accepted, or the user planned it
        // themselves as their own routine — the coach must not surface it again as a fresh idea. Drop the
        // proposal rather than stack a duplicate card next to a session the user already said yes to.
        if proposals.contains(where: {
            $0.status.isCommitment && Self.dedupKey(day: $0.day, sport: $0.sport) == key
        }) {
            return false
        }

        if let idx = proposals.firstIndex(where: {
            $0.status == .proposed && Self.dedupKey(day: $0.day, sport: $0.sport) == key
        }) {
            let existing = proposals[idx]
            proposals[idx] = PlanProposal(
                id: existing.id, day: p.day, time: p.time, sport: p.sport, intent: p.intent,
                targetEffort: p.targetEffort, zone: p.zone, durationMin: p.durationMin,
                rationale: p.rationale, status: .proposed,
                source: .coachProposed,
                goalIds: p.goalIds.isEmpty ? existing.goalIds : p.goalIds,
                createdAt: existing.createdAt,
                rejectedWorkoutKeys: existing.rejectedWorkoutKeys)
            return true
        }
        proposals.insert(p, at: 0)
        trim()
        return true
    }

    /// The `(day, sport)` identity two proposals share when one supersedes the other. Pure + static so
    /// the dedup rule can be pinned directly; sport is trimmed and case-folded so "  Zone 2 RIDE " and
    /// "Zone 2 ride" collapse.
    static func dedupKey(day: String, sport: String) -> String {
        day + "|" + sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The user said yes. Only ever called from a UI action.
    func accept(_ id: UUID, at time: Date? = nil) {
        update(id) { p in
            p.status = .accepted
            p.decidedAt = Date()
            if let time { p.time = time }
        }
    }

    func decline(_ id: UUID) {
        update(id) { p in
            p.status = .declined
            p.decidedAt = Date()
        }
    }

    /// The user accepted the slot but changed the activity — the swap the user asked for. Keeps what it
    /// replaced so the consequence can be explained and the Journey page can show the real story.
    func swap(_ id: UUID, toSport sport: String, intent: PlanProposal.Intent? = nil, at time: Date? = nil) {
        update(id) { p in
            if p.swappedFrom == nil { p.swappedFrom = p.sport }
            p.sport = sport
            if let intent { p.intent = intent }
            if let time { p.time = time }
            p.status = .modifiedByUser
            p.source = .userSwapped
            p.decidedAt = Date()
        }
    }

    /// The user MOVED a committed session to another day (and optionally a new time). It stays a
    /// commitment; adherence reads this as a move, not a miss. `rescheduledFrom` keeps the original day
    /// (captured once, so moving twice still points back to where it started).
    func reschedule(_ id: UUID, toDay newDay: String, at time: Date? = nil) {
        update(id) { p in
            if p.rescheduledFrom == nil { p.rescheduledFrom = p.day }
            p.day = newDay
            p.time = time
            p.status = .rescheduled
            p.decidedAt = Date()
        }
    }

    func complete(_ id: UUID, evidence: PlanProposal.CompletionEvidence? = nil) {
        update(id) { p in
            p.status = .completed
            p.decidedAt = Date()
            p.completionEvidence = evidence
        }
        reconciliationResolutions.removeAll { $0.proposalId == id }
    }

    /// The user confirmed that a candidate workout fulfilled this commitment.
    func confirmWorkout(_ workout: PlanWorkoutReference, for id: UUID, now: Date = Date()) {
        complete(id, evidence: workout.completionEvidence(method: .confirmed, matchedAt: now))
    }

    /// Remember a rejected candidate and remove it from the current question immediately.
    func rejectWorkout(_ workoutKey: String, for id: UUID) {
        update(id) { proposal in
            guard !proposal.rejectedWorkoutKeys.contains(workoutKey) else { return }
            proposal.rejectedWorkoutKeys.append(workoutKey)
            if proposal.rejectedWorkoutKeys.count > 20 {
                proposal.rejectedWorkoutKeys.removeFirst(proposal.rejectedWorkoutKeys.count - 20)
            }
        }
        reconciliationResolutions.removeAll { $0.proposalId == id }
    }

    func setReconciliationResolutions(_ resolutions: [PlanReconciliationResolution]) {
        reconciliationResolutions = resolutions
    }

    /// Assign or clear which goal a session serves. General sessions deliberately use nil.
    func linkGoal(_ goalId: UUID?, to proposalId: UUID) {
        update(proposalId) { $0.goalId = goalId }
    }

    /// Assign the confirmed set of goals this one session supports. Order follows the user's selection;
    /// duplicates are collapsed so one activity can never count twice for the same goal.
    func linkGoals(_ goalIds: [UUID], to proposalId: UUID) {
        var seen = Set<UUID>()
        let unique = goalIds.filter { seen.insert($0).inserted }
        update(proposalId) { $0.goalIds = unique }
    }

    func recordEffect(_ id: UUID, feedback: PlanProposal.EffectFeedback, note: String? = nil) {
        update(id) { proposal in
            guard proposal.status == .completed else { return }
            proposal.effectFeedback = feedback
            let clean = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            proposal.feedbackNote = clean?.isEmpty == false ? clean : nil
        }
    }

    /// Mark a session as not-done WITH its reason. The reason is the point: it's what stops adherence
    /// from being a scoreboard of failures.
    func skip(_ id: UUID, reason: PlanProposal.SkipReason) {
        update(id) { p in
            p.status = .skipped
            p.skipReason = reason
            p.decidedAt = Date()
        }
    }

    func pause(_ id: UUID) {
        update(id) { p in
            p.status = .paused
            p.decidedAt = Date()
        }
    }

    /// Undo a set time without deciding anything else about the session — the counterpart to
    /// `PlanTimeSheet`'s "Set" that was missing. Also cancels any reminder scheduled for it, via `update`.
    func clearTime(_ id: UUID) {
        update(id) { p in p.time = nil }
    }

    /// A session the USER planned themselves, already accepted (they don't need to approve their own idea).
    /// `goalId` links it to the goal it serves when the user logged it from that goal's journey.
    func addUserSession(day: String, time: Date?, sport: String, intent: PlanProposal.Intent,
                        goalId: UUID? = nil, goalIds: [UUID]? = nil) {
        var p = PlanProposal(day: day, time: time, sport: sport, intent: intent,
                             status: .accepted, source: .userCreated, goalId: goalId,
                             goalIds: goalIds)
        p.decidedAt = Date()
        proposals.insert(p, at: 0)
        trim()
        PlanReminder.schedule(for: p)
    }

    /// Sessions the user actually COMPLETED for a given goal, from `since` onward.
    ///
    /// Only sessions explicitly linked to THIS goal count. General/unlinked sessions deliberately do not:
    /// with several goals active at once, date-only attribution would credit the same workout to each one.
    func completedSessions(forGoal goalId: UUID, since dayKey: String) -> [PlanProposal] {
        proposals.filter { p in
            guard p.status == .completed else { return false }
            return p.serves(goalId) && p.day >= dayKey
        }
    }

    func remove(_ id: UUID) {
        PlanReminder.cancel(for: id)
        proposals.removeAll { $0.id == id }
    }

    func clearAll() {
        for p in proposals { PlanReminder.cancel(for: p.id) }
        proposals = []
    }

    /// Every status-changing entry point above goes through this one choke point, so rescheduling the
    /// reminder from the CURRENT state after each mutation is enough to keep it truthful — there is no
    /// second cancellation path to forget when a commitment is swapped, skipped, or its time cleared.
    private func update(_ id: UUID, _ mutate: (inout PlanProposal) -> Void) {
        guard let idx = proposals.firstIndex(where: { $0.id == id }) else { return }
        mutate(&proposals[idx])
        PlanReminder.schedule(for: proposals[idx])
        // Any explicit user/store mutation invalidates the transient question built from the previous
        // snapshot. The next coordinator pass may create a fresh one for the new day/sport/time.
        reconciliationResolutions.removeAll { $0.proposalId == id }
    }

    private func trim() {
        if proposals.count > Self.maxProposals {
            proposals = Array(proposals.prefix(Self.maxProposals))
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(proposals) else { return }
        try? data.write(to: Self.fileURL, options: .atomic)
        let snapshot = proposals
        Task { await CoachSemanticMemory.shared.recommendationsChanged(snapshot) }
    }
}
