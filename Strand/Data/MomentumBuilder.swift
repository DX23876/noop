import Foundation
import StrandAnalytics
import StrandDesign
import WhoopStore

/// Turns what the Today screen already holds into `MomentumMessage` candidates.
///
/// The split with `MomentumFeed` is deliberate: the feed decides ORDER and knows no text, this decides
/// WHETHER THERE IS ANYTHING TO SAY and writes the words. Both halves are pure — every input arrives as
/// a plain value, so the whole thing is testable without a screen, a strap or a database.
///
/// Two rules run through all of it:
///
/// 1. **No invented numbers.** A candidate is only produced when its number is real. No step goal and no
///    measured step count means no step message — not a message against a guess. This is the same line
///    `GoalMilestones` draws when it refuses to turn a plan into a score.
/// 2. **Urgency is "is there a candidate", not a permanently high tier.** `weeklyTrainingGoal` sits in
///    the time-critical tier, so it is only emitted when the week is genuinely running out. Emitting it
///    every day would park it at the top of the card all week and kill the daily rotation.
enum MomentumBuilder {

    /// Everything the builder needs, as plain values. Anything the caller cannot supply stays nil and
    /// simply produces no candidate of that kind.
    struct Inputs {
        /// The day being shown (today, or a navigated past day).
        var day: DailyMetric?
        /// Recent daily rows, oldest→newest, for baselines / streaks / consecutive-day reads.
        var recentDays: [DailyMetric] = []
        /// The local day key of the day being shown.
        var dayKey: String = ""
        /// True when a past day is being shown; actionable messages are dropped downstream.
        var isToday: Bool = true

        /// The fixed statement for an explicit sick / injured / on-break status, when one is set.
        var statusOverride: BaseCardStatement?
        /// The calibration headline + detail while the baseline is still forming.
        var calibration: (headline: String, detail: String)?

        /// The existing recovery read (headline + detail), already localized by the caller. Passing the
        /// SAME copy the card showed before keeps this a re-presentation rather than a rewrite.
        var recoveryRead: (headline: String, detail: String)?
        /// Today's HRV against the learned baseline, in whole percent.
        var hrvDeltaPct: Int?

        /// Today's MEASURED step count. A strap-derived estimate must not be passed here — see
        /// `stepsAreEstimated`.
        var measuredSteps: Int?
        /// True when the only step figure available is the strap estimate, which is honest enough for a
        /// qualitative read but not for "2,340 to go".
        var stepsAreEstimated: Bool = false
        /// The user's daily step goal, when they set one.
        var stepGoal: Int?
        /// The wearer's own typical daily steps (median of recent days).
        var typicalSteps: Int?

        /// Nightly sleep hours over the recent week and the personal need, for the catch-up read.
        var weekSleepHours: [Double] = []
        var sleepNeedHours: Double?

        /// Sessions still owed this week and how many days remain to do them in.
        var weekSessionsPlanned: Int?
        var weekSessionsDone: Int?
        var daysLeftInWeek: Int?

        /// The next goal waypoint: what it is called, its value text, and whether it is a weight goal.
        var nextMilestone: (goal: String, value: String, isWeight: Bool)?

        /// Consecutive days meeting a goal, from `StreakCalculator`.
        var streakDays: Int?

        /// Consecutive straining days immediately before/including today.
        var strainingDaysInARow: Int?

        /// A session committed for TODAY that has not been recorded yet, by its title. nil when nothing
        /// is planned or the planned session is already done.
        var openPlannedSessionToday: String?

        /// The week's Effort so far against this wearer's own typical week, 0...1+. Feeds the
        /// "good day to push" read, which must not fire in the middle of a hard week.
        var weekLoadRatio: Double?

        /// The raised strain / illness early-warning, already localized by the caller (the SAME copy the
        /// Today banner renders, so the two cannot describe one alert two ways). nil when none is raised.
        var healthAlertCopy: String?

