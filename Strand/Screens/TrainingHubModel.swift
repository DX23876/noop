import Foundation
import Combine
import StrandDesign
import StrandTraining
import UserNotifications

@MainActor
final class TrainingHubModel: ObservableObject {
    struct HistoryImportPreview: Identifiable {
        let id = UUID()
        let result: TrainingHistoryImport
        let mappedExerciseCount: Int

        var workoutCount: Int { result.workouts.count }
        var exerciseCount: Int { Set(result.workouts.flatMap { $0.exercises.map(\.exerciseId) }).count }
        var setCount: Int { result.workouts.flatMap(\.exercises).flatMap(\.sets).count }
    }

    /// Routines from another app, shown before anything is stored.
    struct RoutineImportPreview: Identifiable {
        enum Source { case hevy, openGym }
        let id = UUID()
        let source: Source
        let result: TrainingRoutineImport
        /// Routines an earlier import of the same routines made; importing again updates them in place.
        let alreadyImported: Set<UUID>
    }

    @Published private(set) var loaded = false
    @Published private(set) var exercises: [TrainingExercise] = []
    @Published private(set) var plan = TrainingPlan()
    /// Every plan the wearer holds, resting ones included. `plan` above is what is being FOLLOWED,
    /// and stays the one answer to what to train today.
    @Published private(set) var programs: [TrainingProgram] = []
    @Published private(set) var workouts: [NativeWorkout] = []
    @Published private(set) var resolvedHistory = ResolvedStrengthHistory(
        sessions: [], workouts: [], templates: [:])
    @Published private(set) var trackers: [SessionTrackerAttribution] = []
    @Published private(set) var performanceHistory = TrainingPerformanceHistory.empty
    /// Days of the past year with minutes logged, computed once per load rather than in a view body.
    @Published private(set) var activityDays: [TrainingActivityDay] = []
    @Published var historyImportPreview: HistoryImportPreview?
    @Published var routineImportPreview: RoutineImportPreview?
    @Published private(set) var loadingHevyRoutines = false
    @Published var errorMessage: String?

    /// Reads the plan and the whole resolved history. While a live session runs this is skipped once
    /// something is loaded: nothing the hub shows changes mid-workout, and resolving every session again
    /// on each data refresh is exactly the work that made logging stutter.
    func load(repo: Repository, session: ActiveSessionController? = nil,
              weekStartsOn: TrainingWeekStart = .monday, force: Bool = false) async {
        if !force, loaded, session?.hasLiveSession == true { return }
        await repo.prepareNativeTraining()
        async let exercises = repo.nativeTrainingExercises()
        async let plan = repo.nativeTrainingPlan(weekStartsOn: weekStartsOn)
        async let programs = repo.nativeTrainingPrograms()
        async let workouts = repo.nativeWorkouts()
        async let trackers = repo.nativeTrainingTrackers()
        async let resolved = repo.resolvedStrengthHistory(days: ResolvedStrengthHistory.allHistoryDays)
        self.exercises = await exercises
        self.plan = await plan
        self.programs = await programs
        self.workouts = await workouts
        self.trackers = await trackers
        self.resolvedHistory = await resolved
        refreshPerformanceHistory()
        activityDays = TrainingActivityDay.pastYear(sessions: resolvedHistory.sessions,
                                                    weekStart: weekStartsOn)
        loaded = true
        session?.update(context: startContext)
    }

    var startContext: TrainingStartContext {
        TrainingStartContext(exercises: exercises, plan: plan, programs: programs,
                             workouts: workouts, performance: performanceHistory)
    }

    private func refreshPerformanceHistory() {
        performanceHistory = TrainingPerformanceHistory(native: workouts, resolved: resolvedHistory,
                                                        exercises: exercises)
    }

    var exerciseById: [String: TrainingExercise] {
        Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
    }

    func routines(on date: Date) -> [TrainingRoutine] { Self.routines(in: plan, on: date) }

    /// The routines planned for `date` that no saved workout of that day was run from (`PlannedToday`).
    func openRoutines(on date: Date) -> [TrainingRoutine] {
        let planned = routines(on: date)
        let open = Set(PlannedToday.openRoutineIds(planned.map(\.id), day: Self.dayString(date), workouts: workouts))
        return planned.filter { open.contains($0.id) }
    }

    /// The routines `plan` holds for `date`: its own day first, then its weekday. Shared with Today's
    /// next-session widget, which reads the plan alone instead of the whole hub.
    static func routines(in plan: TrainingPlan, on date: Date) -> [TrainingRoutine] {
        let day = dayFormatter.string(from: date)
        let weekday = TrainingWeekday(rawValue: Calendar.current.component(.weekday, from: date) == 1
            ? 7 : Calendar.current.component(.weekday, from: date) - 1) ?? .monday
        return plan.routines(day: day, weekday: weekday)
    }

