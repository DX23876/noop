import Foundation
import StrandAnalytics
import StrandCore
import WhoopStore

/// Strength and Cardio read models for Android. Both use the pure preparation the Apple models run;
/// the JSON boundary carries finished readings and their coverage, never a second analytics formula.
public enum CoreTrainingReports {
    public struct Range: Encodable {
        public var lower: Double, upper: Double
        init(_ range: ClosedRange<Double>) { lower = range.lowerBound; upper = range.upperBound }
    }

    public struct Trend: Encodable {
        public var slopePerWeek: Double, spread: Range, pointCount: Int, spanDays: Int
        public var firstValue: Double, lastValue: Double, directionIsUnclear: Bool
        init(_ trend: StrengthTrendLine) {
            slopePerWeek = trend.slopePerWeek; spread = Range(trend.slopeSpread)
            pointCount = trend.pointCount; spanDays = trend.spanDays
            firstValue = trend.firstValue; lastValue = trend.lastValue
            directionIsUnclear = trend.directionIsUnclear
        }
    }

    public struct Point: Encodable {
        public var day: String, startTs: Int, value: Double?
    }

    public struct Selection: Encodable {
        public var days: Int, weekOffset: Int, minWeekOffset: Int
        public var monday: String, sunday: String, readingDay: String

