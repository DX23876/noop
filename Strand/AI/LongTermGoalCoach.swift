import Foundation
import StrandAnalytics

/// What the coach learns about a catalog goal, and what it may draft from one. English and in code,
/// like the rest of the coach context: the figures are the reading the page shows, handed over as
/// computed facts so the model never derives its own.
extension LongTermMetric {
    /// The unit the context writes values in.
    var coachUnit: String {
        switch self {
        case .distanceTotal, .longestDistance: return "km"
        case .minutesTotal: return "min"
        case .workoutsTotal: return "workouts"
        case .stepsTotal: return "steps"
        case .paceAverage: return "s/km"
        case .hrvAverage: return "ms"
        case .sleepAverage: return "h"
        case .recoveryAverage, .bodyFat: return "%"
        case .weight, .leanMass: return "kg"
        case .waist: return "cm"
        case .vo2max: return "ml/kg/min"
        case .restingHr: return "bpm"
        case .weeklyAdherence: return "share of weeks"
        }
    }
}

extension GoalShapeReading {
    /// One line of facts for the coach: the numbers of this goal's page, nothing interpreted.
    func coachFacts() -> String {
        func n(_ value: Double) -> String { String(format: "%g", (value * 10).rounded() / 10) }
        func day(_ date: Date?) -> String? { date.map { Repository.localDayKey($0) } }
        switch self {
        case .sum(let d):
            let r = d.reading
            let u = d.metric.coachUnit
            var parts = ["collected \(n(r.total)) of \(n(r.target)) \(u) (\(Int((r.fraction * 100).rounded())) %)",
                         "planned by now \(n(r.plannedByNow)) \(u)",
                         "\(n(r.weeksLeft)) weeks left"]
            if let need = r.neededPerWeek { parts.append("needs \(n(need)) \(u) a week") }
            if let recent = r.recentWeeklyAverage { parts.append("recent average \(n(recent)) \(u) a week") }
            parts.append("this week \(n(d.thisWeek)) \(u)")
            parts.append("state \(r.state.rawValue)")
            return parts.joined(separator: "; ")
        case .target(let d):
            let u = d.metric.coachUnit
            var parts = ["now \(n(d.current)) \(u) (start \(n(d.baseline)), target \(n(d.target)))",
                         "progress \(Int((d.progress * 100).rounded())) %"]
            if let rate = d.ratePerWeek { parts.append("trend \(n(rate)) \(u) a week") }
            if let next = d.milestones?.next {
                parts.append("next mark \(n(next)) \(u)" + (day(d.nextMarkDate).map { " around \($0)" } ?? ""))
            }
            if let arrival = day(d.arrivalDate) { parts.append("target around \(arrival) at this pace") }
            if d.isProvisional { parts.append("few readings so far: provisional") }
            parts.append("state \(d.state?.rawValue ?? "running, no direction yet")")
            return parts.joined(separator: "; ")
        case .best(let d):
            let r = d.reading
            var parts = ["best since the start \(r.best.map { "\(n($0)) km" } ?? "none yet")"]
            if let recent = r.recentBest { parts.append("longest of the last four weeks \(n(recent)) km") }
            if let earlier = r.earlierBest { parts.append("best before the goal \(n(earlier)) km") }
            if let fraction = r.fraction { parts.append("\(Int((fraction * 100).rounded())) % of the target") }
            if let weekly = d.recentWeeklyDistance { parts.append("\(n(weekly)) km a week lately") }
            parts.append("state \(r.state?.rawValue ?? "no date to plan against")")
            return parts.joined(separator: "; ")
        case .consistency(let d):
            let r = d.reading
            var parts = ["weekly goal \(n(d.weeklyTarget)) \(d.weeklyMetric.rawValue) a week, this week \(n(d.thisWeek))",
                         "kept \(r.hit) of \(r.evaluated) judged weeks"
                            + (r.share.map { " (\(Int(($0 * 100).rounded())) %, on track from \(Int((d.adherenceTarget * 100).rounded())) %)" } ?? ""),
                         "streak \(r.currentStreak) weeks, best \(r.bestStreak)",
                         "last weeks " + d.lastWeeks.map(\.rawValue).joined(separator: ",")]
            if let average = d.averagePerWeek { parts.append("average \(n(average)) a week") }
            parts.append("state \(r.state.rawValue)")
            return parts.joined(separator: "; ")
        case .average(let d):
            let r = d.reading
            let u = d.metric.coachUnit
            var parts = ["28-day average \(r.mean.map { "\(n($0)) \(u)" } ?? "not enough readings")",
                         "target \(n(d.target)) \(u) (\(d.higherIsBetter ? "higher" : "lower") is better)",
                         "at target \(r.atTarget) of \(r.values)"]
            if let trend = r.trendPerMonth { parts.append("trend \(n(trend)) \(u) a month") }
            parts.append("state \(r.state.rawValue)")
            return parts.joined(separator: "; ")
        case .maintain(let d):
            let r = d.reading
            let u = d.metric.coachUnit
            var parts = ["band \(n(d.center)) ± \(n(d.band)) \(u)"]
            if let latest = r.latest { parts.append("latest \(n(latest)) \(u)") }
            if let share = r.inBandShare { parts.append("\(Int((share * 100).rounded())) % of \(r.readings) readings in the band") }
            if let spread = r.spread { parts.append("swing \(n(spread)) \(u)") }
            parts.append("state \(r.state.rawValue)")
            return parts.joined(separator: "; ")
        }
    }

