import Foundation
import StrandAnalytics
import StrandTraining
import WhoopStore

/// One detailed set log selected for one real workout. The canonical id belongs to session fusion;
/// `workout` keeps the source's original exercises and measurements unchanged.
struct ResolvedStrengthSession: Identifiable, Sendable {
    struct Exercise: Sendable {
        let source: HevyExercise
        let anatomy: ExerciseAnatomy?
    }

    let id: String
    let workout: HevyWorkout
    let exercises: [Exercise]
    let canonicalRow: WorkoutRow?

    var startTs: Int { workout.startTs }
    var endTs: Int { workout.endTs }
    var durationS: Double { canonicalRow?.durationS ?? workout.durationS ?? 0 }
    var workingSetCount: Int { exercises.reduce(0) { $0 + $1.source.workingSets.count } }
    var hasUnmappedSets: Bool {
        exercises.contains { $0.anatomy == nil && !$0.source.workingSets.isEmpty }
    }
}

/// One definition of "all history" for every training surface.
enum TrainingHistoryWindow {
    static let allDays = 20 * 365 + 5
}

struct ResolvedStrengthHistory: Sendable {
    let sessions: [ResolvedStrengthSession]
    let workouts: [HevyWorkout]
    let templates: [String: HevyExerciseTemplate]
    /// Start of the repository query, including weeks with no workout. This is the evidence needed to
    /// distinguish a genuinely complete eight-week baseline from eight workouts spread over years.
    let historyAvailableFrom: Int?

    /// The window every "all history" training view reads, so Training, Strength and Cardio agree on
    /// what "All" means.
    static let allHistoryDays = TrainingHistoryWindow.allDays

    init(sessions: [ResolvedStrengthSession], workouts: [HevyWorkout],
         templates: [String: HevyExerciseTemplate], historyAvailableFrom: Int? = nil) {
        self.sessions = sessions
        self.workouts = workouts
        self.templates = templates
        self.historyAvailableFrom = historyAvailableFrom
    }

    var unmappedExerciseTitles: [String] {
        Array(Set(sessions.flatMap(\.exercises).filter { $0.anatomy == nil }
            .map { $0.source.title })).sorted()
    }

    /// Projects the selected canonical set log onto the provider-neutral muscle metric seam. Exercise
    /// ids use reviewed anatomy ids where possible, so the same lift imported from different providers
    /// contributes to one strength trend without copying either workout.
    func muscleMetricSets() -> [MuscleMetricSet] {
        let reference = MuscleStimulus.StrengthReference(workouts: workouts, templates: templates)
        return sessions.flatMap { session in
            session.exercises.flatMap { exercise -> [MuscleMetricSet] in
                let template = exercise.source.templateId.flatMap { templates[$0] }
                let exerciseId = exercise.anatomy?.id
                    ?? exercise.source.templateId
                    ?? "unmapped:\(exercise.source.title.lowercased())"
                return exercise.source.sets.map { set in
                    MuscleMetricSet(
                        sessionId: session.id,
                        sessionTitle: session.workout.title,
                        exerciseId: exerciseId,
                        exerciseTitle: exercise.source.title,
                        startTs: session.startTs,
                        isWarmup: set.type == .warmup,
                        rpeWasRecorded: set.rpe != nil,
                        stimulus: MuscleStimulus.setStimulus(
                            set, templateId: exercise.source.templateId, template: template,
                            at: session.startTs, reference: reference),
                        estimatedOneRepMaxKg: OneRepMax.forSet(set, template: template),
                        primaryMuscleIds: exercise.anatomy?.primaryMuscleIds ?? [],
                        secondaryMuscleIds: exercise.anatomy?.secondaryMuscleIds ?? [],
                        stabilizerMuscleIds: exercise.anatomy?.stabilizerMuscleIds ?? [])
                }
            }
        }
    }
}

/// Detailed muscle exposure from the shared, de-duplicated strength history. Primary muscles receive
/// full credit and secondary muscles half credit. Stabilizers remain catalogue metadata only.
struct DetailedMuscleLoadSnapshot: Sendable {
    let byMuscle: [String: Double]
    let workingSets: Int
    let mappedSets: Int
    let ratedSets: Int

    var hasUnmappedSets: Bool { mappedSets < workingSets }

    static func volume(history: ResolvedStrengthHistory, from: Int, to: Int) -> Self {
        priced(history: history, from: from, to: to, decayingTo: nil)
    }

    static func current(history: ResolvedStrengthHistory, now: Int) -> Self {
        priced(history: history, from: now - 21 * 86_400, to: now, decayingTo: now)
    }