        /// Hours of strap runtime left on the current discharge, and the local hour the feed is being
        /// built at. Both are needed to decide whether the strap will still be recording at wake-up;
        /// either being nil simply produces no candidate.
        var strapHoursRemaining: Double?
        var hourOfDay: Int?

        /// The current menstrual-cycle phase name and its day range, already localized. nil unless cycle
        /// tracking is on and a phase has been resolved.
        var cyclePhaseTitle: String?
        var cycleDayRange: String?
    }

    // MARK: - Entry point

    /// Every candidate that has something real to say, in no particular order — `MomentumFeed.rank`
    /// decides which one leads.
    static func candidates(_ i: Inputs) -> [MomentumMessage] {
        var out: [MomentumMessage] = []
        appendOverrides(i, into: &out)
        appendHealthAlert(i, into: &out)
        appendRecovery(i, into: &out)
        appendTraining(i, into: &out)
        appendActivity(i, into: &out)
        appendSleepAction(i, into: &out)
        appendStrapBattery(i, into: &out)
        appendProgress(i, into: &out)
        appendCycle(i, into: &out)
        return out
    }

    // MARK: - Tier 1 — something is wrong now, or a window closes tonight

    /// The strain / illness early-warning. Momentum had no channel for it: the only surface was the
    /// Today banner, so the feed could be leading with a step goal while the app had decided something
    /// looked wrong. The copy is the caller's — the SAME string the banner renders — so the two cannot
    /// describe one alert two ways.
    private static func appendHealthAlert(_ i: Inputs, into out: inout [MomentumMessage]) {
        guard i.isToday, let copy = i.healthAlertCopy else { return }
        out.append(MomentumMessage(
            kind: .healthAlert, tone: .critical,
            headline: String(localized: "Your body looks strained"),
            detail: copy,
            actionLine: String(localized: "Favour rest today, and treat any plan as optional.")))
    }

    /// Tonight's lights-out target. `sleepCatchUp` names the debt; this names the action that clears it,
    /// using the SAME owed-minutes figure and the same "keep it doable" shift (`bedtimeShiftMinutes`),
    /// so the two can never disagree about how much is owed.
    ///
    /// Evening and night only: "lights out by 22:40" at nine in the morning is noise, not advice.
    private static func appendSleepAction(_ i: Inputs, into out: inout [MomentumMessage]) {
        guard i.isToday, let hour = i.hourOfDay, hour >= 18 || hour < 4,
              let owed = sleepOwedMinutes(i) else { return }
        let shift = bedtimeShiftMinutes(owed)
        out.append(MomentumMessage(
            kind: .bedtimeTarget, tone: .neutral,
            headline: String(localized: "Turn in \(shift) minutes earlier tonight"),
            detail: String(localized: "You are \(durationText(owed)) short against your own need this week."),
            actionLine: String(localized: "One earlier night, not the whole debt at once.")))
    }

    /// The strap will not last the night. A battery percentage is not news — a night about to be missed
    /// is, which is why this is emitted only when the remaining runtime cannot cover a normal night's
    /// sleep from now. Evening and night only, for the same reason: it is an actionable job at bedtime.
    private static func appendStrapBattery(_ i: Inputs, into out: inout [MomentumMessage]) {
        guard i.isToday, let hours = i.strapHoursRemaining, hours.isFinite, hours > 0,
              let hour = i.hourOfDay, hour >= 18 || hour < 4,
              hours < nightRuntimeHours else { return }
        out.append(MomentumMessage(
            kind: .strapBattery, tone: .caution,
            headline: String(localized: "Charge the strap before bed"),
            detail: String(localized: "About \(Int(hours.rounded())) hours left — not enough to record tonight."),
            actionLine: String(localized: "A short charge now keeps the night's data.")))
    }

