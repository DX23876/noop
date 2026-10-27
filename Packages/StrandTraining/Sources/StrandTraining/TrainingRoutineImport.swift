import Foundation

/// Routines read from another app, ready to be added to NOOP's plan. Nothing here touches workouts:
/// a routine import carries prescriptions only, never history, tracker identities or body data.
///
/// Every routine id is derived from the source's own routine id, so importing the same routine again
/// updates the copy an earlier import made instead of adding a second one.
public struct TrainingRoutineImport: Equatable, Sendable {
    public var routines: [TrainingRoutine]
    /// The source's weekly schedule, by imported routine id. Applied only when the wearer asks for it.
    public var schedule: [TrainingWeekday: [UUID]]
    /// Exercises the routines need that NOOP does not already have.
    public var newExercises: [TrainingExercise]
    /// Exercises left out because the source names one NOOP cannot resolve.
    public var skippedExercises: Int

    public init(routines: [TrainingRoutine], schedule: [TrainingWeekday: [UUID]] = [:],
                newExercises: [TrainingExercise] = [], skippedExercises: Int = 0) {
        self.routines = routines
        self.schedule = schedule
        self.newExercises = newExercises
        self.skippedExercises = skippedExercises
    }

    /// The same routines without the ones whose ids are not in `kept`, and a schedule that names only
    /// what is left. New exercises no remaining routine uses are dropped too.
    public func keeping(_ kept: Set<UUID>) -> TrainingRoutineImport {
        let routines = routines.filter { kept.contains($0.id) }
        let used = Set(routines.flatMap { $0.exercises.map(\.exerciseId) })
        return TrainingRoutineImport(
            routines: routines,
            schedule: schedule.compactMapValues { ids in
                let left = ids.filter(kept.contains)
                return left.isEmpty ? nil : left
            },
            newExercises: newExercises.filter { used.contains($0.id) },
            skippedExercises: skippedExercises)
    }

    /// The plan archive NOOP's own plan import already knows how to merge.
    public func archive(includingSchedule: Bool, weekStartsOn: TrainingWeekStart) -> TrainingPlanArchive {
        var archive = TrainingPlanArchive(
            plan: TrainingPlan(routines: routines, schedule: includingSchedule ? schedule : [:],
                               overrides: [], weekStartsOn: weekStartsOn),
            exercises: [])
        archive.exercises = newExercises
        return archive
    }

    static func routineId(source: String, id: String) -> UUID {
        TrainingCSVImporter.deterministicUUID("routine:\(source):\(id)")
    }
}

public enum TrainingRoutineImportError: Error, Equatable {
    /// The file is not the kind of plan this importer reads.
    case notAPlan
    /// The file is a plan, but none of its routines kept a single exercise.
    case noRoutines
}

// MARK: - OpenGym

/// Reads the plan file OpenGym writes from Plan › Export plan file. Its exercise ids are ExerciseDB
/// numbers, the same catalogue NOOP ships, so a built-in exercise maps onto `exdb:<id>` directly.
/// Custom exercises come along in the file and become NOOP exercises of the wearer's own.
///
/// The format is read from what OpenGym writes; no OpenGym code is used. Progression rules and cardio
/// entries are left out: the two apps progress differently, and a cardio slot has no set to plan.
public enum OpenGymPlanImporter {
    public static let source = "opengym"
    static let poundsToKilograms = 0.45359237

