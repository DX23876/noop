import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// Android's reads of Training Load phase 2 (docs/fork/TRAINING_LOAD_PLAN.md §8), the same snapshot the iPhone's
/// `Repository.trainingGuidance` holds: `training.guidance` for Today, the Training tab and the coach,
/// `training.goalReadings` for the Training Load page, `training.instruments` for the Lab card.
@MainActor
enum CoreTrainingGuidance {
    struct Advice: Encodable {
        var stance: String
        var reason: String
        var state: String
        var limitedLane: String?
        /// Today's Effort target on the stored 0 to 100 axis.
        var effortLow: Double?
        var effortHigh: Double?
        var ateTooLittle: Bool
    }

    struct Offer: Encodable {
        /// planned, cardio, strength, easyMovement or startWalk.
        var kind: String
        var title: String?
        var sport: String?
        var minutes: Int?
        var group: String?
        var sets: Int?
    }

    struct Focus: Encodable {
        var focus: String
        var source: String
        var since: String?
        var pause: String?
    }

    struct Week: Encodable {
        var start: String
        var minutes: Int
        var everydayMinutes: Int
        var ratedMinutes: Int
        var strengthDays: Int
        var targetLow: Int
        var targetHigh: Int
        var strengthDaysLow: Int
        var strengthDaysHigh: Int
        var balanceHint: Bool
        var fromOwnGoal: Bool
        var complete: Bool
    }

    struct Food: Encodable {
        var ateTooLittle: Bool
        var ateOverPlan: Bool
        var proteinLow: Bool
        var completeDays: Int
    }

    struct Rating: Encodable {
        var sessionId: String
        var sport: String
        var startTs: Int
        var endTs: Int
    }

    struct Output: Encodable {
        var today: String
        var advice: Advice
        var offers: [Offer]
        var cardioFocus: Focus
        var strengthFocus: Focus
        var weeks: [Week]
        var carried: Bool
        var strengthBand: String?
        var cardioBand: String?
        var askRating: Rating?
        var food: Food
    }

    /// The options Android passes, the same the iPhone reads from its own settings and models.
    static func options(_ args: [String: Any], store: WhoopStore) async -> TrainingGuidanceReader.Options {
        func double(_ k: String) -> Double? { (args[k] as? NSNumber)?.doubleValue }
        var o = TrainingGuidanceReader.Options(
            maxHR: double("maxHR") ?? Double(StrainScorer.defaultMaxHR()), sex: args["sex"] as? String ?? "")
        o.dismissedWorkoutSpans = args["dismissedWorkouts"] as? [String] ?? []
        o.chosenFocus = (args["focus"] as? String).flatMap(TrainingFocus.init(rawValue:))
        o.age = (args["age"] as? NSNumber)?.intValue
        o.pulseUnreliable = args["pulseUnreliable"] as? Bool ?? false
        o.unwell = args["unwell"] as? Bool ?? false
        o.plannedTitle = args["plannedTitle"] as? String
        o.firstWeekday = (args["firstWeekday"] as? NSNumber)?.intValue ?? Calendar.current.firstWeekday
        o.foodGoalKcal = double("foodGoalKcal")
        o.proteinGoalG = double("proteinGoalG")
        o.weightTrendKgPerWeek = double("weightTrendKgPerWeek")
        o.latestWeightKg = double("latestWeightKg")
        if let plan = DietPlan.decode(args["plan"] as? String) {
            o.dietDirection = TrainingGuidanceReader.dietDirection(plan.goal)
            o.dietStartDay = plan.startDay
        }
        o.goals = (try? await CoreGoalState.read(store: store) { ctx in
            TrainingGuidanceReader.focusGoals(ctx.goals.activeGoals) }) ?? []
        // The activity status the wearer set (sick or injured) rests the body too (Q22 rule 1).
        let status = ActivityStatusStore.load().state
        if status == .sick || status == .injured { o.unwell = true }
        return o
    }

