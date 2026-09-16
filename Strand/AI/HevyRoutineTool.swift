import Foundation
import WhoopStore
import StrandAnalytics
import StrandImport

// MARK: - The two strength tools
//
// `find_hevy_exercises` lets the coach look up what movements exist. `propose_hevy_routine` lets it
// draft one. Neither writes to Hevy; only the review screen can do that.
//
// THE SEARCH IS NOT A CONVENIENCE, IT IS A CORRECTNESS MECHANISM. Hevy identifies exercises by opaque
// ids ("05293BCA"). Asked to write a routine without a way to look them up, a language model will
// produce ids of exactly that shape that refer to nothing — and the failure would surface either as a
// rejected write minutes later, or, far worse, as a valid id for a different movement. Every id in a
// draft is checked against the local catalogue before the draft exists at all.

extension AICoachEngine {

    /// Search the LOCAL mirror of Hevy's exercise catalogue.
    ///
    /// Local by construction: the catalogue is synced with the workouts, so this is a database read and
    /// never a network call on the model's behalf. It returns ids because ids are what
    /// `propose_hevy_routine` needs; it returns muscle group and equipment because those are what makes
    /// one movement a sensible substitute for another.
    func findHevyExercisesTool(query: String?, muscleGroup: String?,
                               equipment: String?, limit: Int) async -> String {
        guard let store = await repo.storeHandle() else { return "The local store isn't available." }
        let catalogue = (try? await store.hevyExerciseTemplates()) ?? [:]
        guard !catalogue.isEmpty else {
            return "No Hevy exercise catalogue is synced yet. The user connects Hevy in Data Sources; "
                + "until then you cannot name specific exercises by id and must not invent any."
        }

        let words = (query ?? "").lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 }
        let wantedGroup = muscleGroup.map { HevyMuscleGroup.parse($0) }
        let wantedEquipment = equipment.map { HevyEquipment.parse($0) }

        var matches = catalogue.values.filter { template in
            if let wantedGroup, wantedGroup != .other,
               template.primaryMuscleGroup != wantedGroup,
               !template.secondaryMuscleGroups.contains(wantedGroup) { return false }
            if let wantedEquipment, wantedEquipment != .other, template.equipment != wantedEquipment {
                return false
            }
            guard !words.isEmpty else { return true }
            let haystack = template.title.lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }

        // Movements the user actually trains come first: a substitution they already know beats a
        // technically-correct one they have never done. Then alphabetical, so the list is stable.
        let trained = await trainedTemplateIds()
        matches.sort { a, b in
            let ta = trained.contains(a.id), tb = trained.contains(b.id)
            if ta != tb { return ta }
            return a.title < b.title
        }

        guard !matches.isEmpty else {
            return "No exercise in the user's Hevy catalogue matches that. Try a broader query, or a "
                + "muscle_group on its own. Do NOT invent an exercise_template_id."
        }

