import Foundation
import StrandAnalytics
import StrandCore
import StrandTraining
import WhoopStore

/// One resolved session, its actual set transcript and the recording-source physiology.
public enum CoreTrainingSession {
    public struct HeartPoint: Encodable { public var ts: Int, bpm: Double }
    public struct Rating: Encodable {
        public var id: String, rpe: Double, loadAU: Double?, timing: String
        public var durationMinutes: Double?, ratedAtTs: Int?
        init(_ entry: SessionRPEEntry, durationS: Double?) {
            id = entry.id; rpe = entry.rpe; loadAU = entry.load(durationS: durationS)
            timing = entry.timing(durationS: durationS).rawValue
            durationMinutes = SessionRPEEntry.durationMinutes(durationS); ratedAtTs = entry.ratedAtTs
        }
    }
    public struct Set: Encodable {
        public var index: Int, type: String, isWorking: Bool
        public var weightKg: Double?, reps: Int?, leftReps: Int?, rightReps: Int?
        public var durationS: Double?, distanceM: Double?, rpe: Double?, e1rmKg: Double?, bodyweightLoadKg: Double?
        init(_ line: StrengthSetLine, native: NativeWorkoutSet?) {
            index = line.index; type = line.type.rawValue; isWorking = line.isWorking
            weightKg = line.weightKg; reps = line.reps; leftReps = native?.leftReps; rightReps = native?.rightReps
            durationS = line.durationS; distanceM = line.distanceM; rpe = line.rpe
            e1rmKg = line.e1rmKg; bodyweightLoadKg = line.bodyweightLoadKg
        }
    }
    public struct Exercise: Encodable {
        public var title: String, kind: String, notes: String?, primary: String?, secondary: [String]
        public var workingSets: Int, topSetKg: Double?, sets: [Set]
        init(_ block: StrengthExerciseBlock, native: NativeWorkoutExercise?) {
            title = block.title; kind = block.kind.rawValue; notes = block.notes
            primary = block.primaryMuscle?.rawValue; secondary = block.secondaryMuscles.map(\.rawValue)
            workingSets = block.workingSetCount; topSetKg = block.topSetKg
            sets = block.sets.map { line in
                Set(line, native: native.flatMap { $0.sets.indices.contains(line.index) ? $0.sets[line.index] : nil })
            }
        }
    }
    public struct Summary: Encodable {
        public var workingSets: Int, exerciseCount: Int, volumeSets: Int, ratedSets: Int
        public var volumeKg: Double, bodyweightVolumeKg: Double, unpricedBodyweightSets: Int
        public var meanRPE: Double?, densityKgPerMinute: Double?
        init(_ detail: StrengthSessionBreakdown, durationS: Double?) {
            let s = detail.summary
            workingSets = s.workingSetCount; exerciseCount = s.exerciseCount; volumeSets = s.volumeSetCount
            ratedSets = s.rpeSetCount; volumeKg = s.volumeLoadKg; meanRPE = s.meanRpe
            bodyweightVolumeKg = detail.bodyweightVolumeKg; unpricedBodyweightSets = detail.unpricedBodyweightSetCount
            densityKgPerMinute = s.workingSetCount > 0 && Double(s.volumeSetCount) / Double(s.workingSetCount) >= 0.6
                && durationS == detail.durationS ? detail.densityKgPerMinute : nil
        }
    }
    public struct Output: Encodable {
        public var id: String, canonicalId: String?, title: String, source: String, kind: String
        public var startTs: Int, endTs: Int, durationS: Double?, notes: String?
        public var avgHr: Int?, maxHr: Int?, distanceM: Double?, energyKcal: Double?
        public var summary: Summary?, groups: [[Exercise]]
        public var heartRate: [HeartPoint], zoneMinutes: [Double]?, bucketSeconds: Int
        public var rating: Rating?
    }

    struct Selection {
        var canonicalId: String?, row: WorkoutRow?, detailed: ResolvedStrengthSession?, kind: String
        var templates: [String: HevyExerciseTemplate]
        var start: Int { detailed?.startTs ?? row?.startTs ?? 0 }
        var end: Int { detailed?.endTs ?? row?.endTs ?? 0 }
        var duration: Double? { row?.durationS ?? detailed?.workout.durationS }
        var title: String { detailed?.workout.title ?? row?.sport ?? "" }
    }