    /// What is followed and what is held, read again after any write that can change either. One
    /// helper rather than two lines at every call site, so a mutator cannot refresh one and forget
    /// the other and leave the plan list disagreeing with the week.
    private func refreshPlans(repo: Repository) async {
        async let plan = repo.nativeTrainingPlan(weekStartsOn: self.plan.weekStartsOn)
        async let programs = repo.nativeTrainingPrograms()
        self.plan = await plan
        self.programs = await programs
        await closeFinishedBlocks(repo: repo)
    }

    /// A block whose last week is behind the wearer closes its run, once, here.
    ///
    /// Nothing else changes: the plan keeps running, its prescriptions stay as they are, and the page
    /// offers to repeat it or build the next one. Closing the run is what lets it appear under
    /// earlier blocks with the figures from its own window.
    private func closeFinishedBlocks(repo: Repository) async {
        let today = Repository.localDayKey(Date())
        for program in programs where program.isActive {
            guard let state = TrainingBlockState.resolve(block: program.block, today: today),
                  state.isFinished else { continue }
            let open = await repo.nativeTrainingBlockRuns(programId: program.id)
                .contains { $0.endedOn == nil }
            guard open else { continue }
            try? await repo.finishNativeTrainingBlockRun(programId: program.id, day: today)
        }
    }

    /// The plan being followed, which is where a new routine goes unless the wearer says otherwise.
    var activeStrengthProgram: TrainingProgram? {
        TrainingProgramActivation.active(.strength, in: programs)
    }

    func program(_ id: UUID?) -> TrainingProgram? {
        guard let id else { return nil }
        return programs.first { $0.id == id }
    }

    /// One plan's routines. The followed plan answers out of `plan`, which is already in memory; a
    /// resting plan is read from the store, since nothing else holds it.
    func routines(ofProgram id: UUID, repo: Repository) async -> [TrainingRoutine] {
        if programs.first(where: { $0.id == id })?.isActive == true {
            return plan.routines.filter { $0.programId == id }
        }
        return await repo.nativeTrainingRoutines(programId: id)
    }

    func addStarter(_ routine: TrainingRoutine, repo: Repository) async {
        do {
            var placed = routine
            placed.programId = routine.programId ?? activeStrengthProgram?.id
            try await repo.saveNativeTrainingRoutine(placed)
            await refreshPlans(repo: repo)
        } catch {
            errorMessage = String(localized: "The routine could not be saved.")
        }
    }

    func saveProgram(_ program: TrainingProgram, repo: Repository) async {
        do {
            var updated = program
            updated.updatedAt = Int(Date().timeIntervalSince1970)
            try await repo.saveNativeTrainingProgram(updated)
            await refreshPlans(repo: repo)
        } catch {
            errorMessage = String(localized: "The plan could not be saved.")
        }
    }

    /// A copy of a plan, its routines included, resting until the wearer takes it up.
    ///
    /// The copying itself is `TrainingProgramEditing.duplicate` in the core, so Android makes exactly
    /// the same copy.
    func duplicateProgram(_ program: TrainingProgram, repo: Repository) async {
        let now = Int(Date().timeIntervalSince1970)
        let source = await routines(ofProgram: program.id, repo: repo)
        let copy = TrainingProgramEditing.duplicate(
            program, routines: source,
            title: String(localized: "\(program.title) copy"), now: now)
        await saveBuiltPlan(copy.program, routines: copy.routines, activate: false, repo: repo)
    }

    /// Writes a plan the builder, a template or a copy produced: the plan WITHOUT its week first,
    /// then its routines, then the week.
    ///
    /// A scheduled day points at a routine and the store enforces that, so writing the plan with its
    /// week while the routines do not exist yet is rejected and nothing is saved at all. It is saved
    /// resting unless the wearer said to follow it.
    ///
    /// Returns whether it was saved, so a caller does not open a plan that was never written.
    @discardableResult
    func saveBuiltPlan(_ program: TrainingProgram, routines: [TrainingRoutine],
                       activate: Bool, repo: Repository) async -> Bool {
        do {
            var resting = program
            resting.isActive = false
            resting.block?.startedOn = nil
            resting.schedule = [:]
            try await repo.saveNativeTrainingProgram(resting)
            for routine in routines {
                var placed = routine
                placed.programId = program.id
                try await repo.saveNativeTrainingRoutine(placed)
            }
            try await repo.saveNativeTrainingSchedule(program.schedule, programId: program.id)
            if activate { try await repo.activateNativeTrainingProgram(program.id) }
            await refreshPlans(repo: repo)
            return true
        } catch {
            errorMessage = String(localized: "The plan could not be saved.")
            await refreshPlans(repo: repo)
            return false
        }
    }

