import Foundation

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
    nonisolated static let declineStreakFloor = 3

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

    /// The user set or changed only the time of day. Status, source and the swap history stay as they
    /// were: recording a time change as a swap made the Journey page report a sport change that never
    /// happened.
    func setTime(_ id: UUID, at time: Date?) {
        update(id) { $0.time = time }
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
    ///
    /// One recorded workout fulfils at most one commitment, the rule the automatic matcher already
    /// applies. A workout offered to two plans used to stay on the second plan's question after the
    /// first confirmation, and confirming it there counted the same session twice toward a goal.
    func confirmWorkout(_ workout: PlanWorkoutReference, for id: UUID, now: Date = Date()) {
        guard !proposals.contains(where: {
            $0.id != id && $0.completionEvidence?.workoutKey == workout.workoutKey
        }) else { return }
        complete(id, evidence: workout.completionEvidence(method: .confirmed, matchedAt: now))
        reconciliationResolutions = reconciliationResolutions.compactMap { resolution in
            guard resolution.kind == .candidates,
                  resolution.candidates.contains(where: { $0.workoutKey == workout.workoutKey })
            else { return resolution }
            let remaining = resolution.candidates.filter { $0.workoutKey != workout.workoutKey }
            return remaining.isEmpty ? nil
                : PlanReconciliationResolution(proposalId: resolution.proposalId, kind: .candidates,
                                               candidates: remaining)
        }
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
