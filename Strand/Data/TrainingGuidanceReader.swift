import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// Training Load plan, phase 2 (docs/fork/TRAINING_LOAD_PLAN.md §8): the morning advice, "enough?", the offers
/// and the rating to ask for, read once for every surface on both platforms. Apple reads it through
/// `Repository.refreshTrainingGuidance`, Android through the core op `training.guidance`; Today, the Effort target,
/// the Training tab, Training Load and the coach all show this one snapshot (Q5, Q23, Q24).
enum TrainingGuidanceReader {
    struct Options: Sendable {
        var maxHR: Double
        var sex: String
        var dismissedWorkoutSpans: [String] = []
        /// The focus the wearer chose (Q3); nil lets the goals decide.
        var chosenFocus: TrainingFocus? = nil
        var age: Int? = nil
        /// "Mein Puls zeigt meine Belastung nicht richtig" (Q7): minutes count by duration and rating.
        var pulseUnreliable = false
        /// The illness signal is raised, or the wearer set themselves sick or injured (Q22 rule 1).
        var unwell = false
        var goals: [TrainingFocusResolver.Goal] = []
        var dietDirection: TrainingFocusResolver.DietDirection? = nil
        var dietStartDay: String? = nil
        /// A weekly-minutes goal the wearer set themselves, which wins over the focus target (Q33).
        var ownWeeklyMinutes: Int? = nil
        /// Today's session from the plan, by its title (Q26).
        var plannedTitle: String? = nil
        /// `Calendar.firstWeekday`: 1 Sunday, 2 Monday.
        var firstWeekday: Int = 2
        /// The diet plan's day goals as the Food page resolves them (`DietDayResolver`); nil without a plan,
        /// which turns every food signal off (Q42).
        var foodGoalKcal: Double? = nil
        var proteinGoalG: Double? = nil
        /// The weight trend over three weeks in kilograms a week, and the latest weight, for the stall and the
        /// fast-loss checks.
        var weightTrendKgPerWeek: Double? = nil
        var latestWeightKg: Double? = nil
    }

    struct RatingAsk: Sendable, Equatable {
        let sessionId: String
        let sport: String
        let startTs: Int
        let endTs: Int
    }

    struct Snapshot: Sendable {
        let today: String
        let advice: MorningAdviceReading
        let offers: [TrainingOffer]
        let cardioFocus: TrainingFocusReading
        let strengthFocus: TrainingFocusReading
        /// The last complete weeks and the running one, oldest first. Empty under 18 (no adult target).
        let weeks: [EnoughWeek]
        let strengthBand: RelativeLoadBand?
        let cardioBand: RelativeLoadBand?
        /// The most recent session from yesterday or today without a rating, for the morning tap (Q12).
        let askRating: RatingAsk?
        /// What the food log adds (Q37 to Q42).
        let food: TrainingFoodSignals.Signals

        var thisWeek: EnoughWeek? { weeks.last }
        var carried: Bool { EnoughCount.isCarried(weeks) }
    }

    static let weeksRead = EnoughCount.windowWeeks + 1