    public static func parse(_ data: Data, existingExercises: [TrainingExercise] = [],
                             catalog: [TrainingExercise] = BundledExerciseCatalog.exercises,
                             defaultRestSeconds: Int = 120,
                             now: Int = Int(Date().timeIntervalSince1970)) throws -> TrainingRoutineImport {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["opengym_plan"] != nil,
              let rawRoutines = root["routines"] as? [[String: Any]] else {
            throw TrainingRoutineImportError.notAPlan
        }
        let toKilograms: Double
        switch (root["unit"] ?? root["weightUnit"]) as? String {
        case "lb", "lbs": toKilograms = poundsToKilograms
        default: toKilograms = 1
        }

        let byCatalogId = Dictionary(catalog.compactMap { exercise in exercise.sourceId.map { ($0, exercise) } },
                                     uniquingKeysWith: { first, _ in first })
        var known = Dictionary(existingExercises.map { (TrainingCSVImporter.normalizeName($0.title), $0) },
                               uniquingKeysWith: { first, _ in first })
        var newExercises: [TrainingExercise] = []
        var customById: [String: TrainingExercise] = [:]
        for raw in (root["customEx"] as? [[String: Any]]) ?? [] {
            guard let id = string(raw["id"]), let name = string(raw["n"]) else { continue }
            let key = TrainingCSVImporter.normalizeName(name)
            if let existing = known[key] { customById[id] = existing; continue }
            let exercise = TrainingExercise(
                id: "imported:opengym:\(TrainingCSVImporter.stableSlug(name))", title: name,
                mode: string(raw["bp"]) == "cardio" ? .duration : .weightReps,
                equipmentIds: string(raw["eq"]).map { [$0] } ?? [],
                instructions: string(raw["desc"]).map { [$0] } ?? [],
                source: .imported, sourceId: id, attribution: "OpenGym")
            known[key] = exercise
            customById[id] = exercise
            newExercises.append(exercise)
        }

        var skipped = 0
        var routines: [TrainingRoutine] = []
        var routineIds: [String: UUID] = [:]
        for raw in rawRoutines {
            let sourceId = string(raw["id"]) ?? string(raw["name"]) ?? UUID().uuidString
            var supersets: [String: UUID] = [:]
            var exercises: [RoutineExercise] = []
            for slot in (raw["ex"] as? [[String: Any]]) ?? [] {
                guard let id = string(slot["id"]),
                      let exercise = customById[id] ?? byCatalogId[id],
                      slot["min"] == nil, slot["speed"] == nil else { skipped += 1; continue }
                let superset = string(slot["sg"]).map { group in
                    if let known = supersets[group] { return known }
                    let fresh = UUID()
                    supersets[group] = fresh
                    return fresh
                }
                exercises.append(RoutineExercise(
                    exerciseId: exercise.id,
                    sets: openGymSets(slot, mode: exercise.mode, toKilograms: toKilograms),
                    restSeconds: positiveInt(slot["restSec"]) ?? defaultRestSeconds,
                    warmupRestSeconds: positiveInt(slot["warmupRestSec"]),
                    supersetId: superset,
                    note: string(slot["note"])))
            }
            guard !exercises.isEmpty else { continue }
            let id = TrainingRoutineImport.routineId(source: source, id: sourceId)
            routineIds[sourceId] = id
            routines.append(TrainingRoutine(
                id: id, title: string(raw["name"]) ?? "OpenGym", exercises: exercises,
                excludeFromProgression: (raw["excludeFromProgression"] as? Bool) == true,
                createdAt: now, updatedAt: now))
        }
        guard !routines.isEmpty else { throw TrainingRoutineImportError.noRoutines }

        // OpenGym keys its week by JavaScript's day number: 0 is Sunday, 1 Monday through 6 Saturday.
        var schedule: [TrainingWeekday: [UUID]] = [:]
        for (key, value) in (root["week"] as? [String: Any]) ?? [:] {
            guard let number = Int(key), (0...6).contains(number),
                  let weekday = TrainingWeekday(rawValue: number == 0 ? 7 : number) else { continue }
            let ids = ((value as? [Any]) ?? [value]).compactMap { string($0).flatMap { routineIds[$0] } }
            if !ids.isEmpty { schedule[weekday] = ids }
        }
        let used = Set(routines.flatMap { $0.exercises.map(\.exerciseId) })
        return TrainingRoutineImport(routines: routines, schedule: schedule,
                                     newExercises: newExercises.filter { used.contains($0.id) },
                                     skippedExercises: skipped)
    }

