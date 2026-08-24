import Foundation
import WhoopStore

extension AICoachEngine {
    /// Parses and stores a review-only goal/routine bundle. The only mutation here is to the proposal
    /// inbox; active goals and actions are deliberately unreachable until the review UI confirms them.
    func proposeGoalSetupTool(input: [String: Any]) async -> String {
        await proposeGoalSetupTool(input: input, proposalStore: .shared)
    }

    func proposeGoalSetupTool(input: [String: Any],
                              proposalStore: CoachGoalSetupProposalStore) async -> String {
        let goalInput = input["goal"] as? [String: Any]
        let routineInputs = (input["routines"] as? [[String: Any]] ?? []).prefix(5)
        guard goalInput != nil || !routineInputs.isEmpty else {
            return "Nothing drafted: include a goal, at least one routine, or both."
        }

        let goalResult = await parseGoalDraft(goalInput)
        if let error = goalResult.error { return "Nothing drafted: \(error)" }
        let goalDraft = goalResult.value

        var routines: [CoachGoalSetupProposal.RoutineDraft] = []
        for raw in routineInputs {
            switch parseRoutineDraft(raw, setupGoal: goalDraft?.goal) {
            case .success(let routine): routines.append(routine)
            case .failure(let error): return "Nothing drafted: \(error.description)"
            }
        }
        guard goalDraft != nil || !routines.isEmpty else {
            return "Nothing drafted: the setup contained no usable goal or routines."
        }

        let rationale = ((input["rationale"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let proposal = CoachGoalSetupProposal(goal: goalDraft, routines: routines,
                                              rationale: rationale)
        guard proposalStore.propose(proposal) else {
            return "Nothing drafted: the setup was empty."
        }
        let parts = [goalDraft == nil ? nil : "goal",
                     routines.isEmpty ? nil : "\(routines.count) routine\(routines.count == 1 ? "" : "s")"]
            .compactMap { $0 }.joined(separator: " and ")
        return "Drafted (NOT active): \(parts). It is waiting in Goal & Journey for the user to review, "
            + "edit and confirm. Do not describe it as created or enabled."
    }

    private struct ParsedGoalDraft {
        let value: CoachGoalSetupProposal.GoalDraft?
        let error: String?
    }

    private func parseGoalDraft(_ raw: [String: Any]?) async -> ParsedGoalDraft {
        guard let raw else { return .init(value: nil, error: nil) }
        let operation = CoachGoalSetupProposal.Operation(rawValue: (raw["operation"] as? String) ?? "create")
            ?? .create
        let existing: CoachGoal?
        if operation == .update {
            guard let idText = raw["goal_id"] as? String, let id = UUID(uuidString: idText),
                  let found = CoachGoalStore.shared.goal(id: id),
                  found.status == .active || found.status == .paused else {
                return .init(value: nil, error: "goal_id must name an existing active or paused goal for update")
            }
            existing = found
        } else {
            existing = nil
        }

        let kind: CoachGoal.Kind
        if let text = raw["kind"] as? String, let parsed = CoachGoal.Kind(rawValue: text) { kind = parsed }
        else if let existing { kind = existing.kind }
        else { return .init(value: nil, error: "a new goal needs a valid kind") }

        let title = ((raw["title"] as? String) ?? existing?.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .init(value: nil, error: "a goal needs a title") }

        var baseline = Self.doubleArg(raw["baseline"]) ?? existing?.baseline
        var baselineEvidence: CoachGoalSetupProposal.BaselineEvidence?
        if raw["use_current_baseline"] as? Bool == true {
            if let resolved = await resolveLocalBaseline(for: kind) {
                baseline = resolved.value
                baselineEvidence = resolved
            }
        }
        let target = Self.doubleArg(raw["target"]) ?? existing?.target
        let targetDate = (raw["target_date"] as? String).flatMap(Self.parseSetupDay)
            ?? existing?.targetDate
        let tags: [CoachGoal.MotivationTag]
        if let values = raw["motivation_tags"] as? [String] {
            tags = values.compactMap(CoachGoal.MotivationTag.init(rawValue:))
        } else {
            tags = existing?.motivationTags ?? []
        }
        let goal = CoachGoal(id: existing?.id ?? UUID(), kind: kind, title: title,
                             baseline: baseline, target: target, targetDate: targetDate,
                             status: .active, motivation: existing?.motivation ?? "",
                             motivationTags: tags, shareMotivation: existing?.shareMotivation ?? false,
                             acknowledgedRisk: existing?.acknowledgedRisk,
                             createdAt: existing?.createdAt ?? Date(), history: existing?.history ?? [],
                             pauseIntervals: existing?.pauseIntervals ?? [], closure: existing?.closure)
        return .init(value: .init(operation: operation, editingId: existing?.id, goal: goal,
                                 baselineEvidence: baselineEvidence), error: nil)
    }

    private struct SetupInputError: Error {
        let description: String
    }

    private func parseRoutineDraft(_ raw: [String: Any], setupGoal: CoachGoal?)
        -> Result<CoachGoalSetupProposal.RoutineDraft, SetupInputError> {
        let operation = CoachGoalSetupProposal.Operation(rawValue: (raw["operation"] as? String) ?? "create")
            ?? .create
        let existing: GoalAction?
        if operation == .update {
            guard let text = raw["action_id"] as? String, let id = UUID(uuidString: text),
                  let found = GoalActionStore.shared.actions.first(where: { $0.id == id }) else {
                return .failure(.init(description: "action_id must name an existing routine for update"))
            }
            existing = found
        } else {
            existing = nil
        }
        let title = ((raw["title"] as? String) ?? existing?.title ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .failure(.init(description: "each routine needs a title")) }
        let forbidden = ["nutrition", "diet", "meal plan", "medication", "dosage", "treatment",
                         "ernährung", "diät", "medikament", "dosierung", "behandlung"]
        guard !forbidden.contains(where: { title.localizedCaseInsensitiveContains($0) }) else {
            return .failure(.init(description: "nutrition, medication and treatment routines are outside Coach scope"))
        }

        let requirement: GoalAction.Requirement
        if let type = raw["type"] as? String {
            switch type {
            case "steps":
                let minimum = max(1_000, min(Self.intArg(raw["minimum_steps"]) ?? 10_000, 50_000))
                requirement = .steps(minimum: minimum)
            case "workout":
                let sports = (raw["sports"] as? [String] ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                guard !sports.isEmpty else {
                    return .failure(.init(description: "a workout routine needs at least one activity name"))
                }
                let minutes = Self.intArg(raw["minimum_minutes"]).map { max(5, min($0, 240)) }
                requirement = .workout(sports: sports, minimumMinutes: minutes)
            case "manual": requirement = .manual
            default: return .failure(.init(description: "routine type must be steps, workout or manual"))
            }
        } else if let existing {
            requirement = existing.requirement
        } else {
            return .failure(.init(description: "a new routine needs a type"))
        }

        let schedule: GoalAction.Schedule
        if let scheduleText = raw["schedule"] as? String {
            if scheduleText == "daily" { schedule = .daily }
            else if scheduleText == "weekdays" {
                let days = (raw["weekdays"] as? [Int] ?? []).filter { (1...7).contains($0) }
                let unique = Array(Set(days)).sorted()
                guard !unique.isEmpty else {
                    return .failure(.init(description: "a weekday routine needs at least one weekday from 1 to 7"))
                }
                schedule = .weekdays(unique)
            } else { return .failure(.init(description: "schedule must be daily or weekdays")) }
        } else { schedule = existing?.schedule ?? .daily }

        var goalIds: [UUID]
        if raw.keys.contains("goal_ids") {
            goalIds = []
            for text in raw["goal_ids"] as? [String] ?? [] {
                guard let id = UUID(uuidString: text),
                      CoachGoalStore.shared.activeGoals.contains(where: { $0.id == id }) else {
                    return .failure(.init(description: "routine goal_ids must use exact active-goal ids"))
                }
                if !goalIds.contains(id) { goalIds.append(id) }
            }
        } else { goalIds = existing?.goalIds ?? [] }
        let explicitlySupportsSetup = raw["supports_setup_goal"] as? Bool
        if let setupGoal, explicitlySupportsSetup == true || (explicitlySupportsSetup == nil && goalIds.isEmpty) {
            if !goalIds.contains(setupGoal.id) { goalIds.append(setupGoal.id) }
        }
        guard !goalIds.isEmpty else {
            return .failure(.init(description: "each routine must support the setup goal or an active goal"))
        }
        let action = GoalAction(id: existing?.id ?? UUID(), title: title, requirement: requirement,
                                schedule: schedule, goalIds: goalIds,
                                isActive: existing?.isActive ?? true,
                                createdAt: existing?.createdAt ?? Date())
        return .success(.init(operation: operation, editingId: existing?.id, action: action))
    }

    private func resolveLocalBaseline(for kind: CoachGoal.Kind) async
        -> CoachGoalSetupProposal.BaselineEvidence? {
        switch kind {
        case .run where toolConsent.enabled.contains(.workouts):
            let workouts = await repo.workoutRows(days: 365)
            guard let row = workouts.filter({ $0.sport.lowercased().contains("run") && ($0.distanceM ?? 0) > 0 })
                .max(by: { ($0.distanceM ?? 0) < ($1.distanceM ?? 0) }) else { return nil }
            return .init(value: (row.distanceM ?? 0) / 1_000,
                         date: Date(timeIntervalSince1970: Double(row.startTs)), source: "Recorded run")
        case .consistency where toolConsent.enabled.contains(.workouts):
            let workouts = await repo.workoutRows(days: 30)
            guard !workouts.isEmpty else { return nil }
            return .init(value: Double(workouts.count) / (30.0 / 7.0),
                         date: workouts.map(\.startTs).max().map { Date(timeIntervalSince1970: Double($0)) },
                         source: "Last 30 days of workouts")
        case .sleep where toolConsent.enabled.contains(.coreBiometrics):
            let rows = Array(repo.days.sorted { $0.day < $1.day }.suffix(14))
            let values = rows.compactMap(\.totalSleepMin)
            guard !values.isEmpty else { return nil }
            return .init(value: values.reduce(0, +) / Double(values.count) / 60,
                         date: rows.last.flatMap { Self.parseSetupDay($0.day) }, source: "14-night sleep average")
        case .weight where toolConsent.enabled.contains(.coreBiometrics):
            let weights = await repo.weightSeries(days: 365)
            // A manually logged weigh-in belongs to the Logs consent group. With only core biometric
            // access, fall back to the newest Apple Health sample instead of leaking a private log.
            guard let latest = weights.reversed().first(where: {
                $0.source != .manual || toolConsent.enabled.contains(.logs)
            }) else { return nil }
            let label = latest.source == .manual
                ? "Latest weigh-in logged in NOOP" : "Latest Apple Health weight"
            return .init(value: latest.value, date: Self.parseSetupDay(latest.day), source: label)
        default:
            return nil
        }
    }

    private static func doubleArg(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? String { return Double(value.replacingOccurrences(of: ",", with: ".")) }
        return nil
    }

    private static func parseSetupDay(_ text: String) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.autoupdatingCurrent.date(from: DateComponents(year: parts[0], month: parts[1],
                                                                       day: parts[2], hour: 12))
    }
}
