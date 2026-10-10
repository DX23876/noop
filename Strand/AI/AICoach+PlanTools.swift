import Foundation
import Combine
import Security
import WhoopStore
import StrandAnalytics
import StrandImport
import StrandDesign
import SemanticMemory

// AICoachEngine plan tools (`propose_plan` and its siblings).
// Split out of AICoach.swift unchanged; `AICoachEngine` itself lives there.

extension AICoachEngine {
    // MARK: - Plan tools

    /// `propose_plan`: record a SUGGESTION. Note what this deliberately cannot do — it cannot accept,
    /// schedule, or activate anything. The proposal sits in `.proposed` until the user taps yes, and the
    /// returned string tells the model to say exactly that rather than describing it as settled.
    func proposePlanTool(day: String?, sport: String, intent: String,
                         targetEffort: Double?, rationale: String, time: String?,
                         zone: Int? = nil, durationMin: Int? = nil,
                         goalId: String? = nil, goalIds: [String]? = nil) async -> String {
        let trimmedSport = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSport.isEmpty else { return "Nothing proposed: name the activity." }
        guard let parsedIntent = PlanProposal.Intent(rawValue: intent.lowercased()) else {
            return "Nothing proposed: intent must be one of rest, easy, moderate, hard, mobility."
        }
        let requestedDay = (day ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let dayKey = requestedDay.isEmpty ? Repository.localDayKey(Date()) : requestedDay

        // "HH:mm" on the proposal's own day — a time without its day would silently land on today.
        var when: Date?
        if let time, !time.isEmpty {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm"
            df.timeZone = .current
            when = df.date(from: "\(dayKey) \(time)")
        }

        let adaptation = CoachRecommendationAdaptation.advice(
            sport: trimmedSport,
            intent: parsedIntent,
            day: dayKey,
            proposedTime: when,
            history: CoachPlanStore.shared.proposals
        )
        if let reason = adaptation.blockReason {
            return "Not proposed because of the user's local feedback: \(reason)"
        }
        if when == nil { when = adaptation.preferredTime }

        // Link only to a validated ACTIVE goal. With one goal the historical implicit behaviour remains;
        // with several the tool must use the opaque id from the goal context or leave a genuinely general
        // session unlinked. Never guess between goals.
        let activeGoals = CoachGoalStore.shared.activeGoals
        let rawGoalIds = (goalIds ?? []) + (goalId.map { [$0] } ?? [])
        var requestedGoals: [UUID] = []
        for raw in rawGoalIds where !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = UUID(uuidString: raw), activeGoals.contains(where: { $0.id == parsed }) else {
                return "Nothing proposed: goal_ids must name active goals using exact ids from the goal context."
            }
            if !requestedGoals.contains(parsed) { requestedGoals.append(parsed) }
        }
        if requestedGoals.isEmpty, activeGoals.count == 1 {
            requestedGoals = [activeGoals[0].id]
        }
        // Effort is a CONSEQUENCE of intensity × duration, not a number to pick. When the model names a
        // zone and a duration, compute what that session is actually worth against the wearer's OWN
        // bands and use that; a supplied figure survives only if it is within a few points of it.
        let cleanZone = zone.flatMap { (1...5).contains($0) ? $0 : nil }
        let cleanDuration = durationMin.flatMap { $0 > 0 ? min($0, 600) : nil }
        var effort = targetEffort.map { max(0, min($0, 100)) }
        var correction: String?
        if let cleanZone, let cleanDuration,
           let range = EffortFeasibility.sessionEffortRange(
               zone: cleanZone, minutes: Double(cleanDuration),
               zoneSet: ProfileStore().hrZoneSet, restingHR: await recentRestingHR()) {
            let computed = (range.typical * 10).rounded() / 10
            if let given = effort, range.distanceFromTypical(given) <= EffortFeasibility.targetTolerance {
                // Close enough to be the coach's judgement about where in the band to sit — leave it.
            } else {
                if let given = effort {
                    correction = String(format: "Your target of %.0f was replaced with %.0f: ", given, computed)
                        + EffortFeasibility.sentence(zone: cleanZone, minutes: Double(cleanDuration), range: range)
                        + " State \(Int(computed.rounded())), not \(Int(given.rounded()))."
                } else {
                    correction = EffortFeasibility.sentence(zone: cleanZone,
                                                            minutes: Double(cleanDuration), range: range)
                }
                effort = computed
            }
        }

        let proposal = PlanProposal(day: dayKey, time: when, sport: trimmedSport,
                                    intent: parsedIntent,
                                    targetEffort: effort,
                                    zone: cleanZone, durationMin: cleanDuration,
                                    rationale: rationale,
                                    goalIds: requestedGoals)
        guard CoachPlanStore.shared.propose(proposal) else {
            // The user already has this exact session committed for that day (their own routine, or a
            // proposal they accepted) — the store refused the duplicate (#P7 9.8/10.5). Tell the model so
            // it acknowledges what's already there instead of re-pitching it.
            return "Not proposed: the user already has \(trimmedSport) committed for \(dayKey). "
                + "Acknowledge their existing plan rather than suggesting it again as if it were new."
        }
        CoachNotifier.postPlanProposal(proposal)
        let adapted = adaptation.evidenceNote.map { " Local adaptation: \($0)" } ?? ""
        let effortNote = correction.map { " \($0)" } ?? ""
        return "Proposed (NOT scheduled): \(proposal.contextSummary()) on \(dayKey).\(adapted)\(effortNote) "
            + "It's waiting for the user to accept, change or decline it in the app — tell them it's "
            + "there for their yes, and don't refer to it as booked."
    }