    /// What reading this goal's numbers shares with the provider, for the tip card's consent check.
    var dataPurposes: Set<CoachPurpose> {
        switch self {
        case .sum, .best, .consistency: return [.workouts]
        case .target, .average, .maintain: return [.coreBiometrics]
        }
    }
}

/// Catalog goals the coach may draft. The draft becomes the same goal the setup screen makes: the
/// template's kind and measure, and for a weekly rhythm the weekly goal that measures it.
enum CatalogGoalDraft {
    struct Made {
        let goal: CoachGoal
        /// The weekly goal a consistency template is measured by; it must be confirmed with the goal.
        let weekly: PeriodGoal?
    }

    /// Templates the coach can draft. Hydration needs the drinking log and "Active days" a weekly metric
    /// of its own, so both stay with the setup screen.
    static var draftable: [GoalTemplateID] {
        GoalCatalog.all.filter(\.inWalkthrough).map(\.id).filter { $0 != .hydration }
    }

    struct Input {
        var target: Double?
        var baseline: Double?
        var targetDate: Date?
        var countFrom: Date?
        var sports: [String] = []
        var band: Double?
        var fixedWeeks: Int?
        var journalQuestion: String?
        var wantsYes: Bool = true
        var title: String?
    }

    /// Builds the goal, or says in one line what is missing so the coach can fix the call.
    static func make(_ id: GoalTemplateID, _ input: Input, now: Date = Date()) -> Result<Made, CatalogDraftError> {
        guard draftable.contains(id), let template = GoalCatalog.template(id) else {
            return .failure(.init("template \(id.rawValue) cannot be drafted by the coach"))
        }
        guard let target = input.target, target > 0 else {
            return .failure(.init("template \(id.rawValue) needs a positive target"))
        }
        let goalId = UUID()
        var spec = GoalMeasureSpec(metric: id.metric, sportFilter: input.sports)
        var baseline = input.baseline
        var date = input.targetDate
        var weekly: PeriodGoal?
        switch template.shape {
        case .sum:
            guard let end = input.targetDate, end > now else {
                return .failure(.init("a collect goal needs a target_date in the future"))
            }
            spec.countFrom = input.countFrom
            baseline = 0
            date = end
        case .target:
            guard let start = baseline else {
                return .failure(.init("template \(id.rawValue) needs the measured starting value as baseline"))
            }
            guard start != target else { return .failure(.init("baseline and target are the same")) }
        case .maintain:
            spec.band = max(0.5, min(input.band ?? 1, 5))
            date = nil
        case .best:
            if id == .event, date == nil { return .failure(.init("a race goal needs its race day as target_date")) }
        case .average:
            date = nil
        case .consistency:
            guard let metric = id.weeklyMetric else {
                return .failure(.init("template \(id.rawValue) has no weekly measure yet"))
            }
            var habitKey: String?
            if metric == .habitDays {
                guard let question = input.journalQuestion?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !question.isEmpty else {
                    return .failure(.init("a journal habit goal needs journal_question copied from the journal"))
                }
                habitKey = question
            }
            let maxPerWeek: Double = metric == .stepDays || metric == .sleepNights || metric == .restDays
                || metric == .habitDays ? 7 : 10_000
            let weeklyTarget = min(target, maxPerWeek)
            weekly = PeriodGoal(metric: metric, period: .week, target: weeklyTarget,
                                threshold: metric.defaultThreshold,
                                sportFilter: metric == .workouts ? input.sports : [],
                                habitKey: habitKey, habitWantsYes: input.wantsYes, parentGoalId: goalId)
            baseline = nil
            spec.weeklyGoalId = weekly?.id
            spec.adherenceWeeks = LongTermGoalMath.adherenceWindowWeeks
            spec.adherenceTarget = LongTermGoalMath.adherenceTarget
            if let weeks = input.fixedWeeks, weeks > 0 {
                spec.fixedEnd = now.addingTimeInterval(Double(min(weeks, 104)) * 7 * 86_400)
            }
            date = spec.fixedEnd
        }
        let name = input.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let goal = CoachGoal(id: goalId, kind: id.kind,
                             title: name.isEmpty ? template.title.localizedCatalogValue : name,
                             baseline: baseline, target: target, targetDate: date,
                             templateId: id.rawValue, measure: spec)
        return .success(.init(goal: goal, weekly: weekly))
    }
}