    private static func priced(history: ResolvedStrengthHistory, from: Int, to: Int,
                               decayingTo now: Int?) -> Self {
        let reference = MuscleStimulus.StrengthReference(workouts: history.workouts,
                                                         templates: history.templates)
        var values: [String: Double] = [:]
        var working = 0, mapped = 0, rated = 0
        for session in history.sessions where session.startTs >= from && session.startTs <= to {
            for exercise in session.exercises {
                let template = exercise.source.templateId.flatMap { history.templates[$0] }
                for set in exercise.source.workingSets {
                    working += 1
                    if set.rpe != nil { rated += 1 }
                    guard let anatomy = exercise.anatomy else { continue }
                    mapped += 1
                    var amount = MuscleStimulus.setStimulus(
                        set, templateId: exercise.source.templateId, template: template,
                        at: session.startTs, reference: reference)
                    if let now {
                        let age = Double(max(0, now - session.startTs))
                        amount *= exp(-age / (72 * 3_600))
                    }
                    for muscle in anatomy.primaryMuscleIds { values[muscle, default: 0] += amount }
                    for muscle in anatomy.secondaryMuscleIds {
                        values[muscle, default: 0] += amount * MuscleStimulus.secondaryShare
                    }
                }
            }
        }
        return .init(byMuscle: values, workingSets: working, mappedSets: mapped, ratedSets: rated)
    }
}

extension Repository {
    /// One read model for Strength, Training, Training Load and the Coach. Detailed set providers are
    /// selected once; tracker and Apple Health components enrich the canonical envelope without
    /// duplicating the set list.
    func resolvedStrengthHistory(days: Int = 4_000) async -> ResolvedStrengthHistory {
        let now = Int(Date().timeIntervalSince1970)
        let from = now - days * 86_400
        guard let store = await storeHandle() else {
            return .init(sessions: [], workouts: [], templates: [:], historyAvailableFrom: from)
        }
        async let importedRead = Self.pagedStrengthWorkouts(store: store, from: from, to: now + 86_400)
        async let templateRead = store.strengthExerciseTemplates()
        async let nativeWorkoutRead = Self.pagedNativeWorkouts(store: store, from: from, to: now + 86_400)
        async let nativeExerciseRead = store.trainingExercises()
        async let aliasRead = store.trainingExerciseAnatomyAliases()
        async let fusionRead = trainingSessions(days: days)

        let imported = (try? await importedRead) ?? []
        let importedTemplates = (try? await templateRead) ?? [:]
        let nativeWorkouts = (try? await nativeWorkoutRead) ?? []
        let nativeExercises = (try? await nativeExerciseRead) ?? []
        let aliases = (try? await aliasRead) ?? []
        let fusion = await fusionRead
        let native = NativeTrainingProjection.strength(workouts: nativeWorkouts, exercises: nativeExercises)
        var templates = importedTemplates
        templates.merge(native.templates) { imported, _ in imported }

        let nativeDefinitions = Dictionary(uniqueKeysWithValues: nativeExercises.map { ($0.id, $0) })
        let candidates = imported + native.workouts
        var used = Set<String>()
        var resolved: [ResolvedStrengthSession] = []

        for envelope in fusion.sessions.filter({ $0.kind == .strength }) {
            let matches = candidates.filter { Self.overlaps($0, envelope.row) > 0.8 }
            guard let chosen = matches.max(by: { Self.detailPriority($0) < Self.detailPriority($1) }) else { continue }
            guard !used.contains(chosen.id) else { continue }
            used.formUnion(matches.map(\.id))
            resolved.append(Self.resolve(chosen, canonicalId: envelope.id, row: envelope.row,
                                    templates: templates, native: nativeDefinitions,
                                    aliases: aliases))
        }
        // A detailed import can exist before its lightweight envelope has been refreshed. Keep it
        // visible rather than waiting for another launch, while preserving its stable source id.
        for workout in candidates where used.insert(workout.id).inserted {
            resolved.append(Self.resolve(workout, canonicalId: "detail|\(workout.id)", row: nil,
                                    templates: templates, native: nativeDefinitions,
                                    aliases: aliases))
        }
        resolved.sort { $0.startTs > $1.startTs }
        return .init(sessions: resolved, workouts: resolved.map(\.workout), templates: templates,
                     historyAvailableFrom: from)
    }

    private nonisolated static func pagedStrengthWorkouts(store: WhoopStore, from: Int,
                                                           to: Int) async -> [HevyWorkout] {
        let pageSize = 500
        var offset = 0
        var values: [HevyWorkout] = []
        while true {
            let page = (try? await store.strengthWorkouts(from: from, to: to,
                                                          limit: pageSize, offset: offset)) ?? []
            guard !page.isEmpty else { break }
            values.append(contentsOf: page)
            offset += pageSize
        }
        return values
    }

    private nonisolated static func pagedNativeWorkouts(store: WhoopStore, from: Int,
                                                         to: Int) async -> [NativeWorkout] {
        let pageSize = 500
        var offset = 0
        var values: [NativeWorkout] = []
        while true {
            let page = (try? await store.nativeWorkouts(from: from, to: to,
                                                        limit: pageSize, offset: offset)) ?? []
            values.append(contentsOf: page)
            guard page.count == pageSize else { break }
            offset += pageSize
        }
        return values
    }