    static func read(reader: StoreReader, days: [DailyMetric], options: Options,
                     now: Int = Int(Date().timeIntervalSince1970)) async -> Snapshot {
        let offset = TimeZone.current.secondsFromGMT()
        let today = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now)))
        let lookback = max(TrainingLoadLanes.lookbackDays, weeksRead * 7 + 7)
        let from = now - lookback * 86_400
        let fusion = await TrainingSessionResolver.read(reader: reader, from: from, to: now + 86_400,
                                                        dismissedDetectedSpans: options.dismissedWorkoutSpans)
        let strength = await StrengthHistoryReader.read(store: reader.store, days: lookback, now: now) { fusion }
        let resolution = await CardioLoadPricing.price(fusion.sessions, reader: reader, maxHR: options.maxHR,
                                                       sex: options.sex, dataRevision: 0, cache: CardioLoadCache(),
                                                       budget: CardioLoadPricing.cardioLoadSessionBudget,
                                                       recompute: false).resolution
        let cardio = TrainingLoadLanes.cardioSeries(sessions: fusion.sessions, resolution: resolution,
                                                    tzOffsetSeconds: offset)
        let context = TrainingLoadLanes.readinessContext(strengthWorkouts: strength.workouts, cardio: cardio,
                                                         today: today, tzOffsetSeconds: offset)
        let strengthBand: RelativeLoadBand? = context.lanes.first(where: { $0.kind == .strength })?.band
        let cardioBand: RelativeLoadBand? = context.lanes.first(where: { $0.kind == .cardio })?.band
        let recovery = TrainingStatusModel.recovery(days: days, through: today).state

        // Focus per lane and "enough?" for the cardio focus, which is what the minutes measure.
        let cardioFocus = TrainingFocusResolver.resolve(lane: .cardio, chosen: options.chosenFocus,
                                                        diet: options.dietDirection, dietStartDay: options.dietStartDay,
                                                        goals: options.goals, today: today)
        let strengthFocus = TrainingFocusResolver.resolve(lane: .strength, chosen: options.chosenFocus,
                                                          diet: options.dietDirection, dietStartDay: options.dietStartDay,
                                                          goals: options.goals, today: today)
        let ratings = await SessionRPEEntry.read(store: reader.store, from: from, to: now + 86_400)
        let weeks = await enoughWeeks(reader: reader, focus: cardioFocus.focus, options: options, today: today,
                                      sessions: fusion.sessions, resolution: resolution, ratings: ratings,
                                      strengthWorkouts: strength.workouts, offset: offset)

        let trainedToday = fusion.sessions.contains {
            AnalyticsEngine.dayString($0.row.startTs, offsetSec: offset) == today
        } || strength.workouts.contains { AnalyticsEngine.dayString($0.startTs, offsetSec: offset) == today }

        let todayRow = days.first { $0.day == today }
        let night: AdviceNight
        if todayRow?.recovery != nil {
            night = .scored
        } else {
            let latest = await reader.unionLatestHRSampleTs() ?? 0
            let midnight = Self.localMidnight(now, offset: offset)
            let hour = (now - midnight) / 3600
            night = latest < midnight + 3 * 3600 && hour < 15 ? .pending : .missing
        }

        let goalRests = (cardioFocus.pause?.restsTheBody ?? false) || (strengthFocus.pause?.restsTheBody ?? false)
        let unwell = options.unwell || goalRests
        let behind = Self.isBehind(weeks.last, today: today, firstWeekday: options.firstWeekday)
        let heavy = [strengthBand, cardioBand].contains { $0 == .higher || $0 == .muchHigher }
        let cachedGoal = options.dietDirection == nil ? nil : TrainingGuidanceFoodGoal.load(today: today)
        let food = await TrainingFoodSignals.read(store: reader.store, today: today,
                                                  goalKcal: options.foodGoalKcal ?? cachedGoal?.kcal,
                                                  proteinGoalG: options.proteinGoalG ?? cachedGoal?.proteinG,
                                                  heavyWeek: heavy,
                                                  losing: cardioFocus.focus == .loseWeight,
                                                  trendKgPerWeek: options.weightTrendKgPerWeek)
        let charge: Double? = todayRow?.recovery
        let input = MorningAdviceInput(
            charge: charge, night: night, unwell: unwell,
            recovery: recovery, strengthBand: strengthBand, cardioBand: cardioBand,
            plannedToday: options.plannedTitle != nil, behindGoal: behind,
            ateTooLittle: food.ateTooLittle, trainedToday: trainedToday)
        let advice = MorningAdvice.resolve(input)

        let cardioRoom = LaneOutlook.headroom(dailyByDay: cardio.byDay, unknownDays: cardio.unknownDays,
                                              activity: cardio.activity, lane: .cardio, today: today)?.beforeAbove
        let offers = TrainingOffers.build(advice: advice, plannedTitle: options.plannedTitle, cardioRoom: cardioRoom,
                                          typical: typicalCardio(sessions: fusion.sessions, resolution: resolution,
                                                                 today: today, offset: offset),
                                          strengthGroups: strengthRoom(strength: strength, today: today, offset: offset))
        return Snapshot(today: today, advice: advice, offers: offers, cardioFocus: cardioFocus,
                        strengthFocus: strengthFocus, weeks: weeks, strengthBand: strengthBand, cardioBand: cardioBand,
                        askRating: ratingToAsk(sessions: fusion.sessions, ratings: ratings, today: today, offset: offset,
                                               now: now),
                        food: food)
    }

    // MARK: The verdict against the goal

    struct GoalReadings: Sendable {
        let cardio: LaneGoalReading
        let strength: LaneGoalReading
        /// The main lifts' change over six weeks, the one strength trend (Q39).
        let strengthChangePercent: Double?
    }

    /// Training Load's two verdicts after the goal has spoken, from the page's own prepared lanes and the
    /// guidance snapshot, so the page and Today read one focus and one "enough?".
    static func goalReadings(prepared: TrainingLoadPreparation.Prepared, guidance: Snapshot,
                             strengthWorkouts: [HevyWorkout], templates: [String: HevyExerciseTemplate],
                             options: Options) -> GoalReadings {
        let offset = TimeZone.current.secondsFromGMT()
        let change = StrengthSession.recentChangePercent(workouts: strengthWorkouts, templates: templates,
                                                         through: guidance.today, tzOffsetSeconds: offset)
        var weightPercent: Double? = nil
        if let trend = options.weightTrendKgPerWeek, let kg = options.latestWeightKg, kg > 0 { weightPercent = trend / kg * 100 }
        let cardio = GoalOutcome.cardio(verdict: prepared.cardioVerdict, band: prepared.cardio.reading?.band,
                                        focus: guidance.cardioFocus, weeks: guidance.weeks,
                                        recovery: prepared.recovery.state, today: guidance.today)
        let strength = GoalOutcome.strength(verdict: prepared.strengthVerdict, band: prepared.strength.reading?.band,
                                            focus: guidance.strengthFocus, changePercent: change,
                                            weightChangePercentPerWeek: weightPercent,
                                            recovery: prepared.recovery.state, today: guidance.today)
        return GoalReadings(cardio: cardio, strength: strength, strengthChangePercent: change)
    }

    // MARK: Enough

    /// The running week and the four before it, each against the focus target. Minutes come from the daily
    /// pass's `active_min_*` series; a session the pulse cannot speak for adds its rated minutes (Q8, Q21), and
    /// with `pulseUnreliable` only rated minutes count (Q7).
    static func enoughWeeks(reader: StoreReader, focus: TrainingFocus, options: Options, today: String,
                            sessions: [UnifiedTrainingSession], resolution: TrainingCardioLoadResolution,
                            ratings: [SessionRPEEntry], strengthWorkouts: [HevyWorkout], offset: Int) async -> [EnoughWeek] {
        guard let target = EnoughTarget.forFocus(focus, age: options.age, ownWeeklyMinutes: options.ownWeeklyMinutes)
        else { return [] }
        let thisStart = weekStart(today, firstWeekday: options.firstWeekday)
        let starts = (0..<weeksRead).reversed().map { WeeklyDigestEngine.addDays(thisStart, -7 * $0) }
        let first = starts.first ?? thisStart
        let stored = await reader.storedActiveMinutesByDay(fromDay: first, toDay: today)

        let ratingByStart = Dictionary(ratings.map { ($0.startTs, $0.rpe) }, uniquingKeysWith: { a, _ in a })
        let ratingById = Dictionary(ratings.compactMap { r in r.sessionId.map { ($0, r.rpe) } },
                                    uniquingKeysWith: { a, _ in a })
        var ratedByDay: [String: Int] = [:]
        for s in sessions where s.kind != .strength {
            let day = AnalyticsEngine.dayString(s.row.startTs, offsetSec: offset)
            guard day >= first, day <= today else { continue }
            let measured = resolution.loads[s.id] != nil
            let swim = SessionRatingPolicy.family(forSport: s.row.sport) == .swimming
            guard options.pulseUnreliable || !measured || swim else { continue }
            let minutes = max(0, (s.row.endTs - s.row.startTs) / 60)
            let rating = ratingById[s.id] ?? ratingByStart[s.row.startTs]
            let rated = ActiveMinutes.ratedMinutes(durationMinutes: minutes, rating: rating)
            ratedByDay[day, default: 0] += rated.moderate + 2 * rated.vigorous
        }
        var strengthDays: Set<String> = []
        for w in strengthWorkouts { strengthDays.insert(AnalyticsEngine.dayString(w.startTs, offsetSec: offset)) }
        for s in sessions where s.kind == .strength {
            strengthDays.insert(AnalyticsEngine.dayString(s.row.startTs, offsetSec: offset))
        }

        return starts.map { start in
            let end = WeeklyDigestEngine.addDays(start, 6)
            var hrMinutes = 0, everyday = 0, rated = 0, strengthCount = 0
            var cursor = start
            while cursor <= end && cursor <= today {
                let m = stored[cursor] ?? ActiveMinutesDay()
                let e = m.everydayModerate + 2 * m.everydayVigorous
                let s = m.sessionModerate + 2 * m.sessionVigorous
                if !options.pulseUnreliable { hrMinutes += s + e; everyday += e }
                rated += ratedByDay[cursor] ?? 0
                if strengthDays.contains(cursor) { strengthCount += 1 }
                cursor = WeeklyDigestEngine.addDays(cursor, 1)
            }
            return EnoughWeek(start: start, equivalentMinutes: hrMinutes + rated, everydayMinutes: everyday,
                              ratedMinutes: rated, strengthDays: strengthCount, target: target,
                              isComplete: end < today)
        }
    }

    /// Behind the goal: this week's minutes trail the share of the target the days so far ask for. Never on
    /// the week's first two days, when nothing can be behind yet.
    static func isBehind(_ week: EnoughWeek?, today: String, firstWeekday: Int) -> Bool {
        guard let week, !week.isComplete else { return false }
        let elapsed = (FitnessInstruments.dayNumber(today) ?? 0) - (FitnessInstruments.dayNumber(week.start) ?? 0) + 1
        guard elapsed >= 3 else { return false }
        let expected = Double(week.target.minutesLow) * Double(elapsed) / 7
        return Double(week.equivalentMinutes) < expected
    }

    static func weekStart(_ day: String, firstWeekday: Int) -> String {
        guard let n = FitnessInstruments.dayNumber(day) else { return day }
        // dayNumber 0 (1970-01-01) was a Thursday: Calendar weekday 5.
        let weekday = ((n % 7) + 7 + 4) % 7 + 1
        let back = (weekday - firstWeekday + 7) % 7
        return WeeklyDigestEngine.addDays(day, -back)
    }

    static func localMidnight(_ ts: Int, offset: Int) -> Int {
        let local = ts + offset
        return local - ((local % 86_400) + 86_400) % 86_400 - offset
    }

    // MARK: Offers

    /// The wearer's usual cardio: the sport with the most measured sessions in the last four weeks and its
    /// median load per covered minute.
    static func typicalCardio(sessions: [UnifiedTrainingSession], resolution: TrainingCardioLoadResolution,
                              today: String, offset: Int) -> TrainingOffers.Typical? {
        let since = WeeklyDigestEngine.addDays(today, -27)
        var bySport: [String: [Double]] = [:]
        for s in sessions where s.kind != .strength {
            guard AnalyticsEngine.dayString(s.row.startTs, offsetSec: offset) >= since,
                  let load = resolution.loads[s.id], load.coveredMinutes > 0, load.trimp > 0 else { continue }
            bySport[s.row.sport, default: []].append(load.trimp / Double(load.coveredMinutes))
        }
        guard let best = bySport.max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) }),
              let median = FitnessInstruments.median(best.value) else { return nil }
        return TrainingOffers.Typical(sport: best.key, loadPerMinute: median)
    }

    /// Hard sets each muscle group can still take today before its week reads above usual, three or more only.
    static func strengthRoom(strength: ResolvedStrengthHistory, today: String, offset: Int) -> [(group: String, sets: Int)] {
        var out: [(group: String, sets: Int)] = []
        for (group, byDay) in MuscleGroupLoad.setsByGroupByDay(strength.workouts, templates: strength.templates,
                                                               tzOffsetSeconds: offset) {
            guard group != .cardio, group != .other else { continue }
            let activity = LaneActivity(sessionsByDay: byDay.mapValues { _ in 1 })
            guard let room = LaneOutlook.headroom(dailyByDay: byDay, activity: activity, lane: .strength,
                                                  today: today) else { continue }
            let sets = Int(room.beforeAbove)
            if sets >= 3 { out.append((group.rawValue, sets)) }
        }
        return out.sorted { ($0.sets, $1.group) > ($1.sets, $0.group) }
    }

    // MARK: Rating

    /// The latest session that ended yesterday or today, ten minutes or longer, without a rating.
    static func ratingToAsk(sessions: [UnifiedTrainingSession], ratings: [SessionRPEEntry], today: String,
                            offset: Int, now: Int) -> RatingAsk? {
        let yesterday = WeeklyDigestEngine.addDays(today, -1)
        let ratedIds = Set(ratings.compactMap(\.sessionId))
        let ratedStarts = Set(ratings.map(\.startTs))
        return sessions
            .filter { s in
                let day = AnalyticsEngine.dayString(s.row.startTs, offsetSec: offset)
                let starts = Set(s.components.map { $0.row.startTs } + [s.row.startTs])
                return (day == yesterday || day == today) && s.row.endTs <= now
                    && s.row.endTs - s.row.startTs >= 600
                    && !ratedIds.contains(s.id) && starts.isDisjoint(with: ratedStarts)
            }
            .max { $0.row.endTs < $1.row.endTs }
            .map { RatingAsk(sessionId: $0.id, sport: $0.row.sport, startTs: $0.row.startTs, endTs: $0.row.endTs) }
    }
}