    /// The runtime a night needs to be recorded end to end: a night's sleep plus the evening before it.
    /// Deliberately generous — waking to a strap that died at 03:00 loses the night either way.
    static let nightRuntimeHours: Double = 10

    // MARK: - Tier 5 — context that is true of the day being read

    private static func appendCycle(_ i: Inputs, into out: inout [MomentumMessage]) {
        guard let title = i.cyclePhaseTitle else { return }
        out.append(MomentumMessage(
            kind: .cyclePhase, tone: .neutral,
            headline: title,
            detail: i.cycleDayRange ?? String(localized: "Cycle phase, estimated on device.")))
    }

    // MARK: - Tier 0 — what the user told us, and the honest "not yet"

    private static func appendOverrides(_ i: Inputs, into out: inout [MomentumMessage]) {
        if let s = i.statusOverride {
            out.append(MomentumMessage(
                kind: .statusOverride, tone: .neutral,
                headline: s.headline, detail: s.summary))
        }
        if let c = i.calibration {
            out.append(MomentumMessage(
                kind: .calibrating, tone: .neutral,
                headline: c.headline, detail: c.detail))
        }
    }

    // MARK: - Tier 3 — recovery, and tier 5 — its trend

    private static func appendRecovery(_ i: Inputs, into out: inout [MomentumMessage]) {
        if let r = i.recoveryRead {
            let score = i.day?.recovery
            out.append(MomentumMessage(
                kind: .recoveryRead,
                tone: score.map(tone(forCharge:)) ?? .neutral,
                headline: r.headline,
                detail: r.detail,
                actionLine: score.flatMap(recoveryActionLine),
                progress: score.map { MomentumProgress(fraction: $0 / 100, label: "\(Int($0.rounded())) / 100") },
                deltaText: i.hrvDeltaPct.map { $0 >= 0 ? "+\($0)%" : "\($0)%" },
                action: MomentumAction(title: String(localized: "See what shaped it"),
                                       destination: .chargeBreakdown)))
        }

        // A multi-day direction is worth more than a single morning's number, so it is its own message
        // rather than a clause inside the recovery read.
        if let run = hrvRun(i), run.days >= 3 {
            out.append(MomentumMessage(
                kind: .hrvTrend,
                tone: run.above ? .positive : .caution,
                headline: run.above
                    ? String(localized: "Your HRV has been above baseline for \(run.days) days")
                    : String(localized: "Your HRV has been below baseline for \(run.days) days"),
                detail: run.above
                    ? String(localized: "Your recovery is trending in the right direction.")
                    : String(localized: "Your body is carrying something — load, sleep debt or illness.")))
        }
    }

    // MARK: - Tier 1 / 3 — training

