import Foundation
import WhoopStore

/// Immutable workout snapshot used by reconciliation UI and completion evidence. `WorkoutRow` has no
/// stable id, so the key intentionally excludes source: the repository may choose a richer cross-source
/// twin after a later import, but it is still the same start/end/sport activity.
struct PlanWorkoutReference: Codable, Equatable, Identifiable {
    let workoutKey: String
    let startTs: Int
    let endTs: Int
    let sport: String
    let source: String
    let durationS: Double?
    let strain: Double?
    let distanceM: Double?

    var id: String { workoutKey }

    init(_ row: WorkoutRow) {
        workoutKey = Self.key(startTs: row.startTs, endTs: row.endTs, sport: row.sport)
        startTs = row.startTs
        endTs = row.endTs
        sport = row.sport
        source = row.source
        durationS = row.durationS
        strain = row.strain
        distanceM = row.distanceM
    }

    static func key(startTs: Int, endTs: Int, sport: String) -> String {
        "\(startTs)|\(endTs)|\(PlanWorkoutMatcher.normalizedLabel(sport))"
    }

    func completionEvidence(method: PlanProposal.CompletionEvidence.Method,
                            matchedAt: Date) -> PlanProposal.CompletionEvidence {
        .init(workoutKey: workoutKey, startTs: startTs, endTs: endTs, sport: sport, source: source,
              durationS: durationS, strain: strain, distanceM: distanceM,
              method: method, matchedAt: matchedAt)
    }
}

struct PlanReconciliationResolution: Equatable, Identifiable {
    enum Kind: Equatable { case candidates, overdue }
    let proposalId: UUID
    let kind: Kind
    let candidates: [PlanWorkoutReference]
    var id: UUID { proposalId }
}

/// Pure, deterministic matching between user-approved plan commitments and locally stored workouts.
/// It never calls a model and never declares a miss. Ambiguity is an explicit result for the user.
enum PlanWorkoutMatcher {
    struct Result: Equatable {
        struct Automatic: Equatable {
            let proposalId: UUID
            let workout: PlanWorkoutReference
        }
        let automatic: [Automatic]
        let resolutions: [PlanReconciliationResolution]
    }

    private static let fourHours: TimeInterval = 4 * 3600

    static func match(proposals: [PlanProposal], workouts: [WorkoutRow], now: Date = Date(),
                      calendar: Calendar = .current) -> Result {
        let open = proposals.filter { proposal in
            proposal.status == .accepted || proposal.status == .modifiedByUser
                || proposal.status == .rescheduled
        }
        let completedKeys = Set(proposals.compactMap { $0.completionEvidence?.workoutKey })
        let available = workouts
            .filter { Date(timeIntervalSince1970: TimeInterval($0.startTs)) <= now }
            .map(PlanWorkoutReference.init)
            .filter { !completedKeys.contains($0.workoutKey) }

        var candidatesByPlan: [UUID: [PlanWorkoutReference]] = [:]
        var plansByWorkout: [String: Set<UUID>] = [:]

        for proposal in open {
            let candidates = available.filter { workout in
                guard !proposal.rejectedWorkoutKeys.contains(workout.workoutKey) else { return false }
                return isCandidate(proposal: proposal, workout: workout, calendar: calendar)
            }
            candidatesByPlan[proposal.id] = candidates
            for workout in candidates where isStrongSportMatch(proposal.sport, workout.sport) {
                plansByWorkout[workout.workoutKey, default: []].insert(proposal.id)
            }
        }

        var automatic: [Result.Automatic] = []
        var consumed = Set<String>()
        // Timed commitments first, then oldest plan day. This makes conflict resolution stable and gives
        // the more specific promise first claim without depending on array insertion order.
        let ordered = open.sorted {
            if ($0.time != nil) != ($1.time != nil) { return $0.time != nil }
            if $0.day != $1.day { return $0.day < $1.day }
            return $0.id.uuidString < $1.id.uuidString
        }
        for proposal in ordered {
            let strong = (candidatesByPlan[proposal.id] ?? []).filter {
                isStrongSportMatch(proposal.sport, $0.sport) && !consumed.contains($0.workoutKey)
            }
            guard strong.count == 1, let workout = strong.first,
                  plansByWorkout[workout.workoutKey]?.count == 1 else { continue }
            automatic.append(.init(proposalId: proposal.id, workout: workout))
            consumed.insert(workout.workoutKey)
        }

        let autoPlans = Set(automatic.map(\.proposalId))
        let today = dayKey(now, calendar: calendar)
        var resolutions: [PlanReconciliationResolution] = []
        for proposal in ordered where !autoPlans.contains(proposal.id) {
            let candidates = (candidatesByPlan[proposal.id] ?? [])
                .filter { !consumed.contains($0.workoutKey) }
                .sorted { $0.startTs < $1.startTs }
            if !candidates.isEmpty {
                resolutions.append(.init(proposalId: proposal.id, kind: .candidates,
                                         candidates: candidates))
            } else if proposal.day < today {
                resolutions.append(.init(proposalId: proposal.id, kind: .overdue, candidates: []))
            }
        }
        return Result(automatic: automatic, resolutions: resolutions)
    }

    private static func isCandidate(proposal: PlanProposal, workout: PlanWorkoutReference,
                                    calendar: Calendar) -> Bool {
        let workoutDate = Date(timeIntervalSince1970: TimeInterval(workout.startTs))
        let timeFits: Bool
        if let planned = proposal.time {
            timeFits = abs(workoutDate.timeIntervalSince(planned)) <= fourHours
        } else {
            timeFits = dayKey(workoutDate, calendar: calendar) == proposal.day
        }
        guard timeFits else { return false }
        if isStrongSportMatch(proposal.sport, workout.sport) { return true }
        // Generic imported/detected labels can be plausible in the right time slot, but never strong
        // enough for automatic completion.
        return isGeneric(workout.sport) || isGeneric(proposal.sport)
    }