// MARK: Goals

extension TrainingGuidanceReader {
    /// The active and paused goals as the focus resolver reads them, with a paused goal's open pause reason.
    static func focusGoals(_ goals: [CoachGoal]) -> [TrainingFocusResolver.Goal] {
        goals.filter { $0.status == .active || $0.status == .paused }.map { goal in
            let kind: TrainingFocusResolver.Goal.Kind
            switch goal.kind {
            case .weight: kind = .weight
            case .endurance: kind = .endurance
            case .run: kind = .run
            case .fitness: kind = .fitness
            case .strength: kind = .strength
            case .hardSets: kind = .hardSets
            case .consistency: kind = .consistency
            case .activity: kind = .activity
            default: kind = .other
            }
            let pause: TrainingGoalPause? = goal.status == .paused
                ? goal.pauseIntervals.last(where: { $0.endedAt == nil })
                    .map { TrainingGoalPause(rawValue: $0.reason.rawValue) ?? .other } ?? .other
                : nil
            return TrainingFocusResolver.Goal(kind: kind, baseline: goal.baseline, target: goal.target,
                                              targetDay: goal.targetDate.map(StoreReader.localDayKey),
                                              createdDay: StoreReader.localDayKey(goal.createdAt), pause: pause)
        }
    }

    static func dietDirection(_ goal: DietPlan.Goal) -> TrainingFocusResolver.DietDirection {
        switch goal {
        case .lose: return .lose
        case .maintain: return .maintain
        case .gain: return .gain
        case .recomp: return .recomp
        }
    }
}