    /// The resting HR to reason about a PLANNED session with: the median of the recent daily readings,
    /// matching `AnalyticsEngine`'s own `restForStrain`, so a projection and the eventual score share a
    /// denominator. Falls back to `StrainScorer.defaultRestingHR` before any night is banked.
    func recentRestingHR() async -> Double {
        let recent = repo.days.suffix(14).compactMap { $0.restingHr }.sorted()
        guard !recent.isEmpty else { return StrainScorer.defaultRestingHR }
        return Double(recent[recent.count / 2])
    }

    /// `get_session_outlook`: what a session costs THIS user, and what swapping would change.
    func sessionOutlookTool(sport: String, swapFrom: String?,
                            plannedEffort: Double?, plannedSleepHours: Double?) async -> String {
        let trimmed = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Name the activity to size up." }
        let inputs = await planInputs()
        if let from = swapFrom?.trimmingCharacters(in: .whitespacesAndNewlines), !from.isEmpty {
            return PlanConsequence.compare(from: from, fromEffort: plannedEffort,
                                           to: trimmed, toEffort: plannedEffort,
                                           plannedSleepHours: plannedSleepHours,
                                           inputs: inputs).sentence()
        }
        return PlanConsequence.outlook(sport: trimmed, plannedEffort: plannedEffort,
                                       plannedSleepHours: plannedSleepHours,
                                       inputs: inputs).sentence()
    }

    /// `simulate_day`: the what-if. Returns an honest "not enough history" rather than a made-up number.
    func simulateDayTool(effort: Double?, sleepHours: Double?) async -> String {
        guard let sleepHours else { return "Tell me how many hours you plan to sleep and I'll project it." }
        let inputs = await planInputs()
        return PlanConsequence.simulate(todayEffort: effort.map { max(0, min($0, 100)) },
                                        plannedSleepHours: max(0, sleepHours),
                                        inputs: inputs)
            ?? "There isn't enough recent Charge history to project tomorrow honestly yet."
    }

    func refreshVO2maxDisplay() async {
        activeEnergyByDay = await repo.activeEnergyByDay(days: 31)
        let estimates = await repo.exploreSeries(key: "vo2max_est", source: Repository.whoopSource, days: 90)
            .map { VO2maxReading(day: $0.day, value: $0.value, segment: "vo2max_est") }
        let apple = await repo.exploreSeries(key: "vo2max", source: Repository.appleHealthSource, days: 365)
            .map { VO2maxReading(day: $0.day, value: $0.value, segment: Repository.appleHealthSource) }
        vo2maxDisplay = CardioEvidence.display(estimates: estimates, apple: apple,
                                               through: Repository.logicalDayKey(Date()))
    }