    static func read(_ args: [String: Any], store: WhoopStore, reader: StoreReader,
                     now: Int = Int(Date().timeIntervalSince1970)) async -> Output {
        let options = await options(args, store: store)
        let today = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now)))
        let from = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now - 30 * 86_400)))
        let days = await CoreRead.dailyRows(from: from, to: today, reader: reader)
        return output(await TrainingGuidanceReader.read(reader: reader, days: days, options: options, now: now))
    }

    static func output(_ s: TrainingGuidanceReader.Snapshot) -> Output {
        let a = s.advice
        return Output(
            today: s.today,
            advice: Advice(stance: a.stance.rawValue, reason: a.reason.rawValue, state: a.state.rawValue,
                           limitedLane: a.limitedLane?.rawValue, effortLow: a.effortTarget?.lowerBound,
                           effortHigh: a.effortTarget?.upperBound, ateTooLittle: a.ateTooLittle),
            offers: s.offers.map(offer), cardioFocus: focus(s.cardioFocus), strengthFocus: focus(s.strengthFocus),
            weeks: s.weeks.map(week), carried: s.carried, strengthBand: s.strengthBand?.rawValue,
            cardioBand: s.cardioBand?.rawValue,
            askRating: s.askRating.map { Rating(sessionId: $0.sessionId, sport: WorkoutSource.localizedDisplaySport($0.sport),
                                                startTs: $0.startTs, endTs: $0.endTs) },
            food: Food(ateTooLittle: s.food.ateTooLittle, ateOverPlan: s.food.ateOverPlan,
                       proteinLow: s.food.proteinLow, completeDays: s.food.completeDays))
    }

    static func offer(_ o: TrainingOffer) -> Offer {
        switch o {
        case .planned(let title): return Offer(kind: "planned", title: title)
        case .cardio(let sport, let minutes):
            return Offer(kind: "cardio", sport: WorkoutSource.localizedDisplaySport(sport), minutes: minutes)
        case .strength(let group, let sets): return Offer(kind: "strength", group: group, sets: sets)
        case .easyMovement: return Offer(kind: "easyMovement")
        case .startWalk(let minutes): return Offer(kind: "startWalk", minutes: minutes)
        }
    }

    static func focus(_ f: TrainingFocusReading) -> Focus {
        Focus(focus: f.focus.rawValue, source: f.source.rawValue, since: f.since, pause: f.pause?.rawValue)
    }

    static func week(_ w: EnoughWeek) -> Week {
        Week(start: w.start, minutes: w.equivalentMinutes, everydayMinutes: w.everydayMinutes, ratedMinutes: w.ratedMinutes,
             strengthDays: w.strengthDays, targetLow: w.target.minutesLow, targetHigh: w.target.minutesHigh,
             strengthDaysLow: w.target.strengthDaysLow, strengthDaysHigh: w.target.strengthDaysHigh,
             balanceHint: w.target.balanceHint, fromOwnGoal: w.target.fromOwnGoal, complete: w.isComplete)
    }

    // MARK: Training Load page

    struct GoalReading: Encodable {
        var note: String?
        var noteIsHeadline: Bool
        var focus: Focus
    }

    struct GoalReadings: Encodable {
        var cardio: GoalReading
        var strength: GoalReading
        var strengthChangePercent: Double?
        var food: Food
        var guidance: Output
    }

    /// The page's two verdicts after the goal has spoken. The verdicts themselves stay in `training.load`; this
    /// adds the note that replaces or follows them, from the same lanes.
    static func goalReadings(_ args: [String: Any], store: WhoopStore, reader: StoreReader,
                             now: Int = Int(Date().timeIntervalSince1970)) async -> GoalReadings {
        let options = await options(args, store: store)
        let load = await CoreTrainingLoad.reading(reader: reader, maxHR: options.maxHR, sex: options.sex,
                                                  dismissedWorkoutSpans: options.dismissedWorkoutSpans, now: now)
        let from = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now - 30 * 86_400)))
        let days = await CoreRead.dailyRows(from: from, to: load.today, reader: reader)
        let guidance = await TrainingGuidanceReader.read(reader: reader, days: days, options: options, now: now)
        let history = await StrengthHistoryReader.read(store: store, days: 60, now: now) { load.fusion }
        let r = TrainingGuidanceReader.goalReadings(prepared: load.prepared, guidance: guidance,
                                                    strengthWorkouts: history.workouts, templates: history.templates,
                                                    options: options)
        func reading(_ g: LaneGoalReading) -> GoalReading {
            GoalReading(note: g.note?.rawValue, noteIsHeadline: g.noteIsHeadline, focus: focus(g.focus))
        }
        let out = output(guidance)
        return GoalReadings(cardio: reading(r.cardio), strength: reading(r.strength),
                            strengthChangePercent: r.strengthChangePercent, food: out.food, guidance: out)
    }

    // MARK: Lab

    struct Instrument: Encodable {
        var direction: String
        var change: Double?
        var sessions: Int
        var pairs: Int?
        var agreement: Double?
        var passes: Bool
        var reference: String?
    }

    struct Instruments: Encodable {
        var cadence: Instrument
        var recovery: Instrument
        var pace: Instrument
    }

    static func instruments(_ args: [String: Any], store: WhoopStore, reader: StoreReader,
                            now: Int = Int(Date().timeIntervalSince1970)) async -> Instruments {
        let options = await options(args, store: store)
        let today = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now)))
        let from = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now - 70 * 86_400)))
        let days = await CoreRead.dailyRows(from: from, to: today, reader: reader)
        let vo2 = await CoreTrainingLoad.vo2maxReadings(reader: reader, now: now).apple
        var byWeek: [String: [Double]] = [:]
        for r in vo2 {
            let day = r.day
            byWeek[TrainingGuidanceReader.weekStart(day, firstWeekday: options.firstWeekday), default: []].append(r.value)
        }
        let weekly = byWeek.keys.sorted().compactMap { k in FitnessInstruments.median(byWeek[k]!).map { (start: k, value: $0) } }
        let s = await TrainingInstrumentsReader.read(reader: reader, maxHR: options.maxHR,
                                                     dismissedWorkoutSpans: options.dismissedWorkoutSpans,
                                                     firstWeekday: options.firstWeekday, appleVO2Weekly: weekly,
                                                     days: days, now: now)
        func one(_ i: TrainingInstrumentsReader.Instrument) -> Instrument {
            Instrument(direction: i.reading.direction.rawValue, change: i.reading.change, sessions: i.reading.sessions,
                       pairs: i.check?.pairs, agreement: i.check?.agreement, passes: i.check?.passes ?? false,
                       reference: i.reference)
        }
        return Instruments(cadence: one(s.cadence), recovery: one(s.recovery), pace: one(s.pace))
    }
}