    private static func appendTraining(_ i: Inputs, into out: inout [MomentumMessage]) {
        // Only when the week is genuinely running out (see the note at the top of the file). "2 of 3
        // done, four days left" is a progress note, not something to lead the screen with.
        if let planned = i.weekSessionsPlanned, let done = i.weekSessionsDone,
           let daysLeft = i.daysLeftInWeek, planned > 0, done < planned, daysLeft <= 2 {
            let missing = planned - done
            out.append(MomentumMessage(
                kind: .weeklyTrainingGoal,
                tone: daysLeft <= 1 ? .caution : .neutral,
                headline: missing == 1
                    ? String(localized: "One session short of your week")
                    : String(localized: "\(missing) sessions short of your week"),
                detail: String(localized: "You've done \(done) of \(planned) this week."),
                actionLine: daysLeft <= 1
                    ? String(localized: "Today is the last day to close it.")
                    : String(localized: "\(daysLeft) days left."),
                progress: MomentumProgress(fraction: Double(done) / Double(planned),
                                           label: "\(done) / \(planned)"),
                action: MomentumAction(title: String(localized: "View goal"), destination: .goalJourney)))
        }

        // A session the user COMMITTED to today, still unrecorded. Time-critical by nature: it expires
        // at midnight, which is exactly what that tier is for.
        if i.isToday, let planned = i.openPlannedSessionToday {
            out.append(MomentumMessage(
                kind: .planDeviation, tone: .caution,
                headline: String(localized: "\(planned) is still open"),
                detail: String(localized: "You planned it for today and nothing has been recorded yet."),
                actionLine: String(localized: "Start it, or move it in your plan."),
                action: MomentumAction(title: String(localized: "Open plan"), destination: .plan)))
        }

        // "Today looks like a good training day" — but ONLY when both halves hold. Recovery alone would
        // tell someone to push in the middle of an already-heavy week, which is how a training app talks
        // people into digging a hole. It also stays quiet when a rest day is being urged, so the screen
        // cannot advise two opposite things at once.
        if i.isToday, let score = i.day?.recovery, ChargeBand.of(score: score) == .primed || ChargeBand.of(score: score) == .peak,
           let load = i.weekLoadRatio, load <= 1.0, (i.strainingDaysInARow ?? 0) < 3 {
            out.append(MomentumMessage(
                kind: .trainingSuggestion, tone: .positive,
                headline: String(localized: "Today looks like a good training day"),
                detail: String(localized: "Recovery is high and this week's load is still moderate."),
                actionLine: String(localized: "A harder session is well supported today."),
                action: MomentumAction(title: String(localized: "Start a session"),
                                       destination: .liveSession)))
        }

        // Several straining days in a row is the one read here that says something is WRONG, so it
        // carries the critical tone that lets it interrupt (see `MomentumFeed.criticalBonus`).
        if let run = i.strainingDaysInARow, run >= 3 {
            out.append(MomentumMessage(
                kind: .restDayNeeded, tone: .critical,
                headline: String(localized: "\(run) straining days in a row"),
                detail: String(localized: "Load has been high without a real break."),
                actionLine: String(localized: "An easy day would serve you better than another hard one.")))
        }
    }

    // MARK: - Tier 4 — how the day is actually going

    private static func appendActivity(_ i: Inputs, into out: inout [MomentumMessage]) {
        guard i.isToday else { return }

        // A remaining-count needs a MEASURED figure. On the strap estimate we can still say something
        // true — just not a number to chase.
        if let steps = i.measuredSteps, !i.stepsAreEstimated, let goal = i.stepGoal, goal > 0 {
            let remaining = goal - steps
            if remaining > 0 {
                out.append(MomentumMessage(
                    kind: .stepGoal, tone: .neutral,
                    headline: String(localized: "\(remaining) steps to your goal"),
                    detail: String(localized: "You're at \(steps) of \(goal) today."),
                    actionLine: String(localized: "About \(walkMinutes(remaining)) min of walking would do it."),
                    progress: MomentumProgress(fraction: Double(steps) / Double(goal),
                                               label: "\(steps) / \(goal)")))
            } else {
                out.append(MomentumMessage(
                    kind: .stepGoal, tone: .positive,
                    headline: String(localized: "Step goal reached"),
                    detail: String(localized: "\(steps) steps today, past your goal of \(goal)."),
                    progress: MomentumProgress(fraction: 1, label: "\(steps) / \(goal)")))
            }
            return   // one activity message is enough; the goal read is the more concrete one
        }

        // No goal set — compare against the wearer's OWN normal instead of inventing a target. This is
        // also the only activity read a strap ESTIMATE is honest enough for, so it is not gated on
        // `stepsAreEstimated`.
        if let steps = i.measuredSteps ?? nil, let typical = i.typicalSteps, typical > 0,
           Double(steps) < Double(typical) * 0.7 {
            let behind = typical - steps
            out.append(MomentumMessage(
                kind: .stepsBelowUsual, tone: .neutral,
                headline: String(localized: "Quieter day than usual"),
                detail: i.stepsAreEstimated
                    ? String(localized: "You're tracking below your normal daily movement.")
                    : String(localized: "About \(behind) steps below your normal day."),
                progress: i.stepsAreEstimated
                    ? nil
                    : MomentumProgress(fraction: Double(steps) / Double(typical),
                                       label: "\(steps) / \(typical)")))
        }

        if let owed = sleepOwedMinutes(i), owed >= 30 {
            out.append(MomentumMessage(
                kind: .sleepCatchUp, tone: .caution,
                headline: String(localized: "You're short on sleep this week"),
                detail: String(localized: "About \(durationText(owed)) behind your nightly need."),
                actionLine: String(localized: "Turning in \(bedtimeShiftMinutes(owed)) min earlier tonight would start closing it.")))
        }
    }

