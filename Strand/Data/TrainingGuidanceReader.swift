import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore
import WhoopProtocol
import StrandTraining

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
        /// Today's committed coach session and how hard it is, so a day held back can offer to move it (Q17, Q27).
        var plannedProposalId: UUID? = nil
        var plannedHard = false
        var plannedModerate = false
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

    struct MovablePlan: Sendable, Equatable {
        let id: UUID
        let title: String
        let tomorrow: String
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
        /// Today's planned session that goes against the advice and can be moved to tomorrow on a tap (Q17, Q27).
        let movablePlan: MovablePlan?
        /// The weight trend over three weeks in kilograms a week and the latest weight, read in the core so both
        /// platforms see the same stall and fast-loss checks.
        let weightTrendKgPerWeek: Double?
        let latestWeightKg: Double?

        var thisWeek: EnoughWeek? { weeks.last }
        var carried: Bool { EnoughCount.isCarried(weeks) }
    }

    static let weeksRead = EnoughCount.windowWeeks + 1

    /// Sessions the caller has already read and priced over at least `lookbackDays`, so a refresh that has just
    /// read the lanes does not read and price them a second time.
    struct Precomputed: Sendable {
        let sessions: [UnifiedTrainingSession]
        let resolution: TrainingCardioLoadResolution
        let strength: ResolvedStrengthHistory
    }

    /// History the guidance reads: the lanes' own window, and at least the weeks of "enough?" plus one.
    static var lookbackDays: Int { max(TrainingLoadLanes.lookbackDays, weeksRead * 7 + 7) }

    /// `cache` is the pricing memo the caller keeps across reads (`CardioLoadCache`); a fresh one prices the
    /// last week's sessions from raw heart rate again, because ledger rows only answer once a session is a week old.
    static func read(reader: StoreReader, days: [DailyMetric], options: Options,
                     now: Int = Int(Date().timeIntervalSince1970), precomputed: Precomputed? = nil,
                     cache: CardioLoadCache = CardioLoadCache(), defaults: UserDefaults = .standard) async -> Snapshot {
        let offset = TimeZone.current.secondsFromGMT()
        let today = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now)))
        let lookback = lookbackDays
        let from = now - lookback * 86_400
        let sessions: [UnifiedTrainingSession]
        let strength: ResolvedStrengthHistory
        let resolution: TrainingCardioLoadResolution
        if let precomputed {
            sessions = precomputed.sessions; strength = precomputed.strength; resolution = precomputed.resolution
        } else {
            let fusion = await TrainingSessionResolver.read(reader: reader, from: from, to: now + 86_400,
                                                            dismissedDetectedSpans: options.dismissedWorkoutSpans)
            sessions = fusion.sessions
            strength = await StrengthHistoryReader.read(store: reader.store, days: lookback, now: now) { fusion }
            resolution = await CardioLoadPricing.price(fusion.sessions, reader: reader, maxHR: options.maxHR,
                                                       sex: options.sex, dataRevision: 0, cache: cache,
                                                       budget: CardioLoadPricing.cardioLoadSessionBudget,
                                                       recompute: false).resolution
        }
        let cardio = TrainingLoadLanes.cardioSeries(sessions: sessions, resolution: resolution,
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
                                      sessions: sessions, resolution: resolution, ratings: ratings,
                                      strengthWorkouts: strength.workouts, offset: offset, days: days)

        let trainedToday = sessions.contains {
            AnalyticsEngine.dayString($0.row.startTs, offsetSec: offset) == today
        } || strength.workouts.contains { AnalyticsEngine.dayString($0.startTs, offsetSec: offset) == today }

        let todayRow = days.first { $0.day == today }
        // Without a Charge for today the night is still on its way until midday: a strap streaming live heart rate
        // keeps its latest sample current while the night itself is not scored yet. Only after midday is a missing
        // Charge a night that was not measured.
        let night: AdviceNight
        if todayRow?.recovery != nil {
            night = .scored
        } else {
            let hour = (now - Self.localMidnight(now, offset: offset)) / 3600
            night = hour < Self.nightPendingUntilHour ? .pending : .missing
        }

        let goalRests = (cardioFocus.pause?.restsTheBody ?? false) || (strengthFocus.pause?.restsTheBody ?? false)
        let unwell = options.unwell || goalRests
        let behind = Self.isBehind(weeks.last, today: today, firstWeekday: options.firstWeekday)
        let heavy = [strengthBand, cardioBand].contains { $0 == .higher || $0 == .muchHigher }
        let weight = await Self.weightTrend(reader: reader, today: today, options: options)
        let cachedGoal = options.dietDirection == nil ? nil : TrainingGuidanceFoodGoal.load(today: today)
        let food = await TrainingFoodSignals.read(store: reader.store, today: today,
                                                  goalKcal: options.foodGoalKcal ?? cachedGoal?.kcal,
                                                  proteinGoalG: options.proteinGoalG ?? cachedGoal?.proteinG,
                                                  heavyWeek: heavy,
                                                  losing: cardioFocus.focus == .loseWeight,
                                                  trendKgPerWeek: weight.trend)
        // Today's plan: a committed coach session, else a routine planned for today and not yet run (Q26).
        var planned = options
        if planned.plannedTitle == nil {
            planned.plannedTitle = await Self.openRoutineTitle(reader: reader, today: today, now: now,
                                                               firstWeekday: options.firstWeekday)
        }
        let charge: Double? = todayRow?.recovery
        let input = MorningAdviceInput(
            charge: charge, night: night, unwell: unwell,
            recovery: recovery, strengthBand: strengthBand, cardioBand: cardioBand,
            plannedToday: planned.plannedTitle != nil, behindGoal: behind,
            ateTooLittle: food.ateTooLittle, trainedToday: trainedToday)
        // The first ready advice holds for the day (Q15).
        let given = TrainingGuidanceAdviceStore.load(day: today, defaults: defaults)
        let advice = MorningAdvice.held(MorningAdvice.resolve(input), given: given)
        if advice.state != .waitingForNight { TrainingGuidanceAdviceStore.save(advice, day: today, defaults: defaults) }

        let cardioRoom = LaneOutlook.headroom(dailyByDay: cardio.byDay, unknownDays: cardio.unknownDays,
                                              activity: cardio.activity, lane: .cardio, today: today)?.beforeAbove
        let offers = TrainingOffers.build(advice: advice, plannedTitle: planned.plannedTitle, cardioRoom: cardioRoom,
                                          typical: typicalCardio(sessions: sessions, resolution: resolution,
                                                                 today: today, offset: offset),
                                          strengthGroups: strengthRoom(strength: strength, today: today, offset: offset))
        return Snapshot(today: today, advice: advice, offers: offers, cardioFocus: cardioFocus,
                        strengthFocus: strengthFocus, weeks: weeks, strengthBand: strengthBand, cardioBand: cardioBand,
                        askRating: ratingToAsk(sessions: sessions, ratings: ratings, today: today, offset: offset,
                                               now: now),
                        food: food,
                        movablePlan: movable(options: planned, advice: advice, today: today),
                        weightTrendKgPerWeek: weight.trend, latestWeightKg: weight.latest)
    }

    /// Hours after local midnight a day without a Charge still waits for its night.
    static let nightPendingUntilHour = 12

    /// The weight trend over the last three weeks and the latest weight, unless the caller passed them.
    static func weightTrend(reader: StoreReader, today: String, options: Options) async -> (trend: Double?, latest: Double?) {
        if options.weightTrendKgPerWeek != nil || options.latestWeightKg != nil {
            return (options.weightTrendKgPerWeek, options.latestWeightKg)
        }
        let points = await WeightSeries.series(reader: reader, from: WeeklyDigestEngine.addDays(today, -29), to: today)
            .map { (day: $0.day, kg: $0.value) }
        let recent = points.filter { $0.day >= WeeklyDigestEngine.addDays(today, -20) }
        return (DietAdjust.slopePerWeek(recent), points.last?.kg)
    }

    /// The first routine the training plan holds for today that no saved workout of today was run from.
    static func openRoutineTitle(reader: StoreReader, today: String, now: Int, firstWeekday: Int) async -> String? {
        let store = reader.store
        guard let plan = try? await store.trainingPlan(weekStartsOn: firstWeekday == 1 ? .sunday : .monday),
              let n = FitnessInstruments.dayNumber(today) else { return nil }
        // dayNumber 0 (1970-01-01) was a Thursday: ISO weekday 4.
        let iso = ((n % 7) + 7 + 3) % 7 + 1
        guard let weekday = TrainingWeekday(rawValue: iso) else { return nil }
        let routines = plan.routines(day: today, weekday: weekday)
        guard !routines.isEmpty else { return nil }
        let workouts = (try? await store.nativeWorkouts(from: now - 2 * 86_400, to: now + 86_400)) ?? []
        let open = Set(PlannedToday.openRoutineIds(routines.map(\.id), day: today, workouts: workouts))
        return routines.first { open.contains($0.id) }?.title
    }

    /// The planned session a held-back day offers to move: a hard one on an easy day, anything above easy on a rest
    /// day, the same rule the coach's proposals are marked by (`MorningAdvice.conflicts`).
    static func movable(options: Options, advice: MorningAdviceReading, today: String) -> MovablePlan? {
        guard let id = options.plannedProposalId, let title = options.plannedTitle,
              MorningAdvice.conflicts(advice, hard: options.plannedHard, moderate: options.plannedModerate,
                                      targetEffort: nil) else { return nil }
        return MovablePlan(id: id, title: title, tomorrow: WeeklyDigestEngine.addDays(today, 1))
    }

    /// Today's committed coach session, read from the one plan store both platforms share.
    @MainActor static func fillPlanned(_ o: inout Options, today: String) {
        guard let p = CoachPlanStore.shared.proposals.first(where: {
            $0.day == today && ($0.status == .accepted || $0.status == .modifiedByUser)
        }) else { return }
        o.plannedTitle = WorkoutSource.localizedDisplaySport(p.sport)
        o.plannedProposalId = p.id
        o.plannedHard = p.intent == .hard
        o.plannedModerate = p.intent == .moderate
    }

    // MARK: The verdict against the goal

    struct GoalReadings: Sendable {
        let cardio: LaneGoalReading
        let strength: LaneGoalReading
        /// The main lifts' change over six weeks, the one strength trend (Q39).
        let strengthChangePercent: Double?
        /// Low protein, shown only beside strength falling in a deficit (Q40).
        let proteinHint: Bool
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
        if let trend = guidance.weightTrendKgPerWeek, let kg = guidance.latestWeightKg, kg > 0 { weightPercent = trend / kg * 100 }
        let cardio = GoalOutcome.cardio(verdict: prepared.cardioVerdict, band: prepared.cardio.reading?.band,
                                        focus: guidance.cardioFocus, weeks: guidance.weeks,
                                        recovery: prepared.recovery.state, today: guidance.today)
        let strength = GoalOutcome.strength(verdict: prepared.strengthVerdict, band: prepared.strength.reading?.band,
                                            focus: guidance.strengthFocus, changePercent: change,
                                            weightChangePercentPerWeek: weightPercent,
                                            recovery: prepared.recovery.state, today: guidance.today)
        // Q40: protein is named as a possible reason only beside strength that is falling in a deficit.
        let proteinHint = guidance.food.proteinLow && guidance.strengthFocus.focus == .loseWeight && (change ?? 0) < 0
        return GoalReadings(cardio: cardio, strength: strength, strengthChangePercent: change, proteinHint: proteinHint)
    }

    // MARK: Enough

    /// The running week and the four before it, each against the focus target. Minutes come from the daily
    /// pass's `active_min_*` series; a session the pulse cannot speak for adds its rated minutes (Q8, Q21), and
    /// with `pulseUnreliable` only rated minutes count (Q7).
    static func enoughWeeks(reader: StoreReader, focus: TrainingFocus, options: Options, today: String,
                            sessions: [UnifiedTrainingSession], resolution: TrainingCardioLoadResolution,
                            ratings: [SessionRPEEntry], strengthWorkouts: [HevyWorkout], offset: Int,
                            days: [DailyMetric] = []) async -> [EnoughWeek] {
        guard let target = EnoughTarget.forFocus(focus, age: options.age, ownWeeklyMinutes: options.ownWeeklyMinutes)
        else { return [] }
        let thisStart = weekStart(today, firstWeekday: options.firstWeekday)
        let starts = (0..<weeksRead).reversed().map { WeeklyDigestEngine.addDays(thisStart, -7 * $0) }
        let first = starts.first ?? thisStart
        let stored = await reader.storedActiveMinutesByDay(fromDay: first, toDay: today)
        let restingValues = days.suffix(14).compactMap(\.restingHr).sorted()
        let resting = restingValues.isEmpty ? StrainScorer.defaultRestingHR : Double(restingValues[restingValues.count / 2])

        let ratingByStart = Dictionary(ratings.map { ($0.startTs, $0.rpe) }, uniquingKeysWith: { a, _ in a })
        let ratingById = Dictionary(ratings.compactMap { r in r.sessionId.map { ($0, r.rpe) } },
                                    uniquingKeysWith: { a, _ in a })
        // Minutes counted by a rating, minutes of a session measured by another trace than the strap's, and strap
        // minutes inside a swim that the rating replaces: each session's minutes are counted exactly once.
        var ratedByDay: [String: Int] = [:]
        var traceByDay: [String: Int] = [:]
        var replacedByDay: [String: Int] = [:]
        for s in sessions where s.kind != .strength && !resolution.duplicateSessionIds.contains(s.id) {
            let day = AnalyticsEngine.dayString(s.row.startTs, offsetSec: offset)
            guard day >= first, day <= today, s.row.endTs > s.row.startTs else { continue }
            let span = s.row.startTs..<s.row.endTs
            let load = resolution.loads[s.id]
            // A session the pricing budget left for later has its heart rate; it is measured, not unrated.
            let measured = load != nil || resolution.deferredSessionIds.contains(s.id)
            let swim = SessionRatingPolicy.family(forSport: s.row.sport) == .swimming
            if options.pulseUnreliable || !measured || swim {
                let minutes = max(0, (s.row.endTs - s.row.startTs) / 60)
                let rating = ratingById[s.id] ?? ratingByStart[s.row.startTs]
                let rated = ActiveMinutes.ratedMinutes(durationMinutes: minutes, rating: rating)
                ratedByDay[day, default: 0] += rated.moderate + 2 * rated.vigorous
                if swim && !options.pulseUnreliable {
                    let strap = await strapSamples(reader: reader, span: span)
                    let m = ActiveMinutes.day(hr: strap, steps: [], sessions: [span], restingHR: resting, maxHR: options.maxHR)
                    replacedByDay[day, default: 0] += m.sessionModerate + 2 * m.sessionVigorous
                }
                continue
            }
            // Measured by another trace (an Apple Watch workout) while the strap was off: the daily pass, which reads
            // the strap alone, has none of these minutes, so they are counted from the session's own trace.
            guard let load, load.source != .noopBand else { continue }
            let strap = await strapSamples(reader: reader, span: span)
            guard strap.count < (span.count / 4) else { continue }
            let trace = await reader.hrSamples(from: span.lowerBound, to: span.upperBound, limit: Int.max)
            let m = ActiveMinutes.day(hr: trace, steps: [], sessions: [span], restingHR: resting, maxHR: options.maxHR)
            var counted = m.sessionModerate + 2 * m.sessionVigorous
            if counted == 0, !trace.isEmpty, options.maxHR > resting + 10 {
                // A sparse trace (a sample every few seconds is not enough per minute): its average speaks for it.
                let average = Double(trace.map(\.bpm).reduce(0, +)) / Double(trace.count)
                let share = (average - resting) / (options.maxHR - resting)
                if share >= ActiveMinutes.vigorousReserve { counted = 2 * load.coveredMinutes }
                else if share >= ActiveMinutes.moderateReserve { counted = load.coveredMinutes }
            }
            traceByDay[day, default: 0] += counted
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
                if !options.pulseUnreliable {
                    hrMinutes += max(0, s - (replacedByDay[cursor] ?? 0)) + e + (traceByDay[cursor] ?? 0)
                    everyday += e
                }
                rated += ratedByDay[cursor] ?? 0
                if strengthDays.contains(cursor) { strengthCount += 1 }
                cursor = WeeklyDigestEngine.addDays(cursor, 1)
            }
            return EnoughWeek(start: start, equivalentMinutes: hrMinutes + rated, everydayMinutes: everyday,
                              ratedMinutes: rated, strengthDays: strengthCount, target: target,
                              isComplete: end < today)
        }
    }

    /// The strap's own samples inside a span, the ones the daily pass counted.
    static func strapSamples(reader: StoreReader, span: Range<Int>) async -> [HRSample] {
        (try? await reader.store.hrSamples(deviceId: reader.activeDeviceId, from: span.lowerBound, to: span.upperBound,
                                           limit: Int.max)) ?? []
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

// MARK: The day's advice

/// The advice as first given today, kept so it holds for the day (Q15) and so cheap readouts (the Effort target
/// notification, the coupled view, Android's coach chips) read the same band and stance without the full read.
enum TrainingGuidanceAdviceStore {
    static let key = "trainingLoad.adviceOfDay"

    private struct Stored: Codable {
        let day: String
        let advice: MorningAdviceReading
    }

    static func save(_ advice: MorningAdviceReading, day: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(Stored(day: day, advice: advice)),
              let text = String(data: data, encoding: .utf8) else { return }
        defaults.set(text, forKey: key)
    }

    static func load(day: String, defaults: UserDefaults = .standard) -> MorningAdviceReading? {
        guard let text = defaults.string(forKey: key), let data = text.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data), stored.day == day else { return nil }
        return stored.advice
    }

    /// Today's capped Effort band on the 0 to 21 scale, or nil before the advice was given.
    static func todayBand21(now: Date = Date(), defaults: UserDefaults = .standard) -> ClosedRange<Int>? {
        load(day: StoreReader.localDayKey(now), defaults: defaults)?.effortBand21
    }
}