    private nonisolated static func resolve(_ workout: HevyWorkout, canonicalId: String,
                                            row: WorkoutRow?, templates: [String: HevyExerciseTemplate],
                                            native: [String: TrainingExercise],
                                            aliases: [TrainingExerciseAnatomyAlias]) -> ResolvedStrengthSession {
        let exercises = workout.exercises.map { exercise -> ResolvedStrengthSession.Exercise in
            let definition = exercise.templateId.flatMap { native[$0] }
            let template = exercise.templateId.flatMap { templates[$0] }
            let recordSource = trainingSource(workout.source)
            let normalized = ExerciseAnatomyCatalog.normalize(template?.title ?? exercise.title)
            let stored = aliases.first { alias in
                if alias.origin == "user" { return alias.normalizedTitle == normalized }
                return alias.source == recordSource && alias.sourceExerciseId != nil
                    && alias.sourceExerciseId == exercise.templateId
            }?.anatomy
            let anatomy = stored ?? definition.flatMap { item in
                ExerciseAnatomyCatalog.resolve(title: item.title, source: recordSource,
                                               sourceId: item.id, equipmentIds: item.equipmentIds,
                                               mode: item.mode)
            } ?? ExerciseAnatomyCatalog.resolve(
                title: template?.title ?? exercise.title, source: recordSource,
                sourceId: exercise.templateId, equipmentIds: equipmentIds(template?.equipment),
                mode: measurementMode(template?.type))
                ?? template.flatMap(fallbackAnatomy)
            return .init(source: exercise, anatomy: anatomy)
        }
        return .init(id: canonicalId, workout: workout, exercises: exercises, canonicalRow: row)
    }

    private nonisolated static func overlaps(_ workout: HevyWorkout, _ row: WorkoutRow) -> Double {
        let overlap = max(0, min(workout.endTs, row.endTs) - max(workout.startTs, row.startTs))
        let shorter = max(1, min(workout.endTs - workout.startTs, row.endTs - row.startTs))
        return Double(overlap) / Double(shorter)
    }

    private nonisolated static func detailPriority(_ workout: HevyWorkout) -> Int {
        let source: Int
        switch workout.source {
        case .noopNative: source = 600
        case .hevyAPI: source = 500
        case .hevyCSV, .strong, .fitNotes, .liftosaur, .imported: source = 400
        case .manual: source = 300
        }
        return source + min(99, workout.exercises.flatMap(\.workingSets).count)
    }

    private nonisolated static func trainingSource(_ source: StrengthDataSource) -> TrainingRecordSource {
        switch source {
        case .noopNative: return .noopNative
        case .hevyAPI: return .hevyAPI
        case .hevyCSV: return .hevyCSV
        case .liftosaur: return .liftosaur
        case .fitNotes: return .fitNotes
        case .strong: return .strong
        case .imported, .manual: return .imported
        }
    }

    private nonisolated static func measurementMode(_ raw: String?) -> TrainingMeasurementMode? {
        guard let raw else { return nil }
        if let exact = TrainingMeasurementMode(rawValue: raw) { return exact }
        return raw == "reps_only" ? .repetitions : nil
    }

    private nonisolated static func equipmentIds(_ equipment: HevyEquipment?) -> [String] {
        guard let equipment else { return [] }
        switch equipment {
        case .none: return ["bodyweight"]
        case .resistanceBand: return ["resistance-band"]
        default: return [equipment.rawValue]
        }
    }

    /// Coarse source anatomy is the final honest fallback. It keeps a standard provider exercise on
    /// the map while its title is absent from the reviewed detailed catalogue, and carries the lower
    /// confidence so the app can still ask once for genuinely custom content.
    private nonisolated static func fallbackAnatomy(_ template: HevyExerciseTemplate) -> ExerciseAnatomy? {
        let primary = detailedIds(template.primaryMuscleGroup)
        guard !primary.isEmpty else { return nil }
        let secondary = template.secondaryMuscleGroups.flatMap(detailedIds)
        return ExerciseAnatomy(
            id: "source:\(template.id)", title: template.title,
            mode: measurementMode(template.type) ?? .weightReps,
            movementPattern: .other, primaryMuscleIds: primary,
            secondaryMuscleIds: secondary.filter { !primary.contains($0) },
            equipmentIds: equipmentIds(template.equipment),
            providerIds: [TrainingRecordSource.hevyAPI.rawValue: template.id],
            confidence: .sourceFallback)
    }

    private nonisolated static func detailedIds(_ group: HevyMuscleGroup) -> [String] {
        switch group {
        case .abdominals: return ["abdominals"]
        case .shoulders: return ["front_delts", "side_delts", "rear_delts"]
        case .biceps: return ["biceps"]
        case .triceps: return ["triceps"]
        case .forearms: return ["forearms"]
        case .quadriceps: return ["quadriceps"]
        case .hamstrings: return ["hamstrings"]
        case .calves: return ["calves"]
        case .glutes: return ["glutes"]
        case .abductors: return ["abductors"]
        case .adductors: return ["adductors"]
        case .lats: return ["lats"]
        case .upperBack: return ["upper_back"]
        case .traps: return ["traps"]
        case .lowerBack: return ["lower_back"]
        case .chest: return ["chest"]
        case .neck: return ["neck"]
        case .cardio, .fullBody, .other: return []
        }
    }
}