    // MARK: - Tier 2 / 5 — waypoints and streaks

    private static func appendProgress(_ i: Inputs, into out: inout [MomentumMessage]) {
        if let m = i.nextMilestone {
            out.append(MomentumMessage(
                kind: m.isWeight ? .weightMilestone : .milestone,
                tone: .neutral,
                headline: String(localized: "Next up: \(m.value)"),
                detail: String(localized: "The next waypoint on \(m.goal)."),
                action: MomentumAction(title: String(localized: "View goal"), destination: .goalJourney)))
        }
        if let days = i.streakDays, days >= 3 {
            out.append(MomentumMessage(
                kind: .streak, tone: .positive,
                headline: String(localized: "\(days) days in a row"),
                detail: String(localized: "You've hit your goal \(days) days running.")))
        }
    }

    // MARK: - Small pure helpers

    /// Charge band → tone, so the card's colour and the ring's colour come from the SAME banding.
    static func tone(forCharge score: Double) -> MomentumTone {
        switch ChargeBand.of(score: score) {
        case .depleted:            return .critical
        case .low:                 return .caution
        case .moderate:            return .neutral
        case .primed, .peak:       return .positive
        }
    }

    /// What today's Charge means for training, in one line.
    static func recoveryActionLine(_ score: Double) -> String? {
        switch ChargeBand.of(score: score) {
        case .depleted: return String(localized: "Rest is the session today.")
        case .low:      return String(localized: "Keep it easy and short.")
        case .moderate: return String(localized: "Moderate work is well judged.")
        case .primed:   return String(localized: "A harder session fits today.")
        case .peak:     return String(localized: "A good day to push.")
        }
    }

    /// A week's sleep debt in readable units. It was first rendered as raw minutes, which produced
    /// "About 339 min behind" — arithmetically right and useless to read. Hours once it passes one.
    static func durationText(_ minutes: Int) -> String {
        guard minutes >= 60 else { return String(localized: "\(minutes) min") }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? String(localized: "\(h) h") : String(localized: "\(h) h \(m) min")
    }

    /// Rough walking minutes for a step count — a guide, not a measurement, at a plain ~110 steps/min.
    static func walkMinutes(_ steps: Int) -> Int { max(1, Int((Double(steps) / 110).rounded())) }

    /// How much earlier to turn in tonight to start closing a debt: a third of it, capped, so the advice
    /// stays doable. Chasing a whole week's debt in one night is not advice anyone follows.
    static func bedtimeShiftMinutes(_ owedMinutes: Int) -> Int {
        min(60, max(15, Int((Double(owedMinutes) / 3).rounded() / 5) * 5))
    }

    /// Consecutive most-recent days on the same side of the HRV baseline, and which side.
    /// nil when there is not enough history to say.
    static func hrvRun(_ i: Inputs) -> (days: Int, above: Bool)? {
        let values = i.recentDays.compactMap(\.avgHrv).filter { $0 > 0 }
        guard values.count >= 7 else { return nil }
        let baseline = values.reduce(0, +) / Double(values.count)
        guard baseline > 0 else { return nil }
        let recent = Array(values.suffix(14).reversed())
        guard let first = recent.first else { return nil }
        let above = first >= baseline
        var run = 0
        for v in recent {
            guard (v >= baseline) == above else { break }
            run += 1
        }
        return (days: run, above: above)
    }