        var lines = ["EXERCISE CATALOGUE (\(matches.count) match\(matches.count == 1 ? "" : "es"), "
                     + "showing up to \(limit)). Use exercise_template_id verbatim in propose_hevy_routine:"]
        for template in matches.prefix(limit) {
            var parts = ["\(template.title) — id \(template.id)",
                         "primary \(template.primaryMuscleGroup.rawValue)"]
            if !template.secondaryMuscleGroups.isEmpty {
                parts.append("also \(template.secondaryMuscleGroups.map(\.rawValue).joined(separator: "/"))")
            }
            parts.append(template.equipment.rawValue)
            if trained.contains(template.id) { parts.append("the user trains this") }
            lines.append("  • " + parts.joined(separator: " · "))
        }
        return lines.joined(separator: "\n")
    }

    /// Template ids the user has actually performed recently.
    private func trainedTemplateIds() async -> Set<String> {
        guard let store = await repo.storeHandle() else { return [] }
        let now = Int(Date().timeIntervalSince1970)
        let workouts = (try? await store.hevyWorkouts(from: now - 120 * 86_400, to: now + 86_400)) ?? []
        return Set(workouts.flatMap { $0.exercises.compactMap(\.templateId) })
    }

    /// The user's synced routines: id, title and what each one contains, in brief.
    ///
    /// The model cannot propose a CHANGE to a routine it cannot name, and it must not guess an id — so
    /// this is the only way an `operation=update` draft can be built. Contents are summarised rather
    /// than listed set by set: the point here is to pick the right routine, and the review screen shows
    /// the full before/after once one is picked.
    func hevyRoutinesTool() async -> String {
        guard let store = await repo.storeHandle() else { return "The local store isn't available." }
        let routines = ((try? await store.hevyRoutines()) ?? []).map(Self.hydrate)
        guard !routines.isEmpty else {
            return "The user has no synced Hevy routines. You can still draft a NEW one with "
                + "propose_hevy_routine (operation=create)."
        }
        let catalogue = (try? await store.hevyExerciseTemplates()) ?? [:]
        var lines = ["HEVY ROUTINES (\(routines.count)). Use routine_id verbatim for an update:"]
        for routine in routines.prefix(30) {
            let names = routine.exercises.prefix(6).map { exercise in
                exercise.templateId.flatMap { catalogue[$0]?.title } ?? exercise.title
            }
            var line = "  • \(routine.title) — id \(routine.id)"
            if !names.isEmpty {
                line += " · " + names.joined(separator: ", ")
                if routine.exercises.count > names.count {
                    line += ", +\(routine.exercises.count - names.count) more"
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Draft a routine for the user to review. **Writes nothing to Hevy.**
    func proposeHevyRoutineTool(input: [String: Any]) async -> String {
        await proposeHevyRoutineTool(input: input, proposalStore: .shared)
    }

    func proposeHevyRoutineTool(input: [String: Any],
                                proposalStore: HevyRoutineProposalStore) async -> String {
        guard let store = await repo.storeHandle() else { return "The local store isn't available." }
        let catalogue = (try? await store.hevyExerciseTemplates()) ?? [:]
        guard !catalogue.isEmpty else {
            return "Nothing drafted: no Hevy exercise catalogue is synced, so no exercise id can be "
                + "verified. Ask the user to connect Hevy in Data Sources first."
        }

        let title = ((input["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return "Nothing drafted: the routine needs a title." }

        let operation = HevyRoutineProposal.Operation(rawValue: (input["operation"] as? String) ?? "create")
            ?? .create
        var routineId: String?
        var folderId: Int?
        var previous: [HevyRoutineDraftExercise]?
        var previousRaw: String?
        if operation == .update {
            guard let id = input["routine_id"] as? String, !id.isEmpty else {
                return "Nothing drafted: an update needs routine_id. Call get_hevy_routines for the exact id."
            }
            let routines = (try? await store.hevyRoutines()) ?? []
            guard let existing = routines.first(where: { $0.id == id }) else {
                return "Nothing drafted: no synced routine has id \(id)."
            }
            routineId = id
            // Routine folders are not synchronized yet. Preserve a verified folder on updates and
            // leave new routines unfiled instead of accepting an identifier the model could invent.
            folderId = existing.folderId
            // Carried for the review screen's before/after and for restoring the previous version.
            // Hevy's PUT is a full replace with no partial update, so this is what makes a draft that
            // would drop exercises VISIBLE before it is sent — see `HevyRoutineWriter`.
            previousRaw = existing.rawJSON
            // `hevyRoutines()` returns the row, whose `exercises` is empty by construction — the
            // contents live in `rawJSON`. Re-parsing it here is what gives the review screen a real
            // before/after; without it the "what gets removed" notice would silently never fire, which
            // is the entire protection against Hevy's full-replace PUT.
            let hydrated = Self.hydrate(existing)
            previous = Self.draftExercises(from: hydrated, catalogue: catalogue)
        }

        var exercises: [HevyRoutineDraftExercise] = []
        for raw in (input["exercises"] as? [[String: Any]] ?? []) {
            guard let templateId = (raw["exercise_template_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !templateId.isEmpty else {
                return "Nothing drafted: every exercise needs an exercise_template_id from "
                    + "find_hevy_exercises."
            }
            // THE check. An id that is not in the catalogue fails the whole draft rather than being
            // dropped: a routine silently missing the movement it was built around is worse than no
            // routine, and the model gets a message it can act on.
            guard let template = catalogue[templateId] else {
                return "Nothing drafted: \"\(templateId)\" is not an exercise in the user's Hevy "
                    + "catalogue. Use find_hevy_exercises and copy an id from it verbatim."
            }
            let sets = Self.draftSets(from: raw["sets"] as? [[String: Any]] ?? [])
            guard !sets.isEmpty else {
                return "Nothing drafted: \(template.title) has no sets."
            }
            exercises.append(HevyRoutineDraftExercise(
                templateId: templateId,
                title: template.title,
                supersetId: raw["superset_id"] as? Int,
                restSeconds: (raw["rest_seconds"] as? Int).map { max(0, min($0, 900)) },
                notes: (raw["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                sets: sets))
        }
        guard !exercises.isEmpty else { return "Nothing drafted: the routine had no exercises." }

        let rationale = ((input["rationale"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var proposal = HevyRoutineProposal(
            operation: operation, routineId: routineId, title: title,
            notes: (input["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
            folderId: folderId,
            exercises: exercises, rationale: rationale,
            previousExercises: previous, previousRawJSON: previousRaw)

        // The gate runs HERE, on the draft, before it is stored — never in the prompt. Its verdict is
        // saved with the proposal so the review screen shows exactly what the gate decided rather than
        // re-deriving something that could differ.
        // Every detailed source, de-duplicated: native sets and file imports carry the same volume a
        // Hevy row does, and a gate that cannot see them warns about a plan it has not measured.
        let workouts = await repo.resolvedStrengthHistory(days: 28).workouts
        proposal.warnings = StrengthPlanGate.warnings(
            for: proposal, templates: catalogue,
            history: StrengthPlanGate.history(from: workouts, templates: catalogue),
            weeklyFrequency: (input["times_per_week"] as? Double)
                ?? (input["times_per_week"] as? Int).map(Double.init) ?? 1)

        guard proposalStore.propose(proposal) else {
            return "Nothing drafted: the routine was empty."
        }

        var reply = operation == .update
            ? "Drafted an UPDATE to \"\(title)\" (NOT sent to Hevy): "
            : "Drafted \"\(title)\" (NOT sent to Hevy): "
        reply += "\(exercises.count) exercise\(exercises.count == 1 ? "" : "s"), "
            + "\(proposal.totalWorkingSets) working sets. "
        reply += "It is waiting for the user to review and send. Do not describe it as created, saved "
            + "or added to Hevy."
        if !proposal.warnings.isEmpty {
            reply += "\n\nThe app's own check flagged this, and the user will see it — mention it plainly:"
            for warning in proposal.warnings { reply += "\n  • \(warning)" }
        }
        return reply
    }

    // MARK: - Parsing

    private static func draftSets(from raw: [[String: Any]]) -> [HevyRoutineDraftSet] {
        raw.prefix(20).map { entry in
            let start = intArgument(entry["rep_range_start"])
            let end = intArgument(entry["rep_range_end"])
            return HevyRoutineDraftSet(
                type: HevySetType.parse(entry["type"] as? String),
                // Clamped rather than trusted. A model that emits 900 for a kilogram figure produces a
                // draft the user might skim past; a bound makes that impossible without discarding the
                // set, which would hide the mistake instead.
                weightKg: doubleArgument(entry["weight_kg"]).map { max(0, min($0, 600)) },
                reps: intArgument(entry["reps"]).map { max(1, min($0, 100)) },
                repRangeStart: start.map { max(1, min($0, 100)) },
                repRangeEnd: end.map { max(1, min($0, 100)) })
        }
    }

    /// Recover a stored routine's exercises from its verbatim document.
    ///
    /// The store cannot do this itself (`HevyApiParser` lives in a package that depends on the store),
    /// so it happens here, once, at the only call site that needs the contents.
    private static func hydrate(_ routine: HevyRoutine) -> HevyRoutine {
        guard let object = try? JSONSerialization.jsonObject(with: Data(routine.rawJSON.utf8)),
              let dictionary = object as? [String: Any] else { return routine }
        return HevyApiParser.parseRoutines([dictionary]).items.first ?? routine
    }

    /// Turn a synced routine into draft exercises, for the before/after view of an update.
    private static func draftExercises(from routine: HevyRoutine,
                                       catalogue: [String: HevyExerciseTemplate]) -> [HevyRoutineDraftExercise] {
        routine.exercises.map { exercise in
            HevyRoutineDraftExercise(
                templateId: exercise.templateId ?? "",
                title: exercise.templateId.flatMap { catalogue[$0]?.title } ?? exercise.title,
                supersetId: exercise.supersetId,
                restSeconds: nil,
                notes: exercise.notes,
                sets: exercise.sets.map {
                    HevyRoutineDraftSet(type: $0.type, weightKg: $0.weightKg, reps: $0.reps)
                })
        }
    }

    private static func intArgument(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double, d.isFinite { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private static func doubleArgument(_ value: Any?) -> Double? {
        if let d = value as? Double, d.isFinite { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String, let d = Double(s), d.isFinite { return d }
        return nil
    }
}