    static func isStrongSportMatch(_ planned: String, _ actual: String) -> Bool {
        guard !isGeneric(planned), !isGeneric(actual) else { return false }
        return sportFamily(planned) == sportFamily(actual)
    }

    static func normalizedLabel(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func sportFamily(_ value: String) -> String {
        let s = normalizedLabel(value)
        let families: [(String, [String])] = [
            ("running", ["run", "running", "jog", "treadmill run", "lauf"]),
            ("cycling", ["ride", "bike", "biking", "cycling", "cycle", "spin", "rad"]),
            ("walking", ["walk", "walking", "treadmill walk", "spazier"]),
            ("hiking", ["hike", "hiking", "wander"]),
            ("strength", ["strength", "weightlifting", "bodybuilding", "crossfit", "kraft"]),
            ("mobility", ["mobility", "stretch", "stretching", "yoga", "pilates", "mobilitat"]),
            ("swimming", ["swim", "swimming", "pool swim", "open water swim", "schwimm"]),
            ("rowing", ["row", "rowing", "row machine", "rudern"]),
            ("hiit", ["hiit", "interval"]),
        ]
        for (family, needles) in families where needles.contains(where: { s.contains($0) }) {
            return family
        }
        return "label:\(s)"
    }

    private static func isGeneric(_ value: String) -> Bool {
        let s = normalizedLabel(value)
        return s.isEmpty || s == "workout" || s == "other" || s == "detected"
            || s == "training" || s == "activity"
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

@MainActor
enum PlanReconciliationCoordinator {
    /// Rebuild the closed loop from the canonical, already cross-source-deduplicated workout feed.
    @discardableResult
    static func reconcile(repo: Repository, store suppliedStore: CoachPlanStore? = nil,
                          now: Date = Date()) async -> [PlanReconciliationResolution] {
        // TEMP DIAGNOSTIC (#freeze-investigation): a launch trace showed the startup sequence reaching
        // "repo.refresh done" and never reaching "plan reconcile done", so the stall is inside this
        // function. Split its three steps so the next capture names the guilty one.
        // Remove with the rest of the FREEZE-DIAG block.
        let diagT0 = Date()
        func diagStep(_ name: String) {
            NSLog("[FREEZE-DIAG] reconcile \(name) at +\(String(format: "%.2f", Date().timeIntervalSince(diagT0)))s")
        }
        let store = suppliedStore ?? CoachPlanStore.shared
        PlanGoalAttributionMigration.runIfNeeded(store: store, goals: CoachGoalStore.shared.goals)
        diagStep("goal-attribution migration done")
        // `reconcileHrCap: 0` — matching keys on `(startTs, endTs, sport)` and never consults HR. `strain` is
        // carried into `completionEvidence`, which no view reads, and only for automatic matches. The
        // display-only HR reconcile would put one query per candidate workout on the launch path for
        // nothing. See `Repository.workoutRows(days:reconcileHrCap:)`.
        let workouts = await repo.workoutRows(days: 45, reconcileHrCap: 0)
        diagStep("workoutRows(45) done n=\(workouts.count) proposals=\(store.proposals.count)")
        let result = PlanWorkoutMatcher.match(proposals: store.proposals, workouts: workouts, now: now)
        diagStep("match #1 done automatic=\(result.automatic.count)")
        for match in result.automatic {
            let proposal = store.proposals.first { $0.id == match.proposalId }
            store.complete(match.proposalId,
                           evidence: match.workout.completionEvidence(method: .automatic,
                                                                        matchedAt: now))
            if let proposal {
                CoachNotifier.postAutomaticCompletion(proposal: proposal, workout: match.workout,
                                                       now: now)
            }
        }
        // Re-run after mutations so conflicts freed by an automatic match and every transient question
        // reflect the persisted state rather than the pre-mutation snapshot.
        let final = PlanWorkoutMatcher.match(proposals: store.proposals, workouts: workouts, now: now)
        diagStep("match #2 done")
        store.setReconciliationResolutions(final.resolutions)
        CoachNotifier.syncPlanReconciliation(final.resolutions, proposals: store.proposals, now: now)
        diagStep("notifier sync done")
        return final.resolutions
    }
}

/// One-time conservative bridge for plans saved before `goalId` existed. A completed unlinked session
/// is attributed only when exactly one goal's lifetime contains that day; ambiguity stays general.
@MainActor
enum PlanGoalAttributionMigration {
    static let defaultsKey = "coach.planGoalAttribution.v2"

    static func runIfNeeded(store: CoachPlanStore, goals: [CoachGoal],
                            defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: defaultsKey) else { return }
        defer { defaults.set(true, forKey: defaultsKey) }

        for proposal in store.proposals where proposal.status == .completed && proposal.goalId == nil {
            let eligible = goals.filter { goal in
                let start = dayKey(goal.createdAt)
                guard start <= proposal.day else { return false }
                switch goal.status {
                case .active, .paused:
                    return true
                case .achieved, .abandoned, .archived:
                    guard let closed = goal.history.last?.date else { return false }
                    return proposal.day <= dayKey(closed)
                }
            }
            if eligible.count == 1 { store.linkGoal(eligible[0].id, to: proposal.id) }
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