struct CatalogDraftError: Error {
    let description: String
    init(_ description: String) { self.description = description }
}

extension CoachGoalStore {
    /// An active goal that measures what `draft` would: the same metric over the same sports, and for a
    /// weekly rhythm the same weekly measure. Several goals of one area are fine (VO2max beside HRV);
    /// only measuring one thing twice is worth a question.
    func activeGoal(measuringLike draft: CoachGoal, weeklyMetric: PeriodMetric?) -> CoachGoal? {
        guard let measure = draft.measure else { return nil }
        return activeGoals.first { goal in
            guard goal.id != draft.id, let other = goal.measure, other.metric == measure.metric,
                  Set(other.sportFilter.map { $0.lowercased() }) == Set(measure.sportFilter.map { $0.lowercased() })
            else { return false }
            guard let weeklyMetric else { return true }
            return other.weeklyGoalId.flatMap { id in PeriodGoalStore.shared.goals.first { $0.id == id } }?
                .metric == weeklyMetric
        }
    }
}

/// The tip on a catalog goal's page: two sentences from the cheap coach model with the goal's own
/// figures, kept until the next day or until the goal's state changes, so opening the page twice does
/// not spend a second request. Only with the coach on, a connection, data sharing and the purposes the
/// figures draw on.
@MainActor
final class LongTermGoalTipStore: ObservableObject {
    static let shared = LongTermGoalTipStore()

    struct Tip: Codable, Equatable {
        let text: String
        let day: String
        let state: String
    }

    @Published private(set) var tips: [UUID: Tip] = [:]
    private var inFlight: Set<UUID> = []
    private let key = "goals.longTermTips.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Tip].self, from: data) {
            tips = Dictionary(uniqueKeysWithValues: decoded.compactMap { k, v in UUID(uuidString: k).map { ($0, v) } })
        }
    }

    /// The tip to show now: today's, for the state the goal is in.
    func current(for goalId: UUID, state: String) -> Tip? {
        guard let tip = tips[goalId], tip.day == Repository.localDayKey(Date()), tip.state == state else { return nil }
        return tip
    }

    static func allowed(_ reading: GoalShapeReading, coach: AICoachEngine) -> Bool {
        CoachFeaturePrefs.isEnabled && coach.isConfigured && coach.dataConsent
            && reading.dataPurposes.isSubset(of: coach.toolConsent.enabled)
    }

    func refreshIfNeeded(goal: CoachGoal, reading: GoalShapeReading, coach: AICoachEngine) async {
        let state = reading.state?.rawValue ?? "none"
        guard Self.allowed(reading, coach: coach), current(for: goal.id, state: state) == nil,
              !inFlight.contains(goal.id) else { return }
        inFlight.insert(goal.id)
        defer { inFlight.remove(goal.id) }
        let user = Self.userTurn(goal: goal, reading: reading)
        guard let reply = await coach.cheapComplete(system: Self.system(coach: coach), user: user, role: .cardAnalysis)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !reply.isEmpty else { return }
        tips[goal.id] = Tip(text: reply, day: Repository.localDayKey(Date()), state: state)
        persist()
    }

    private func persist() {
        let encoded = Dictionary(uniqueKeysWithValues: tips.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) { UserDefaults.standard.set(data, forKey: key) }
    }

    static func system(coach: AICoachEngine) -> String {
        coach.persona.systemPreamble + "\n\n" + """
        You write the tip on one long-term goal's page. Two short sentences at most: what the figures \
        say about where the goal stands, then one concrete thing for this week. Use only the figures you \
        are given, never invent numbers, and do not repeat every figure back. No lists, no headings, no \
        greeting. Not medical advice.
        """ + "\n\n" + CoachReplyLanguage.current.promptClause
    }

    static func userTurn(goal: CoachGoal, reading: GoalShapeReading) -> String {
        "Goal \"\(goal.title)\" (template \(goal.templateId ?? "none")). Figures: \(reading.coachFacts())."
    }

    /// Opening the coach from the tip: the goal as the topic, with the same figures.
    static func cardContext(goal: CoachGoal, reading: GoalShapeReading) -> CoachCardContext {
        CoachCardContext(title: goal.title, summary: reading.coachFacts(),
                         suggestions: [String(localized: "What should this week look like?"),
                                       String(localized: "Is my target realistic?")],
                         requiredPurposes: reading.dataPurposes)
    }
}
