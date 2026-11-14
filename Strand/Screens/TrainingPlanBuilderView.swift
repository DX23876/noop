import SwiftUI
import StrandDesign
import StrandTraining

/// Builds a whole plan from a few answers, shows what came out, and saves it only when the wearer
/// says so.
///
/// The work is `PlanBuilder` in the core, so this screen asks questions and shows a result and
/// decides nothing. Android asks the same questions and gets the same plan.
struct TrainingPlanBuilderView: View {
    @ObservedObject var model: TrainingHubModel
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    /// Called with the plan that was saved, so the caller can open it.
    var onSaved: (TrainingProgram) -> Void = { _ in }

    @State private var daysPerWeek = 3
    @State private var experience = TrainingExperience.beginner
    @State private var emphasis = TrainingEmphasis.balanced
    @State private var minutes = 60
    @State private var onlyMyEquipment = true
    @State private var hasBlock = false
    @State private var blockWeeks = 8
    @State private var built: Built?
    @State private var saving = false

    /// What came out of the builder, kept so the preview and the save use the same plan rather than
    /// building twice and showing one while saving the other.
    private struct Built {
        let program: TrainingProgram
        let routines: [TrainingRoutine]
    }

    var body: some View {
        Form {
            if let built {
                preview(built)
            } else {
                questions
            }
        }
        .forgeListBackground()
        .navigationTitle(Text("Build a plan"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                if built == nil {
                    Button("Build") { build() }
                } else {
                    Button("Save") { save(follow: false) }.disabled(saving)
                }
            }
        }
    }

    // MARK: Questions

    /// The week the current answers would run, from the builder's own resolver.
    private var shape: [PlanBuilder.PlannedDay] {
        PlanBuilder.weekShape(daysPerWeek: daysPerWeek, emphasis: emphasis)
    }