// MARK: The plan's day goal

/// The diet plan's day goal as the Food page last resolved it (Apple `ForgeFoodModel.publishWidget`, Android
/// `food.dayGoal`), kept so the morning advice reads the same goal without resolving the plan a second way.
/// A goal older than a week is not used, and without a plan there is none, which turns the food signals off.
enum TrainingGuidanceFoodGoal {
    static let key = "trainingGuidance.foodGoal"

    static func save(day: String, kcal: Double?, proteinG: Double?, defaults: UserDefaults = .standard) {
        guard let kcal, kcal > 0 else { defaults.removeObject(forKey: key); return }
        defaults.set(["day": day, "kcal": kcal, "proteinG": proteinG ?? 0], forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }

    static func load(today: String, defaults: UserDefaults = .standard) -> (kcal: Double, proteinG: Double?)? {
        guard let d = defaults.dictionary(forKey: key), let day = d["day"] as? String,
              let kcal = (d["kcal"] as? NSNumber)?.doubleValue, kcal > 0,
              day >= WeeklyDigestEngine.addDays(today, -6) else { return nil }
        let protein = (d["proteinG"] as? NSNumber)?.doubleValue
        return (kcal, (protein ?? 0) > 0 ? protein : nil)
    }
}

// MARK: Settings

/// The wearer's Training Load settings of phase 2, the same keys on both platforms.
enum TrainingGuidancePrefs {
    /// The chosen focus (Q3), a `TrainingFocus` raw value; absent lets the goals decide.
    static let focusKey = "trainingLoad.focus"
    /// "Mein Puls zeigt meine Belastung nicht richtig" (Q7), off by default.
    static let pulseUnreliableKey = "trainingLoad.pulseUnreliable"
    /// The morning advice notification (Q16), off by default.
    static let morningAdviceKey = "trainingLoad.morningAdvice"
    /// The day the morning advice was last posted, so it goes out once a day.
    static let morningAdviceDayKey = "trainingLoad.morningAdviceDay"
    /// The Lab instruments (Q19, Q35), off by default.
    static let labInstrumentsKey = "trainingLoad.labInstruments"

    /// The illness signal is raised, as the analytics pass last evaluated it. In memory only: the pass sets it on
    /// every run, and a cold start reads it again before the advice is needed.
    nonisolated(unsafe) static var illnessRaised = false

    static func chosenFocus(_ d: UserDefaults = .standard) -> TrainingFocus? {
        d.string(forKey: focusKey).flatMap(TrainingFocus.init(rawValue:))
    }
}