    /// The headline VO₂max value, or nil when neither source has one.
    private func estimatedVO2max() -> Double? {
        vo2maxDisplay?.primary?.value
    }

    /// Gather what the app can actually measure about the user's starting point, for the feasibility
    /// check. Every field degrades to nil rather than guessing. VO₂max is the value the screens show
    /// (`vo2maxDisplay`) — reported as context, never used to predict.
    func goalEvidence() async -> GoalFeasibility.Evidence {
        let days = repo.days
        var evidence = GoalFeasibility.Evidence()

        // VO₂max (context only): the value the screens show.
        await refreshVO2maxDisplay()
        evidence.vo2max = estimatedVO2max()

        // Running base + weekly session count, from the last 30 days of workouts.
        let rows = await repo.workoutRows(days: 30)
        let runDistances = rows
            .filter { $0.sport.lowercased().contains("run") }
            .compactMap { $0.distanceM }
            .map { $0 / 1000 }
        if let longest = runDistances.max(), longest > 0 { evidence.longestRecentRunKm = longest }
        if !rows.isEmpty { evidence.sessionsPerWeek = Double(rows.count) / (30.0 / 7.0) }

        // Recent mean sleep.
        let sleeps = days.suffix(14).compactMap { $0.totalSleepMin }
        if !sleeps.isEmpty {
            evidence.meanSleepHours = (sleeps.reduce(0, +) / Double(sleeps.count)) / 60
        }

        // Working sets per week, over the same window goal tracking measures a set goal in. Nil rather
        // than zero when no lifting log is connected: "I can't see one" and "you did none" are different
        // answers, and only the second one deserves a verdict.
        // The canonical read model, not one source: a wearer who logs only in NOOP must not read as
        // "no lifting log", and a session recorded natively AND imported must not count twice.
        let strengthHistory = await repo.resolvedStrengthHistory(days: GoalMeasure.hardSetWindowDays)
        if !strengthHistory.workouts.isEmpty {
            let sets = strengthHistory.workouts
                .map { StrengthSession.summarize($0, templates: strengthHistory.templates).workingSetCount }
                .reduce(0, +)
            evidence.hardSetsPerWeek = GoalMeasure.perWeek(count: sets,
                                                           overDays: GoalMeasure.hardSetWindowDays)
        }
        return evidence
    }

    /// Today's date, weekday and rough time of day, so the coach is never guessing what "today" means —
    /// the historical gap that let it not know a workout was 5 days ago or that it's a rest day of the week.
    ///
    /// Internal rather than private because `toolModeContext` (`CoachTools.swift`) needs it too: the tool
    /// path used to carry NO clock at all, so a relative question ("what did I ask you yesterday?") had
    /// nothing to resolve "yesterday" against. Deliberately NOT in the system prompt — that block carries
    /// Anthropic's `cache_control` breakpoint, and a time-of-day string that changes every request would
    /// invalidate the prefix cache on every single turn.
    func clockLine() -> String {
        let now = Date()
        let df = DateFormatter()
        df.dateFormat = "EEEE, yyyy-MM-dd"
        let hour = Calendar.current.component(.hour, from: now)
        let partOfDay: String
        switch hour {
        case 0..<5: partOfDay = "late night"
        case 5..<12: partOfDay = "morning"
        case 12..<17: partOfDay = "afternoon"
        case 17..<21: partOfDay = "evening"
        default: partOfDay = "night"
        }
        return "Right now: \(df.string(from: now)), \(partOfDay)."
    }

    /// Whole days between `ts` (unix seconds) and now, using calendar day boundaries (not a raw 24h
    /// division), so "yesterday evening" reads as 1 day ago rather than 0.
    func daysAgo(_ ts: Int) -> Int {
        Self.daysAgo(Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// The same calendar-day arithmetic for a `Date`. Static and pure so the recall tests can pin the
    /// "yesterday means 1, not 24 hours" behaviour without an engine. `now` is injectable for the same
    /// reason — a test that builds "yesterday" relative to a fixed clock can't flake at midnight.
    static func daysAgo(_ date: Date, now: Date = Date()) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day],
                                  from: cal.startOfDay(for: date),
                                  to: cal.startOfDay(for: now)).day ?? 0
    }
}