    func activateProgram(_ id: UUID, repo: Repository) async {
        do {
            try await repo.activateNativeTrainingProgram(id)
            await refreshPlans(repo: repo)
        } catch {
            errorMessage = String(localized: "The plan could not be saved.")
        }
    }

    func deactivateProgram(_ id: UUID, repo: Repository) async {
        do {
            try await repo.deactivateNativeTrainingProgram(id)
            await refreshPlans(repo: repo)
        } catch {
            errorMessage = String(localized: "The plan could not be saved.")
        }
    }

    func deleteProgram(_ id: UUID, repo: Repository) async {
        do {
            try await repo.deleteNativeTrainingProgram(id)
            await refreshPlans(repo: repo)
        } catch {
            errorMessage = String(localized: "The plan could not be deleted.")
        }
    }

    /// What a plan amounts to in a week, measured against the wearer's own recent sessions.
    ///
    /// One place computes this, so the wizard, the plan page and anything added later cannot show
    /// two different answers for the same plan.
    func review(of program: TrainingProgram, routines: [TrainingRoutine],
                askedMinutesPerSession: Int? = nil) -> PlanReview {
        PlanReview.evaluate(program: program, routines: routines, exercises: exerciseById,
                            askedMinutesPerSession: askedMinutesPerSession,
                            history: PlanHistory.from(workouts: workouts, exercises: exerciseById))
    }

    func saveExercise(_ exercise: TrainingExercise, repo: Repository) async {
        do {
            try await repo.saveNativeTrainingExercise(exercise)
            exercises = await repo.nativeTrainingExercises()
            refreshPerformanceHistory()
        } catch {
            errorMessage = String(localized: "The exercise could not be saved.")
        }
    }

    func saveRoutine(_ routine: TrainingRoutine, repo: Repository) async {
        do {
            var placed = routine
            placed.programId = routine.programId ?? activeStrengthProgram?.id
            try await repo.saveNativeTrainingRoutine(placed)
            await refreshPlans(repo: repo)
        } catch {
            errorMessage = String(localized: "The routine could not be saved.")
        }
    }

    /// Saves the routine, then its weekday assignment within ITS OWN plan. Other routines keep their
    /// days and order, and a routine in a resting plan is scheduled in that plan rather than in the
    /// week being followed.
    func saveRoutine(_ routine: TrainingRoutine, weekdays: Set<TrainingWeekday>, repo: Repository) async {
        do {
            var placed = routine
            let owner = routine.programId ?? activeStrengthProgram?.id
            placed.programId = owner
            try await repo.saveNativeTrainingRoutine(placed)
            if let owner, let program = programs.first(where: { $0.id == owner }) {
                let schedule = RoutineEditing.schedule(program.schedule, assigning: routine.id,
                                                       to: weekdays)
                if schedule != program.schedule {
                    try await repo.saveNativeTrainingSchedule(schedule, programId: owner)
                }
            }
            await refreshPlans(repo: repo)
        } catch {
            errorMessage = String(localized: "The routine could not be saved.")
        }
    }

    func duplicateRoutine(_ routine: TrainingRoutine, repo: Repository) async {
        let copy = RoutineEditing.duplicate(
            routine, title: String(localized: "\(routine.title) copy"),
            now: Int(Date().timeIntervalSince1970))
        await saveRoutine(copy, repo: repo)
    }

    func deleteRoutine(_ id: UUID, repo: Repository) async {
        do {
            try await repo.deleteNativeTrainingRoutine(id)
            await refreshPlans(repo: repo)
        } catch {
            errorMessage = String(localized: "The routine could not be deleted.")
        }
    }

    /// The weekdays a routine is scheduled on, read from the plan it belongs to rather than from the
    /// week being followed. A resting plan's routine has days too, and they are its own.
    func weekdays(of routine: TrainingRoutine) -> Set<TrainingWeekday> {
        let schedule = program(routine.programId)?.schedule ?? plan.schedule
        return RoutineEditing.weekdays(of: routine.id, in: schedule)
    }

    func planArchiveData() throws -> Data {
        try TrainingPlanArchive(plan: plan, exercises: exercises).encoded()
    }