    /// Warm-ups first, then the work sets: a pyramid's own repetitions and loads where it has them,
    /// otherwise `sets` alike. A drop or rest-pause follows the last work set, as OpenGym prescribes it.
    static func openGymSets(_ slot: [String: Any], mode: TrainingMeasurementMode,
                            toKilograms: Double) -> [RoutineSetPlan] {
        let timed = string(slot["mode"]) == "time" || mode == .duration
        let weight = positiveDouble(slot["weight"]).map { $0 * toKilograms }
        let seconds = positiveInt(slot["sec"])
        let low = positiveInt(slot["repsMin"]) ?? positiveInt(slot["reps"])
        let high = positiveInt(slot["repsMax"]) ?? positiveInt(slot["reps"])
        func work(reps: Int?, load: Double?, intensifier: TrainingSetIntensifier = .none) -> RoutineSetPlan {
            timed
                ? RoutineSetPlan(intensifier: intensifier, targetWeightKg: load, targetDurationS: seconds)
                : RoutineSetPlan(intensifier: intensifier, targetWeightKg: load,
                                 repsMin: reps ?? low, repsMax: reps ?? high)
        }

        var sets = (0..<min(5, positiveInt(slot["warmupSets"]) ?? 0)).map { _ in
            RoutineSetPlan(phase: .warmup, repsMin: timed ? nil : low, repsMax: timed ? nil : low,
                           targetDurationS: timed ? seconds : nil)
        }
        if let pyramid = slot["pyramid"] as? [Any], !pyramid.isEmpty, !timed {
            let loads = (slot["pyramidWeight"] as? [Any]) ?? []
            for (index, step) in pyramid.prefix(20).enumerated() {
                let load = index < loads.count ? positiveDouble(loads[index]).map { $0 * toKilograms } : nil
                if let reps = positiveInt(step) {
                    sets.append(work(reps: reps, load: load ?? weight))
                } else {
                    // A step that is not a number ("Max") asks for as many repetitions as possible.
                    sets.append(RoutineSetPlan(intensifier: .amrap, targetWeightKg: load ?? weight))
                }
            }
        } else {
            sets += (0..<min(20, max(1, positiveInt(slot["sets"]) ?? 1))).map { _ in work(reps: nil, load: weight) }
        }
        if (slot["lastToFailure"] as? Bool) == true, let last = sets.lastIndex(where: { $0.phase == .work }),
           sets[last].intensifier == .none {
            sets[last].intensifier = .failure
        }

        let intensifier = slot["intensifier"] as? [String: Any]
        switch string(intensifier?["type"]) {
        case "dropset":
            let count = min(5, max(1, positiveInt(intensifier?["count"]) ?? 1))
            let percent = min(80, max(5, positiveDouble(intensifier?["pct"]) ?? 20))
            var load = weight
            for _ in 0..<count {
                load = load.map { $0 * (1 - percent / 100) }
                sets.append(RoutineSetPlan(intensifier: .dropSet, targetWeightKg: load,
                                           repsMin: timed ? nil : low, repsMax: timed ? nil : high,
                                           intensifierConfiguration: .init(segmentCount: count,
                                                                           loadReductionPercent: percent)))
            }
        case "restpause":
            let rest = max(5, positiveInt(intensifier?["restSec"]) ?? 15)
            sets.append(RoutineSetPlan(intensifier: .restPause, targetWeightKg: weight,
                                       repsMin: positiveInt(intensifier?["totalReps"]),
                                       repsMax: positiveInt(intensifier?["totalReps"]),
                                       intensifierConfiguration: .init(segmentCount: 1, restPauseSeconds: rest)))
        default:
            break
        }
        return sets
    }
}

// MARK: - Hevy

/// One exercise of a Hevy routine as the wearer's NOOP should see it: either an exercise NOOP already
/// has, or a new one made from Hevy's own description of it.
public struct HevyRoutineExerciseMatch: Equatable, Sendable {
    public var exercise: TrainingExercise
    public var isNew: Bool

    public init(exercise: TrainingExercise, isNew: Bool) {
        self.exercise = exercise
        self.isNew = isNew
    }
}

/// Turns routines from Hevy's API (`GET /v1/routines`, one JSON document each) into NOOP routines.
/// The documents are read as Hevy sent them, because a routine's planned sets often carry only a
/// repetition range and no logged values, which the workout parser rightly drops.
///
/// Which NOOP exercise a Hevy exercise is lives with the caller, which knows Hevy's exercise
/// catalogue and the wearer's own aliases. A nil match leaves that exercise out and counts it.
public enum HevyRoutineImporter {
    public static let source = "hevy"

    public static func parse(_ documents: [Data], defaultRestSeconds: Int = 120,
                             now: Int = Int(Date().timeIntervalSince1970),
                             match: (_ title: String, _ templateId: String?) -> HevyRoutineExerciseMatch?)
        -> TrainingRoutineImport {
        parse(documents, defaultRestSeconds: defaultRestSeconds, now: now, matchWithLoad: { title, id, _ in match(title, id) })
    }