    /// Minutes of sleep owed against the personal need across the supplied nights. nil when there is no
    /// need to measure against or no nights to measure.
    static func sleepOwedMinutes(_ i: Inputs) -> Int? {
        guard let need = i.sleepNeedHours, need > 0, !i.weekSleepHours.isEmpty else { return nil }
        let owed = i.weekSleepHours.reduce(0.0) { $0 + max(0, need - $1) }
        return owed > 0 ? Int((owed * 60).rounded()) : nil
    }
}

// MARK: - Assembling the inputs

extension MomentumBuilder {

    /// What ONE Today screen supplies. Everything else — medians, sleep need, goals, the plan, the
    /// strain run — is derived identically for both, in `inputs(_:)` below.
    ///
    /// This exists so the classic and the Liquid Today screen can show the SAME card. They hold their
    /// state under different names (`importedStepsDay` vs `appleDays`, `cachedChargeDisplay` vs
    /// `recoveryCalibration`), and letting each assemble its own inputs is how two screens end up
    /// quietly disagreeing about what matters today.
    struct Context {
        var displayDay: DailyMetric?
        /// The carried last-scored day, when today has no score yet.
        var lastScoredDay: DailyMetric?
        var allDays: [DailyMetric] = []
        var dayKey: String = ""
        var isToday: Bool = true
        /// The "Last night · 15 Aug" provenance for a carried read, or nil when the read is today's.
        var carriedCaption: String?
        var calibration: (headline: String, detail: String)?
        var statusOverride: BaseCardStatement?
        /// Today's MEASURED steps (daily row or Apple Health), and separately the strap ESTIMATE. Kept
        /// apart because only the measured one may carry a remaining count.
        var measuredSteps: Int?
        var estimatedSteps: Int?
        var stepGoal: Int = 0
        /// A session committed for today, still unrecorded.
        var openPlannedSessionToday: String?

        /// The raised health alert's copy, the strap's remaining runtime, and the cycle phase — each
        /// supplied as a plain value by the screen. A screen that cannot supply one passes nil and simply
        /// gets no candidate of that kind, which is how a surface without Today's full state stays quiet
        /// rather than wrong.
        var healthAlertCopy: String?
        var strapHoursRemaining: Double?
        var cyclePhaseTitle: String?
        var cycleDayRange: String?
    }