        init(days: Int, requestedOffset: Int, earliestDay: String?, now: Int) {
            self.days = days
            let today = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now)))
            let thisMonday = WeeklyDigestEngine.mondayOfWeek(containing: today) ?? today
            var minimum = 0
            if let earliestDay, let earliestMonday = WeeklyDigestEngine.mondayOfWeek(containing: earliestDay) {
                var monday = thisMonday
                while monday > earliestMonday && minimum > -(TrainingHistoryWindow.allDays / 7 + 1) {
                    monday = WeeklyDigestEngine.addDays(monday, -7)
                    minimum -= 1
                }
            }
            minWeekOffset = minimum
            weekOffset = max(minimum, min(0, requestedOffset))
            monday = WeeklyDigestEngine.addDays(thisMonday, weekOffset * 7)
            sunday = WeeklyDigestEngine.addDays(monday, 6)
            readingDay = today
        }
    }

    public struct Overview: Encodable {
        public struct Record: Encodable {
            public var exerciseId: String, exerciseTitle: String, workoutId: String
            public var timestamp: Int, estimatedOneRepMaxKg: Double
        }
        public var sessions: Int, trainingDays: Int, workingSets: Int, ratedSets: Int
        public var volumeKg: Double, volumeSets: Int, durationSeconds: Int, durationSessions: Int
        public var sessionsPerWeek: Double, averageRPE: Double?
        public var activeWeeks: Int, observedWeeks: Int, longestStreak: Int
        public var records: [Record]

        init(_ value: StrengthOverview) {
            sessions = value.sessionCount; trainingDays = value.trainingDayCount
            workingSets = value.workingSetCount; ratedSets = value.ratedSetCount
            volumeKg = value.volumeLoadKg; volumeSets = value.volumeSetCount
            durationSeconds = value.durationSeconds; durationSessions = value.durationSessionCount
            sessionsPerWeek = value.sessionsPerWeek; averageRPE = value.averageRPE
            activeWeeks = value.activeWeekCount; observedWeeks = value.observedWeekCount
            longestStreak = value.longestActiveWeekStreak
            records = value.personalRecords.map {
                Record(exerciseId: $0.exerciseId, exerciseTitle: $0.exerciseTitle, workoutId: $0.workoutId,
                       timestamp: $0.timestamp, estimatedOneRepMaxKg: $0.estimatedOneRepMaxKg)
            }
        }
    }

    public struct Muscle: Encodable {
        public var id: String, primarySets: Int, secondarySets: Int
        public var usualSets: Range?, stimulus: Double, usualStimulus: Double?
        public var band: String?, fatigue: Double?, typicalSession: Double?
    }

    public struct Balance: Encodable {
        public var axis: String, setsA: Int, setsB: Int, ratio: Double?, shareA: Double?, usualRatio: Range?
    }

    public struct Exercise: Encodable {
        public struct Choice: Encodable { public var id: String, title: String, sessions: Int }
        public struct Record: Encodable {
            public var value: Double, day: String, startTs: Int, workoutId: String, reps: Int?
            init(_ record: StrengthRecordPoint) {
                value = record.value; day = record.day; startTs = record.startTs
                workoutId = record.workoutId; reps = record.reps
            }
        }
        public var selectedId: String?
        public var choices: [Choice], points: [Point], trend: Trend?, isVolume: Bool
        public var heaviestSet: Record?, bestSessionVolume: Record?, bestEstimatedOneRepMax: Record?
        public var repRecords: [String: Record]
    }

    public struct Strength: Encodable {
        public struct LoggedSet: Encodable {
            public var type: String, countsAsWork: Bool
            public var weightKg: Double?, reps: Int?, rpe: Double?, durationS: Double?, distanceM: Double?
            init(_ value: HevySet) {
                type = value.type.rawValue; countsAsWork = value.type.countsAsWork
                weightKg = value.weightKg; reps = value.reps; rpe = value.rpe
                durationS = value.durationS; distanceM = value.distanceM
            }
        }
        public struct LoggedExercise: Encodable {
            public var title: String, sets: [LoggedSet]
            init(_ value: HevyExercise) {
                title = value.title; sets = value.sets.map(LoggedSet.init)
            }
        }
        public struct LoggedSession: Encodable {
            public var id: String, title: String, startTs: Int, durationS: Double?, source: String
            public var exercises: [LoggedExercise]
            init(_ value: HevyWorkout) {
                id = value.id; title = value.title; startTs = value.startTs
                durationS = value.durationS; source = value.source.rawValue
                exercises = value.exercises.map(LoggedExercise.init)
            }
            init(_ session: ResolvedStrengthSession) {
                self.init(session.workout)
                durationS = session.canonicalRow?.durationS ?? durationS
            }
        }
        public var selection: Selection, lane: CoreTrainingLoad.Lane, ratios: [CoreTrainingLoad.Ratio]
        public var sessions: Int, workingSets: Int, volumeSets: Int, volumeKg: Double, bodyweightKg: Double
        public var bodyweightSets: Int, unpricedBodyweightSets: Int, unattributedSets: Int
        public var charge: Double?, effort: Double?, overview: Overview, muscles: [Muscle], balance: [Balance]
        public var exercise: Exercise
        public var recentSessions: [LoggedSession], genericSessions: [GenericSession], unmappedExercises: [String]
    }

    public struct EntryDraft: Encodable {
        public var title: String, workSets: Int, muscle: String, effort: String, usesRIR: Bool
        init(_ draft: StrengthDetails.Draft) {
            title = draft.title; workSets = draft.workSets; muscle = draft.muscle.rawValue
            effort = draft.effort; usesRIR = draft.usesRIR
        }
    }

    public struct GenericSession: Encodable {
        public var id: String, title: String, startTs: Int, endTs: Int, source: String
        public var drafts: [EntryDraft]
        public var manualWorkoutId: String?
        init(_ entry: StrengthDetails.GenericSession, templates: [String: HevyExerciseTemplate]) {
            id = entry.session.id; title = entry.session.row.sport
            startTs = entry.session.row.startTs; endTs = entry.session.row.endTs
            source = entry.session.row.source; manualWorkoutId = entry.manual?.id
            drafts = StrengthDetails.drafts(from: entry.manual, templates: templates).map(EntryDraft.init)
        }
    }

    public struct CardioSession: Encodable {
        public var startTs: Int, endTs: Int, day: String, sport: String, source: String, modality: String, family: String
        public var durationS: Double?, distanceM: Double?, avgHr: Int?, maxHr: Int?
        public var energyKcal: Double?, strain: Double?, steps: Int?, cardioLoad: Double?
        public var paceSecPerKm: Double?, paceSecPer100m: Double?, speedKmh: Double?, beatsPerKm: Double?
        init(_ session: CardioSessionMetrics, family: String) {
            startTs = session.startTs; endTs = session.endTs; day = session.day; sport = session.sport
            source = session.source; modality = session.modality.rawValue; self.family = family
            durationS = session.durationS; distanceM = session.distanceM; avgHr = session.avgHr; maxHr = session.maxHr
            energyKcal = session.energyKcal; strain = session.strain; steps = session.steps; cardioLoad = session.cardioLoad
            paceSecPerKm = session.paceSecPerKm; paceSecPer100m = session.paceSecPer100m
            speedKmh = session.speedKmh; beatsPerKm = session.beatsPerKm
        }
    }

    public struct Sport: Encodable {
        public var name: String, modality: String, sessions: Int, minutes: Double, distanceM: Double, energyKcal: Double
    }

    public struct SportShare: Encodable {
        public var sport: String, modality: String, load: Double, share: Double
    }

    public struct Zones: Encodable {
        public var minutes: [Double], sessionsRead: Int, sessionsPossible: Int, usedMinuteBuckets: Bool
        init(_ zones: CardioZoneSplit) {
            minutes = zones.minutes; sessionsRead = zones.sessionsRead; sessionsPossible = zones.sessionsPossible
            usedMinuteBuckets = zones.usedMinuteBuckets
        }
    }

    public struct SportProgress: Encodable {
        public struct Best: Encodable {
            public var value: Double, day: String, startTs: Int, sport: String, distanceM: Double?, durationS: Double?
            init(_ best: CardioBest) {
                value = best.value; day = best.day; startTs = best.startTs; sport = best.sport
                distanceM = best.distanceM; durationS = best.durationS
            }
        }
        public var selectedSport: String?
        public var modality: String, metric: String
        public var choices: [String], pace: [Point], efficiency: [Point]
        public var paceTrend: Trend?, efficiencyTrend: Trend?
        public var farthest: Best?, longest: Best?, paceBests: [String: Best]
    }

    public struct Cardio: Encodable {
        public var selection: Selection, lane: CoreTrainingLoad.Lane?, ratios: [CoreTrainingLoad.Ratio]
        public var sessions: [CardioSession], weekSessions: Int, minutes: Double, distanceM: Double, energyKcal: Double
        public var effort: Double?, sessionsWithDistance: Int, typicalMinutes: Range?
        public var averageHr: Double?, typicalAverageHr: Double?, charge: Double?, topSportPace: Double?
        public var sports: [Sport], loadShares: [SportShare], zones: Zones?, progress: SportProgress
    }

    /// Reads the same Strength inputs as `StrengthModel.load`, with one supplied clock per request.
    public static func strength(reader: StoreReader, days: Int = 120, weekOffset: Int = 0,
                                exerciseId: String? = nil, firstWeekday: Int = 2,
                                dismissedWorkouts: [String] = [], now: Int = Int(Date().timeIntervalSince1970)) async -> Strength {
        let days = historyDays(days)
        let offset = TimeZone.current.secondsFromGMT()
        let store = reader.store
        let today = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now)))
        let fusion = await TrainingSessionResolver.read(reader: reader, from: now - days * 86_400,
                                                        to: now + 86_400, dismissedDetectedSpans: dismissedWorkouts)
        let history = await StrengthHistoryReader.read(store: store, days: days, now: now) { fusion }
        let laneDays = days + TrainingLoadLanes.lookbackDays
        let laneFusion = await TrainingSessionResolver.read(reader: reader, from: now - laneDays * 86_400,
                                                            to: now + 86_400, dismissedDetectedSpans: dismissedWorkouts)
        let laneHistory = await StrengthHistoryReader.read(store: store, days: laneDays, now: now) { laneFusion }
        let observations = ((try? await store.muscleRecoveryFeedback()) ?? []).compactMap { row in
            MuscleRecovery.Feeling(rawValue: row.feeling).map {
                MuscleRecovery.Observation(group: row.muscleGroup, ts: row.ts, feeling: $0)
            }
        }
        let prepared = StrengthPreparation.prepare(history: history, laneWorkouts: laneHistory.workouts,
                                                   observations: observations, now: now, historyDays: days,
                                                   offset: offset, firstWeekday: firstWeekday)
        var selection = Selection(days: days, requestedOffset: weekOffset,
                                  earliestDay: (history.workouts.map { AnalyticsEngine.dayString($0.startTs, offsetSec: offset) }
                                    + fusion.sessions.filter { $0.kind == .strength }.map { AnalyticsEngine.dayString($0.row.startTs, offsetSec: offset) }).min(),
                                  now: now)
        let anchor = WeeklyDigestEngine.addDays(today, selection.weekOffset * 7)
        let activity = TrainingLoadLanes.strengthActivity(laneHistory.workouts, tzOffsetSeconds: offset)
        selection.readingDay = TrainingLoadLanes.readingDay(monday: selection.monday,
            today: today, hasActivityToday: (activity.sessionsByDay[today] ?? 0) > 0)
        let weights = await WeightSeries.series(reader: reader,
            from: StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now - (days + BodyweightTimeline.maximumGapDays) * 86_400))),
            to: StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now + 86_400))))
        let week = StrengthPreparation.week(anchor: anchor, sessions: history.workouts, catalogue: history.templates,
            laneWorkouts: laneHistory.workouts, laneByDay: prepared.laneByDay, laneDay: selection.readingDay,
            laneActivity: activity, index: prepared.index,
            bodyweight: BodyweightTimeline(points: weights.map { ($0.day, $0.value) }), offset: offset)
        let daily = await dailyMetrics(reader: reader, from: selection.monday, to: selection.sunday)
        let charges = daily.compactMap(\.recovery), efforts = daily.compactMap(\.strain)
        let selected = exerciseId.flatMap { id in prepared.choices.contains { $0.templateId == id } ? id : nil }
            ?? StrengthPreparation.firstPlottable(in: prepared.choices, workouts: history.workouts,
                                                  templates: history.templates, tzOffsetSeconds: offset)
            ?? prepared.choices.first?.templateId
        let progress = selected.map { StrengthPreparation.exercise(id: $0, sessions: history.workouts,
                                                                    catalogue: history.templates, offset: offset) }
        let exercise = Exercise(selectedId: selected,
            choices: prepared.choices.map { .init(id: $0.templateId,
                title: history.templates[$0.templateId]?.title ?? $0.templateId, sessions: $0.sessions) },
            points: progress?.points.map { Point(day: $0.day, startTs: $0.startTs,
                                                 value: progress?.isVolume == true ? $0.volumeLoadKg : $0.bestE1RMKg) } ?? [],
            trend: progress?.line.map(Trend.init), isVolume: progress?.isVolume ?? false,
            heaviestSet: progress?.records.heaviestSet.map(Exercise.Record.init),
            bestSessionVolume: progress?.records.bestSessionVolume.map(Exercise.Record.init),
            bestEstimatedOneRepMax: progress?.records.bestE1RM.map(Exercise.Record.init),
            repRecords: progress?.records.bestByRepBand.reduce(into: [:]) { $0[$1.key.rawValue] = Exercise.Record($1.value) } ?? [:])
        return Strength(selection: selection, lane: CoreTrainingLoad.Lane(week.lane),
            ratios: week.laneRatios.map { .init(day: $0.day, strength: $0.strength, cardio: $0.cardio) },
            sessions: week.week.sessionCount, workingSets: week.week.workingSetCount,
            volumeSets: prepared.summaries.filter {
                let day = AnalyticsEngine.dayString($0.startTs, offsetSec: offset)
                return day >= selection.monday && day <= selection.sunday
            }.reduce(0) { $0 + $1.volumeSetCount }, volumeKg: week.week.volumeLoadKg,
            bodyweightKg: week.bodyweightKg, bodyweightSets: week.bodyweightSets,
            unpricedBodyweightSets: week.unpricedBodyweightSets, unattributedSets: week.week.unattributedSetCount,
            charge: average(charges), effort: efforts.isEmpty ? nil : efforts.reduce(0, +),
            overview: Overview(prepared.overview), muscles: HevyMuscleGroup.allCases.map {
                Muscle(id: $0.rawValue, primarySets: week.week.setsByMuscle[$0] ?? 0,
                    secondarySets: week.week.secondarySetsByMuscle[$0] ?? 0, usualSets: week.bands[$0].map(Range.init),
                    stimulus: week.stimulus[$0] ?? 0, usualStimulus: week.typical[$0], band: week.groupBands[$0]?.rawValue,
                    fatigue: prepared.fatigue[$0], typicalSession: prepared.typicalSession[$0])
            }, balance: week.balance.map {
                Balance(axis: $0.axis.rawValue, setsA: $0.setsA, setsB: $0.setsB, ratio: $0.ratio,
                        shareA: $0.shareA, usualRatio: week.ratios[$0.axis].map(Range.init))
            }, exercise: exercise,
            recentSessions: history.sessions.sorted { $0.startTs > $1.startTs }.prefix(30).map(Strength.LoggedSession.init),
            genericSessions: StrengthDetails.genericSessions(fusion, workouts: history.workouts)
                .sorted { $0.session.row.startTs > $1.session.row.startTs }
                .map { GenericSession($0, templates: history.templates) },
            unmappedExercises: prepared.unmapped)
    }

    /// Reads the same Cardio inputs as `CardioModel.load`, including all sport families and the
    /// wearer's supplied zone set. Measured zone minutes are never inferred from average heart rate.
    public static func cardio(reader: StoreReader, maxHR: Double, sex: String, days: Int = 120,
                              weekOffset: Int = 0, sport: String? = nil, zoneSet: HRZoneSet? = nil,
                              dismissedWorkouts: [String] = [], now: Int = Int(Date().timeIntervalSince1970)) async -> Cardio {
        let days = historyDays(days)
        let offset = TimeZone.current.secondsFromGMT()
        let today = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(now)))
        let cache = CardioLoadCache()
        let fusion = await TrainingSessionResolver.read(reader: reader, from: now - days * 86_400,
                                                        to: now + 86_400, dismissedDetectedSpans: dismissedWorkouts)
        let visible = fusion.sessions.filter { $0.kind != .strength }
        let resolution = await CardioLoadPricing.price(visible, reader: reader, maxHR: maxHR, sex: sex,
            dataRevision: 0, cache: cache, budget: CardioLoadPricing.cardioLoadSessionBudget, recompute: false).resolution
        let laneFusion = await TrainingSessionResolver.read(reader: reader,
            from: now - (days + TrainingLoadLanes.lookbackDays) * 86_400, to: now + 86_400,
            dismissedDetectedSpans: dismissedWorkouts)
        let laneResolution = await CardioLoadPricing.price(laneFusion.sessions, reader: reader, maxHR: maxHR, sex: sex,
            dataRevision: 0, cache: cache, budget: CardioLoadPricing.cardioLoadSessionBudget, recompute: false).resolution
        let loadByStart = visible.reduce(into: [Int: Double]()) { values, session in
            if let trimp = resolution.loads[session.id]?.trimp { values[session.row.startTs] = trimp }
        }
        let (sessions, choices) = CardioPreparation.sessions(rows: visible.map(\.row), loadByStart: loadByStart, offset: offset)
        let laneSeries = TrainingLoadLanes.cardioSeries(sessions: laneFusion.sessions,
                                                        resolution: laneResolution, tzOffsetSeconds: offset)
        var selection = Selection(days: days, requestedOffset: weekOffset, earliestDay: sessions.map(\.day).min(), now: now)
        selection.readingDay = TrainingLoadLanes.readingDay(monday: selection.monday, today: today,
            hasActivityToday: (laneSeries.activity.sessionsByDay[today] ?? 0) > 0)
        let anchor = WeeklyDigestEngine.addDays(today, selection.weekOffset * 7)
        let inWeek = visible.filter {
            let day = AnalyticsEngine.dayString($0.row.startTs, offsetSec: offset)
            return day >= selection.monday && day <= selection.sunday
        }
        let zones: CardioZoneSplit?
        if let zoneSet, !inWeek.isEmpty {
            zones = await CardioLoadPricing.sessionZoneMinutes(for: inWeek, reader: reader,
                zoneSet: zoneSet, duplicates: resolution.duplicateSessionIds)
        } else { zones = nil }
        let week = CardioPreparation.week(anchor: anchor, all: sessions, laneSessions: laneFusion.sessions,
            laneResolution: laneResolution, laneSeries: laneSeries, laneDay: selection.readingDay,
            offset: offset, zones: zones)
        let daily = await dailyMetrics(reader: reader, from: selection.monday, to: selection.sunday)
        let selected = sport.flatMap { name in choices.contains { $0.sport == name } ? name : nil } ?? choices.first?.sport
        let progress = selected.map { CardioPreparation.sport($0, all: sessions) }
        let modality = selected.map { CardioModality.of(sport: $0) } ?? .unknown
        let metric: String
        switch modality.readout { case .pace: metric = "pace"; case .speed: metric = "speed"; case .none: metric = "none" }
        let sportProgress = SportProgress(selectedSport: selected, modality: modality.rawValue, metric: metric, choices: choices.map(\.sport),
            pace: progress?.history.map { Point(day: $0.day, startTs: $0.startTs, value: modality.readout == .speed ? $0.speedKmh : (modality.readout == .pace ? $0.paceSecPerKm : nil)) } ?? [],
            efficiency: progress?.series.map { Point(day: $0.day, startTs: $0.startTs, value: $0.value) } ?? [],
            paceTrend: progress?.pace.map(Trend.init), efficiencyTrend: progress?.efficiency.map(Trend.init),
            farthest: progress?.bests.farthest.map(SportProgress.Best.init),
            longest: progress?.bests.longest.map(SportProgress.Best.init),
            paceBests: progress?.bests.fastestPaceByBand.reduce(into: [:]) {
                $0[$1.key.rawValue] = SportProgress.Best($1.value)
            } ?? [:])
        let families = visible.reduce(into: [Int: String]()) { $0[$1.row.startTs] = $1.kind.rawValue }
        return Cardio(selection: selection, lane: week.lane.map(CoreTrainingLoad.Lane.init),
            ratios: week.laneRatios.map { .init(day: $0.day, strength: $0.strength, cardio: $0.cardio) },
            sessions: sessions.map { CardioSession($0, family: families[$0.startTs] ?? "other") },
            weekSessions: week.week.sessionCount, minutes: week.week.minutes, distanceM: week.week.distanceM,
            energyKcal: week.week.energyKcal, effort: week.week.effort,
            sessionsWithDistance: week.week.sessionsWithDistance, typicalMinutes: week.typical.map(Range.init),
            averageHr: week.averageHr, typicalAverageHr: week.typicalAverageHr,
            charge: average(daily.compactMap(\.recovery)), topSportPace: week.topSportPace,
            sports: week.week.bySport.map {
                Sport(name: $0.sport, modality: $0.modality.rawValue, sessions: $0.sessionCount,
                      minutes: $0.minutes, distanceM: $0.distanceM, energyKcal: $0.energyKcal)
            }, loadShares: week.shares.map {
                SportShare(sport: $0.sport, modality: $0.modality.rawValue, load: $0.load, share: $0.share)
            }, zones: week.zones.map(Zones.init), progress: sportProgress)
    }

    public static func session(reader: StoreReader, id: String,
                               now: Int = Int(Date().timeIntervalSince1970)) async -> Strength.LoggedSession? {
        let fusion = await TrainingSessionResolver.read(reader: reader,
            from: now - TrainingHistoryWindow.allDays * 86_400, to: now + 86_400, dismissedDetectedSpans: [])
        let history = await StrengthHistoryReader.read(store: reader.store,
            days: TrainingHistoryWindow.allDays, now: now) { fusion }
        return history.sessions.first { $0.workout.id == id }.map(Strength.LoggedSession.init)
    }

    /// Re-resolve the canonical envelope before editing; repeat saves replace its manual detail.
    public static func saveDetails(reader: StoreReader, sessionId: String, drafts: [[String: Any]],
                                   dismissedWorkouts: [String], now: Int = Int(Date().timeIntervalSince1970)) async -> String {
        let days = TrainingHistoryWindow.allDays
        let fusion = await TrainingSessionResolver.read(reader: reader, from: now - days * 86_400,
            to: now + 86_400, dismissedDetectedSpans: dismissedWorkouts)
        let history = await StrengthHistoryReader.read(store: reader.store, days: days, now: now) { fusion }
        guard let entry = StrengthDetails.genericSessions(fusion, workouts: history.workouts)
            .first(where: { $0.session.id == sessionId }) else { return "sessionUnavailable" }
        guard drafts.count <= 100 else { return "invalidDetails" }
        var parsed: [StrengthDetails.Draft] = []
        for value in drafts {
            guard let title = value["title"] as? String, let count = value["workSets"] as? Int,
                  let rawMuscle = value["muscle"] as? String, let muscle = HevyMuscleGroup(rawValue: rawMuscle),
                  let effort = value["effort"] as? String, let usesRIR = value["usesRIR"] as? Bool else {
                return "invalidDetails"
            }
            var draft = StrengthDetails.Draft()
            draft.title = title; draft.workSets = count; draft.muscle = muscle
            draft.effort = effort; draft.usesRIR = usesRIR
            parsed.append(draft)
        }
        do {
            let built = try StrengthDetails.makeEntry(drafts: parsed, session: entry.session,
                existingId: entry.manual?.id, now: now)
            _ = try await reader.store.upsertHevyExerciseTemplates(built.templates)
            _ = try await reader.store.upsertStrengthWorkouts([built.workout])
            return "saved"
        } catch StrengthDetails.DraftError.noExercise { return "noExercise" }
          catch StrengthDetails.DraftError.effortOutOfRange { return "invalidEffort" }
          catch StrengthDetails.DraftError.setCountOutOfRange { return "invalidSets" }
          catch { return "saveFailed" }
    }

    public static func saveMapping(store: WhoopStore, title: String, primary: String, secondary: [String]) async -> Bool {
        guard let group = HevyMuscleGroup(rawValue: primary),
              secondary.allSatisfy({ HevyMuscleGroup(rawValue: $0) != nil }) else { return false }
        do {
            try await StrengthDetails.saveMapping(store: store, title: title, primary: group,
                secondary: secondary.compactMap(HevyMuscleGroup.init(rawValue:)))
            return true
        } catch { return false }
    }

    public static func recordFeedback(store: WhoopStore, muscle: String, feeling: Int,
                                      now: Int = Int(Date().timeIntervalSince1970)) async -> Bool {
        guard let group = HevyMuscleGroup(rawValue: muscle), MuscleRecovery.Feeling(rawValue: feeling) != nil else {
            return false
        }
        do {
            try await store.saveMuscleRecoveryFeedback(.init(muscleGroup: group, ts: now, feeling: feeling))
            return true
        } catch { return false }
    }

    static func historyDays(_ days: Int) -> Int {
        [120, 365, TrainingHistoryWindow.allDays].contains(days) ? days : 120
    }

    /// Training reads non-sleep outcomes from the same imported-over-computed merge as Repository.days.
    /// Sleep edits and wake-day suppression change only sleep fields, which these reports do not read.
    static func dailyMetrics(reader: StoreReader, from: String, to: String) async -> [DailyMetric] {
        let imported = await reader.unionDailyMetrics(from: from, to: to)
        let computed = await reader.unionComputedDailyMetrics(from: from, to: to)
        return StoreReader.mergeDaily(imported: imported, computed: computed)
    }

    static func average(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