    @ViewBuilder private var questions: some View {
        Section {
            // The answers as a picture: a plan is a shape in a week before it is a list of exercises,
            // and these questions used to produce nothing to look at until the whole plan appeared.
            HStack(alignment: .center, spacing: NoopMetrics.space4) {
                CoachPicture(main: "figure.strengthtraining.traditional", accentA: "calendar",
                             accentB: "sparkle", tint: TrainingMuscleMapAppearance.accent)
                    .frame(width: CoachPictureSize.small, height: CoachPictureSize.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your week").font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("\(daysPerWeek) sessions, about \(minutes) minutes each")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .listRowSeparator(.hidden)
            TrainingWeekStrip(days: Set(shape.map(\.weekday)), titles: shape.map(\.title))
                .padding(.vertical, 2)
        }
        Section {
            Stepper("\(daysPerWeek) days a week", value: $daysPerWeek, in: 2...6)
            Stepper("About \(minutes) minutes a session", value: $minutes, in: 20...150, step: 10)
        } footer: {
            Text("The sessions are spread through the week, with rest days between them where the number allows.")
        }

        Section("How long you have been training") {
            Picker("Experience", selection: $experience) {
                Text("New to this").tag(TrainingExperience.beginner)
                Text("A while").tag(TrainingExperience.intermediate)
                Text("Years").tag(TrainingExperience.advanced)
            }
            .pickerStyle(.segmented)
        }

        Section {
            Picker("Lean towards", selection: $emphasis) {
                Text("Balanced").tag(TrainingEmphasis.balanced)
                Text("Strength").tag(TrainingEmphasis.strength)
                Text("Size").tag(TrainingEmphasis.hypertrophy)
                Text("Upper body").tag(TrainingEmphasis.upperBody)
                Text("Lower body").tag(TrainingEmphasis.lowerBody)
            }
        } footer: {
            Text("A lean adds to the plan rather than taking anything out.")
        }

        Section {
            Toggle("Only the equipment I have", isOn: $onlyMyEquipment)
        } header: {
            Text("Equipment")
        } footer: {
            Text(equipmentFooter)
        }

        Section {
            Toggle("Run for a set number of weeks", isOn: $hasBlock)
            if hasBlock {
                Stepper("\(blockWeeks) weeks, the last one lighter", value: $blockWeeks, in: 4...16)
            }
        } header: {
            Text("Block")
        }
    }

    private var equipmentFooter: String {
        let available = TrainingPreferences.availableEquipment
        if !onlyMyEquipment { return String(localized: "Every exercise in the library can be used.") }
        return available.isEmpty
            ? String(localized: "You have not said what equipment you have, under Settings, Training, so everything is used.")
            : String(localized: "\(available.count) kinds of equipment from Settings, Training.")
    }

    // MARK: Preview

    @ViewBuilder private func preview(_ built: Built) -> some View {
        Section {
            Text(built.program.title).font(StrandFont.headline)
            Text("\(built.routines.count) sessions a week")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
        }
        ForEach(built.routines) { routine in
            Section {
                ForEach(routine.exercises) { entry in
                    HStack(spacing: NoopMetrics.space4) {
                        if let exercise = model.exerciseById[entry.exerciseId] {
                            TrainingExercisePicture(exercise: exercise)
                        }
                        Text(model.exerciseById[entry.exerciseId]?.title ?? entry.exerciseId)
                            .font(StrandFont.subhead.weight(.medium))
                        Spacer(minLength: 8)
                        // The prescription is what the row is for; it carries the weight of the line.
                        Text(setSummary(entry))
                            .font(StrandFont.subhead.weight(.semibold).monospacedDigit())
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack(alignment: .center, spacing: NoopMetrics.space3) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(routine.title)
                            .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text("\(SessionEstimate.minutes(routine)) min")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Spacer(minLength: 8)
                    // The session's own muscles: what it looks like before it has been done.
                    TrainingMusclePicture(
                        values: TrainingMuscleProjection.routine(routine, exercises: model.exerciseById),
                        showsBack: true, height: CoachPictureSize.medium)
                }
                .textCase(nil)
                .padding(.top, NoopMetrics.space3)
                .padding(.bottom, NoopMetrics.space1)
            }
        }
        Section {
            PlanReviewCard(review: model.review(of: built.program, routines: built.routines,
                                                askedMinutesPerSession: minutes),
                           routineTitles: Dictionary(built.routines.map { ($0.id, $0.title) },
                                                     uniquingKeysWith: { first, _ in first }))
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
        Section {
            Button("Save and follow this plan") { save(follow: true) }.disabled(saving)
            Button("Start over") { self.built = nil }
        } footer: {
            Text("Saved on its own, a plan rests until you take it up. Everything in it can be edited afterwards.")
        }
    }

    private func setSummary(_ entry: RoutineExercise) -> String {
        let work = entry.sets.filter { $0.phase == .work }
        guard let first = work.first else { return "" }
        if let low = first.repsMin {
            let reps = first.repsMax.map { $0 == low ? "\(low)" : "\(low)–\($0)" } ?? "\(low)+"
            return String(localized: "\(work.count) × \(reps)")
        }
        if let seconds = first.targetDurationS {
            return String(localized: "\(work.count) × \(seconds) s")
        }
        return String(localized: "\(work.count) sets")
    }

    // MARK: Actions

    private func build() {
        var request = PlanRequest(
            daysPerWeek: daysPerWeek,
            equipment: onlyMyEquipment ? TrainingPreferences.availableEquipment : [],
            experience: experience, emphasis: emphasis, minutesPerSession: minutes,
            weightStepKg: TrainingPreferences.weightStep(for: ["barbell"]))
        if hasBlock { request.block = TrainingProgramBlock(weeks: blockWeeks) }
        let result = PlanBuilder.build(request, exercises: model.exercises,
                                       now: Int(Date().timeIntervalSince1970))
        guard !result.routines.isEmpty else {
            model.errorMessage = String(localized: "No plan could be built from the equipment you have. Add more under Settings, Training.")
            return
        }
        built = Built(program: result.program, routines: result.routines)
    }

    private func save(follow: Bool) {
        guard let built, !saving else { return }
        saving = true
        Task {
            let saved = await model.saveBuiltPlan(built.program, routines: built.routines,
                                                  activate: follow, repo: repo)
            saving = false
            // Only a plan that was written is opened. Reporting it regardless put an empty page over
            // the message saying it could not be saved.
            guard saved else { return }
            onSaved(built.program)
            dismiss()
        }
    }
}

/// The ready-made plans. Picking one writes it as a resting plan, so nothing changes in the week
/// until the wearer takes it up on its page.
struct TrainingTemplateListView: View {
    @ObservedObject var model: TrainingHubModel
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    var onSaved: (TrainingProgram) -> Void = { _ in }
    @State private var saving = false
    /// Each template's own training days, read from the plan it makes rather than guessed from the
    /// number of days: a strip that lit the wrong days would be a picture of a plan nobody gets.
    /// Filled after the list is up, so the list still costs nothing to show.
    @State private var weeks: [String: Set<TrainingWeekday>] = [:]

    private var templates: [TrainingProgramCatalog.Template] {
        TrainingProgramCatalog.templates(exercises: model.exercises)
    }

    var body: some View {
        List {
            Section {
                ForEach(templates) { template in
                    Button { pick(template) } label: { row(template) }.disabled(saving)
                }
            } footer: {
                Text("A plan you pick here rests until you follow it, and everything in it can be edited.")
            }
        }
        .forgeListBackground()
        .task { loadWeeks() }
        .navigationTitle(Text("Ready-made plans"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
    }

    private func loadWeeks() {
        guard weeks.isEmpty else { return }
        let now = Int(Date().timeIntervalSince1970)
        let step = TrainingPreferences.weightStep(for: ["barbell"])
        weeks = Dictionary(templates.map { ($0.id, Set($0.make(now, step).program.schedule.keys)) },
                           uniquingKeysWith: { first, _ in first })
    }

    private func row(_ template: TrainingProgramCatalog.Template) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text(template.title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text(template.summary).font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            if let days = weeks[template.id] {
                TrainingWeekStrip(days: days, height: TrainingWeekStrip.compact)
            }
            // The strip already counts the days; saying it again underneath is a second readout of
            // one fact, so the count is only written out while the strip is still being worked out.
            let countsDays = weeks[template.id] == nil
            let credit = template.origin.name.flatMap { name in
                template.origin.attribution.map { "\(name), \($0)" }
            }
            let missing = missingEquipment(template)
            if countsDays || credit != nil || missing != nil {
                HStack(spacing: 6) {
                    if countsDays { Text("\(template.daysPerWeek) days a week") }
                    if let credit {
                        if countsDays { Text("·") }
                        Text(credit)
                    }
                    if let missing {
                        if countsDays || credit != nil { Text("·") }
                        Text("Needs \(missing)").foregroundStyle(StrandPalette.statusWarningForeground)
                    }
                }
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.vertical, NoopMetrics.space1)
    }

    /// Equipment the wearer has not said they have. The template is still offered, with the gap
    /// named: the setting may simply be empty, and nobody should be locked out of a plan by it.
    private func missingEquipment(_ template: TrainingProgramCatalog.Template) -> String? {
        let available = TrainingPreferences.availableEquipment
        guard !available.isEmpty, !template.requiredEquipment.isEmpty else { return nil }
        let missing = template.requiredEquipment.subtracting(available.map(TrainingEquipmentCatalog.canonical))
        guard !missing.isEmpty else { return nil }
        return missing.sorted().joined(separator: ", ")
    }

    private func pick(_ template: TrainingProgramCatalog.Template) {
        guard !saving else { return }
        saving = true
        let result = template.make(Int(Date().timeIntervalSince1970),
                                   TrainingPreferences.weightStep(for: ["barbell"]))
        Task {
            let saved = await model.saveBuiltPlan(result.program, routines: result.routines,
                                                  activate: false, repo: repo)
            saving = false
            guard saved else { return }
            onSaved(result.program)
            dismiss()
        }
    }
}