    /// Everything the builder needs, assembled once for either Today screen.
    ///
    /// `@MainActor` because it reads `GoalTrackingStore.shared`, which is main-actor isolated. Both
    /// callers are views, so this costs nothing; the *pure* half (`candidates`) stays actor-free and
    /// keeps being testable without one.
    @MainActor
    static func inputs(_ c: Context) -> Inputs {
        var i = Inputs()

        // ONE row for the whole recovery read — headline, detail, delta and tone (see `MomentumCopy`).
        let subject = MomentumCopy.subjectRow(displayed: c.displayDay, lastScored: c.lastScoredDay)
        i.day = subject
        i.recentDays = c.allDays
        i.dayKey = c.dayKey
        i.isToday = c.isToday
        i.statusOverride = c.statusOverride
        i.calibration = c.calibration
        i.recoveryRead = (
            headline: MomentumCopy.headline(row: subject, allDays: c.allDays, fallbackDayKey: c.dayKey),
            detail: MomentumCopy.detail(row: subject, allDays: c.allDays, fallbackDayKey: c.dayKey,
                                        carriedCaption: c.carriedCaption)
        )
        i.hrvDeltaPct = MomentumCopy.baselineDeltaPct(row: subject, allDays: c.allDays,
                                                      fallbackDayKey: c.dayKey)

        // Steps: prefer a MEASURED figure. The estimate is passed only flagged, so the builder falls
        // back to the qualitative read instead of quoting a remaining count off a guess.
        if let measured = c.measuredSteps {
            i.measuredSteps = measured
        } else if let est = c.estimatedSteps {
            i.measuredSteps = est
            i.stepsAreEstimated = true
        }
        i.stepGoal = c.stepGoal > 0 ? c.stepGoal : nil
        i.typicalSteps = medianSteps(c.allDays.suffix(28).compactMap(\.steps))

        // Sleep: the wearer's OWN need, derived the way the analytics rollup derives it.
        let nightly = c.allDays.suffix(28).compactMap(\.totalSleepMin).map { $0 / 60.0 }.filter { $0 > 0 }
        if nightly.count >= 7 {
            i.sleepNeedHours = AnalyticsEngine.Rest.personalizedNeedHours(nightlyHours: nightly, age: nil)
            i.weekSleepHours = Array(nightly.suffix(7))
        }

        // Goals — the same snapshots the Goals section already draws.
        if let hero = GoalTrackingStore.shared.snapshots.first(where: { $0.goal.status == .active }) {
            i.weekSessionsPlanned = hero.currentWeek.planned
            i.weekSessionsDone = hero.currentWeek.completed
            i.daysLeftInWeek = daysLeftInWeek()
            if let m = hero.nextMilestone {
                i.nextMilestone = (goal: hero.goal.title,
                                   value: "\(Int(m.value.rounded())) \(hero.goal.kind.unit)",
                                   isWeight: hero.goal.kind == .weight)
            }
            if hero.currentStreak > 0 { i.streakDays = hero.currentStreak }
        }

        i.openPlannedSessionToday = c.openPlannedSessionToday
        i.strainingDaysInARow = strainingRun(c.allDays)
        i.weekLoadRatio = weekLoadRatio(c.allDays)

        i.healthAlertCopy = c.healthAlertCopy
        i.strapHoursRemaining = c.strapHoursRemaining
        i.cyclePhaseTitle = c.cyclePhaseTitle
        i.cycleDayRange = c.cycleDayRange
        // The local hour gates the two evening/night messages. Read once here rather than in each
        // branch, so a feed built in one pass cannot straddle a boundary mid-assembly.
        i.hourOfDay = Calendar.current.component(.hour, from: Date())
        return i
    }

    // MARK: - Derivations shared by both screens

    /// Median of a step series — the wearer's own "normal day", robust to one huge hiking day.
    static func medianSteps(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Whole days left in the current week, including today. Drives whether a weekly training goal is
    /// treated as time-critical at all.
    static func daysLeftInWeek(now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return 7 }
        let days = calendar.dateComponents([.day], from: now, to: week.end).day ?? 0
        return max(1, days)
    }

    /// Consecutive most-recent days whose Effort sits in the upper band, as a plain "hard days in a
    /// row" count. Deliberately simple: it exists to say "you have not had a break", not to score.
    static func strainingRun(_ days: [DailyMetric], threshold: Double = 60) -> Int? {
        var run = 0
        for day in days.reversed() {
            guard let strain = day.strain, strain >= threshold else { break }
            run += 1
        }
        return run > 0 ? run : nil
    }

    /// The last seven days' Effort against the mean of the four weeks before them. 1.0 = a normal week
    /// for this person. nil until there is enough history for "normal" to mean anything — without that
    /// gate a new user's first quiet week would read as a licence to push.
    static func weekLoadRatio(_ days: [DailyMetric]) -> Double? {
        let strains = days.compactMap(\.strain)
        guard strains.count >= 28 else { return nil }
        let week = strains.suffix(7)
        let prior = strains.dropLast(7).suffix(28)
        guard !week.isEmpty, prior.count >= 14 else { return nil }
        let weekMean = week.reduce(0, +) / Double(week.count)
        let priorMean = prior.reduce(0, +) / Double(prior.count)
        guard priorMean > 0 else { return nil }
        return weekMean / priorMean
    }
}