    func importPlan(_ data: Data, repo: Repository) async {
        // An OpenGym plan file picked here goes through its own preview rather than failing as NOOP's.
        if (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["opengym_plan"] != nil {
            prepareOpenGymImport(data)
            return
        }
        do {
            let archive = try TrainingPlanArchive.decode(data)
            try await repo.importNativeTrainingPlan(archive)
            await load(repo: repo, weekStartsOn: archive.weekStartsOn)
        } catch {
            errorMessage = String(localized: "The training plan could not be imported.")
        }
    }

    func prepareHistoryImport(_ data: Data) {
        do {
            let result = try TrainingCSVImporter.parse(data, existingExercises: exercises)
            let definitions = Dictionary(uniqueKeysWithValues:
                (exercises + result.exercises).map { ($0.id, $0) })
            let used = Set(result.workouts.flatMap { $0.exercises.map(\.exerciseId) })
            let mapped = used.filter { id in
                definitions[id].map { TrainingMuscleProjection.anatomy(for: $0) != nil } ?? false
            }.count
            historyImportPreview = .init(result: result, mappedExerciseCount: mapped)
        } catch {
            errorMessage = String(localized: "The workout history could not be imported.")
        }
    }

    func confirmHistoryImport(repo: Repository) async {
        guard let preview = historyImportPreview else { return }
        do {
            try await repo.importNativeTrainingHistory(preview.result)
            historyImportPreview = nil
            await load(repo: repo)
            errorMessage = preview.result.skippedRows > 0
                ? String(localized: "The history was imported. Some incomplete rows were skipped.") : nil
        } catch {
            errorMessage = String(localized: "The workout history could not be imported.")
        }
    }

    private var defaultRestSeconds: Int {
        UserDefaults.standard.object(forKey: TrainingPreferences.defaultRestKey) as? Int
            ?? TrainingPreferences.defaultRestSeconds
    }

    func prepareOpenGymImport(_ data: Data) {
        do {
            let result = try OpenGymPlanImporter.parse(data, existingExercises: exercises,
                                                       defaultRestSeconds: defaultRestSeconds)
            showRoutineImport(result, source: .openGym)
        } catch TrainingRoutineImportError.noRoutines {
            errorMessage = String(localized: "None of the plan's exercises could be found in NOOP.")
        } catch {
            errorMessage = String(localized: "This file is not an OpenGym plan. Export it in OpenGym under Plan, Export plan file.")
        }
    }

    func prepareHevyImport(repo: Repository) async {
        loadingHevyRoutines = true
        defer { loadingHevyRoutines = false }
        do {
            let result = try await repo.hevyRoutineImport(exercises: exercises,
                                                          defaultRestSeconds: defaultRestSeconds)
            guard !result.routines.isEmpty else {
                errorMessage = HevyCredentials.isConnected
                    ? String(localized: "No routines were found in Hevy.")
                    : String(localized: "Connect Hevy under More, Data sources to import its routines.")
                return
            }
            showRoutineImport(result, source: .hevy)
        } catch {
            errorMessage = String(localized: "The Hevy routines could not be loaded.")
        }
    }

    private func showRoutineImport(_ result: TrainingRoutineImport, source: RoutineImportPreview.Source) {
        let existing = Set(plan.routines.map(\.id))
        routineImportPreview = .init(source: source, result: result,
                                     alreadyImported: Set(result.routines.map(\.id)).intersection(existing))
    }

    /// Adds the chosen routines; ones an earlier import made are updated. The source's week joins the
    /// schedule only when asked for, beside what is already planned, never in its place.
    func confirmRoutineImport(_ selected: Set<UUID>, includingSchedule: Bool, repo: Repository) async {
        guard let preview = routineImportPreview else { return }
        let chosen = preview.result.keeping(selected)
        guard !chosen.routines.isEmpty else { routineImportPreview = nil; return }
        do {
            try await repo.importNativeTrainingPlan(
                chosen.archive(includingSchedule: includingSchedule, weekStartsOn: plan.weekStartsOn))
            routineImportPreview = nil
            await load(repo: repo, weekStartsOn: plan.weekStartsOn, force: true)
        } catch {
            errorMessage = String(localized: "The routines could not be imported.")
        }
    }

    /// Writes ONE plan's week. Without a plan named it is the plan being followed, which is what the
    /// hub's own week editor means.
    func saveSchedule(_ schedule: [TrainingWeekday: [UUID]], programId: UUID? = nil,
                      repo: Repository) async {
        do {
            try await repo.saveNativeTrainingSchedule(schedule,
                                                      programId: programId ?? activeStrengthProgram?.id)
            await refreshPlans(repo: repo)
        } catch {
            errorMessage = String(localized: "The schedule could not be saved.")
        }
    }

    func saveOverride(_ override: TrainingDayOverride, repo: Repository) async {
        do {
            try await repo.saveNativeTrainingOverride(override)
            await refreshPlans(repo: repo)
        } catch {
            errorMessage = String(localized: "The day could not be changed.")
        }
    }

    func clearOverride(day: String, repo: Repository) async {
        do {
            try await repo.deleteNativeTrainingOverride(day: day)
            await refreshPlans(repo: repo)
        } catch {
            errorMessage = String(localized: "The day could not be reset.")
        }
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayString(_ date: Date) -> String { dayFormatter.string(from: date) }

    static func weekday(_ date: Date) -> TrainingWeekday {
        let value = Calendar.current.component(.weekday, from: date)
        return TrainingWeekday(rawValue: value == 1 ? 7 : value - 1) ?? .monday
    }
}