    /// The extra source fact distinguishes a prescribed added load from a plain bodyweight movement.
    public static func parse(_ documents: [Data], defaultRestSeconds: Int = 120,
                             now: Int = Int(Date().timeIntervalSince1970),
                             matchWithLoad: (_ title: String, _ templateId: String?, _ usesAddedWeight: Bool) -> HevyRoutineExerciseMatch?)
        -> TrainingRoutineImport {
        var skipped = 0
        var newExercises: [String: TrainingExercise] = [:]
        var routines: [TrainingRoutine] = []
        for data in documents {
            guard let doc = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sourceId = OpenGymPlanImporter.string(doc["id"]) else { continue }
            var supersets: [Int: UUID] = [:]
            var exercises: [RoutineExercise] = []
            let rawExercises = ((doc["exercises"] as? [[String: Any]]) ?? []).sorted {
                (OpenGymPlanImporter.int($0["index"]) ?? 0) < (OpenGymPlanImporter.int($1["index"]) ?? 0)
            }
            for raw in rawExercises {
                let title = OpenGymPlanImporter.string(raw["title"]) ?? ""
                let addedLoad = (raw["sets"] as? [[String: Any]] ?? []).contains {
                    (OpenGymPlanImporter.positiveDouble($0["weight_kg"]) ?? 0) > 0
                }
                guard let found = matchWithLoad(title, OpenGymPlanImporter.string(raw["exercise_template_id"]), addedLoad) else {
                    skipped += 1
                    continue
                }
                if found.isNew { newExercises[found.exercise.id] = found.exercise }
                let sets = hevySets(raw, mode: found.exercise.mode)
                guard !sets.isEmpty else { skipped += 1; continue }
                let superset = OpenGymPlanImporter.int(raw["superset_id"]).map { group in
                    if let known = supersets[group] { return known }
                    let fresh = UUID()
                    supersets[group] = fresh
                    return fresh
                }
                exercises.append(RoutineExercise(
                    exerciseId: found.exercise.id, sets: sets,
                    restSeconds: OpenGymPlanImporter.int(raw["rest_seconds"]).map { max(0, $0) } ?? defaultRestSeconds,
                    supersetId: superset,
                    note: OpenGymPlanImporter.string(raw["notes"])))
            }
            guard !exercises.isEmpty else { continue }
            routines.append(TrainingRoutine(
                id: TrainingRoutineImport.routineId(source: source, id: sourceId),
                title: OpenGymPlanImporter.string(doc["title"]) ?? "Hevy",
                notes: OpenGymPlanImporter.string(doc["notes"]),
                exercises: exercises, createdAt: now, updatedAt: now))
        }
        let used = Set(routines.flatMap { $0.exercises.map(\.exerciseId) })
        return TrainingRoutineImport(routines: routines,
                                     newExercises: newExercises.values.filter { used.contains($0.id) }
                                         .sorted { $0.title < $1.title },
                                     skippedExercises: skipped)
    }

    /// Hevy's planned sets in order. A drop set follows the set it drops from, as NOOP's plan expects.
    static func hevySets(_ exercise: [String: Any], mode: TrainingMeasurementMode) -> [RoutineSetPlan] {
        let rawSets = ((exercise["sets"] as? [[String: Any]]) ?? []).sorted {
            (OpenGymPlanImporter.int($0["index"]) ?? 0) < (OpenGymPlanImporter.int($1["index"]) ?? 0)
        }
        return rawSets.map { set in
            let range = set["rep_range"] as? [String: Any]
            let reps = OpenGymPlanImporter.positiveInt(set["reps"])
            let low = OpenGymPlanImporter.positiveInt(range?["start"]) ?? reps
            let high = OpenGymPlanImporter.positiveInt(range?["end"]) ?? reps
            let phase: TrainingSetPhase = OpenGymPlanImporter.string(set["type"]) == "warmup" ? .warmup : .work
            let intensifier: TrainingSetIntensifier
            switch OpenGymPlanImporter.string(set["type"]) {
            case "dropset": intensifier = .dropSet
            case "failure": intensifier = .failure
            case "rest_pause": intensifier = .restPause
            case "amrap": intensifier = .amrap
            default: intensifier = .none
            }
            let usesReps = mode.recordsRepetitions
            return RoutineSetPlan(
                phase: phase, intensifier: intensifier,
                targetWeightKg: OpenGymPlanImporter.positiveDouble(set["weight_kg"]),
                repsMin: usesReps ? low.map { min($0, high ?? $0) } : nil,
                repsMax: usesReps ? high.map { max($0, low ?? $0) } : nil,
                targetDurationS: OpenGymPlanImporter.positiveInt(set["duration_seconds"]),
                targetDistanceM: OpenGymPlanImporter.positiveDouble(set["distance_meters"]))
        }
    }
}

// MARK: - Loose JSON values

extension OpenGymPlanImporter {
    /// Hand-edited and older files spell numbers as strings and ids as numbers; both are accepted.
    static func string(_ value: Any?) -> String? {
        switch value {
        case let text as String:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber where !isBoolean(number):
            return number.stringValue
        default:
            return nil
        }
    }

    static func double(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber where !isBoolean(number):
            return number.doubleValue.isFinite ? number.doubleValue : nil
        case let text as String:
            return Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
        default:
            return nil
        }
    }

    /// JSON `true` arrives as an NSNumber too; it is a flag, never a count of sets or a weight.
    static func isBoolean(_ number: NSNumber) -> Bool {
        String(cString: number.objCType) == "c"
    }

    static func int(_ value: Any?) -> Int? {
        double(value).flatMap { $0.rounded() == $0 && abs($0) < 1_000_000 ? Int($0) : nil }
    }

    static func positiveInt(_ value: Any?) -> Int? { int(value).flatMap { $0 > 0 ? $0 : nil } }
    static func positiveDouble(_ value: Any?) -> Double? { double(value).flatMap { $0 > 0 ? $0 : nil } }
}