    static func select(reader: StoreReader, id: String, dismissed: [String], now: Int) async -> Selection? {
        let days = TrainingHistoryWindow.allDays
        let fusion = await TrainingSessionResolver.read(reader: reader, from: now - days * 86_400,
            to: now + 86_400, dismissedDetectedSpans: dismissed)
        let history = await StrengthHistoryReader.read(store: reader.store, days: days, now: now) { fusion }
        if let detail = history.sessions.first(where: { $0.id == id || $0.workout.id == id }) {
            let canonical = fusion.sessions.first { $0.id == detail.id }
            return Selection(canonicalId: canonical?.id, row: detail.canonicalRow, detailed: detail, kind: "strength", templates: history.templates)
        }
        guard let session = fusion.sessions.first(where: { $0.id == id }) else { return nil }
        return Selection(canonicalId: session.id, row: session.row, detailed: nil, kind: session.kind.rawValue, templates: history.templates)
    }

    public static func read(reader: StoreReader, id: String, zoneSet: HRZoneSet,
                            dismissed: [String], now: Int = Int(Date().timeIntervalSince1970)) async -> Output? {
        guard let s = await select(reader: reader, id: id, dismissed: dismissed, now: now) else { return nil }
        let source = s.row?.source ?? s.detailed?.workout.source.rawValue ?? ""
        async let buckets = WorkoutPhysiology.buckets(reader: reader, from: s.start, to: s.end, source: source)
        async let zones = WorkoutPhysiology.zoneMinutes(reader: reader, from: s.start, to: s.end, zoneSet: zoneSet, source: source)
        var groups: [[Exercise]] = []
        var summary: Summary?
        if let detailed = s.detailed {
            let from = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(s.start - BodyweightTimeline.maximumGapDays * 86_400)))
            let to = StoreReader.localDayKey(Date(timeIntervalSince1970: TimeInterval(min(now + 86_400, s.end + BodyweightTimeline.maximumGapDays * 86_400))))
            let weights = await WeightSeries.series(reader: reader, from: from, to: to)
            let timeline = BodyweightTimeline(points: weights.map { ($0.day, $0.value) })
            let offset = TimeZone.current.secondsFromGMT()
            let detail = StrengthDetail.breakdown(detailed.workout, templates: s.templates,
                bodyweightKgAt: { timeline.kg(at: $0, tzOffsetSeconds: offset) })
            summary = Summary(detail, durationS: s.duration)
            var native: NativeWorkout?
            if detailed.workout.id.hasPrefix("noop-native:"),
               let uuid = UUID(uuidString: String(detailed.workout.id.dropFirst("noop-native:".count))) {
                native = (try? await reader.store.nativeWorkouts(from: s.start, to: s.end))?.first { $0.id == uuid }
            }
            groups = detail.groups.map { blocks in blocks.map { block in
                Exercise(block, native: native.flatMap { $0.exercises.indices.contains(block.index) ? $0.exercises[block.index] : nil })
            } }
        }
        let rating = await rating(reader: reader, selection: s)
        return await Output(id: id, canonicalId: s.canonicalId, title: s.title,
            source: s.detailed?.workout.source.rawValue ?? source, kind: s.kind,
            startTs: s.start, endTs: s.end, durationS: s.duration,
            notes: s.detailed?.workout.notes ?? s.row?.notes, avgHr: s.row?.avgHr, maxHr: s.row?.maxHr,
            distanceM: s.row?.distanceM, energyKcal: s.row?.energyKcal,
            summary: summary, groups: groups, heartRate: buckets.map { HeartPoint(ts: $0.ts, bpm: $0.bpm) },
            zoneMinutes: zones, bucketSeconds: WorkoutPhysiology.bucketSeconds(from: s.start, to: s.end),
            rating: rating.map { Rating($0, durationS: s.duration) })
    }

    private static func rating(reader: StoreReader, selection s: Selection) async -> SessionRPEEntry? {
        let rows = await SessionRPEEntry.read(store: reader.store, from: 0, to: Int.max)
        return SessionRPEEntry.latest(rows, sessionId: s.canonicalId, startTs: s.start)
    }

    public static func rate(reader: StoreReader, id: String, rpe: Double?, remove: Bool, dismissed: [String],
                            now: Int = Int(Date().timeIntervalSince1970)) async -> Bool {
        guard let s = await select(reader: reader, id: id, dismissed: dismissed, now: now) else { return false }
        if remove {
            guard let existing = await rating(reader: reader, selection: s) else { return false }
            return await SessionRPEEntry.remove(store: reader.store, entry: existing)
        }
        guard let rpe else { return false }
        return await SessionRPEEntry.record(store: reader.store, rpe: rpe, startTs: s.start,
            sport: s.title, sessionId: s.canonicalId, ratedAtTs: now)
    }
}
