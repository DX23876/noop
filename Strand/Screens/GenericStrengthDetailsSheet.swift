import SwiftUI
import StrandDesign
import WhoopStore

/// Adds the details HealthKit cannot contain to an already imported strength-workout envelope.
///
/// The envelope keeps owning the facts it has — when the session happened, how long it lasted, the heart
/// rate attached to it — and this sheet only collects what no workout record carries: which exercises
/// were performed, how many working sets, the muscle they trained and, optionally, how close to failure.
/// Saving writes ONE manual strength workout keyed to the session's own window, so saving twice edits
/// that entry instead of logging the session again.
struct GenericStrengthDetailsSheet: View {
    struct Draft: Identifiable {
        let id = UUID()
        var title = ""
        var workSets = 3
        var muscle: HevyMuscleGroup = .other
        var effort = ""
        var usesRIR = true
    }

    /// What the form can refuse to save, so the wearer is told which field to fix rather than having a
    /// value silently dropped.
    enum DraftError: Error, Equatable {
        case noExercise
        case effortOutOfRange(exercise: String)
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var repo: Repository
    let session: UnifiedTrainingSession
    /// The manual entry already saved for this session, when there is one — the sheet then edits it.
    var existing: HevyWorkout?
    /// Exercise catalogue, used to recover the muscle group of an entry being edited.
    var templates: [String: HevyExerciseTemplate] = [:]
    let onSaved: () async -> Void
    @State private var drafts: [Draft] = []
    @State private var saving = false
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                        NoopCard {
                            Text("Apple Health tells NOOP when this strength session happened. Add only the exercises and work sets; heart rate and duration stay attached to the imported session.")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach($drafts) { $draft in exerciseCard($draft) }
                        NoopButton("Add exercise", systemImage: "plus", kind: .secondary, fullWidth: true) {
                            drafts.append(Draft())
                        }
                        if let saveError {
                            Label(saveError, systemImage: "exclamationmark.triangle.fill")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.statusWarning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(NoopMetrics.screenPadding)
                    DemoScrollBottomAnchor()
                }
                .task { await scrollToDemoBottom(proxy) }
            }
            .navigationTitle("Add strength details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { Image(systemName: "checkmark") }
                    }
                        .accessibilityLabel("Save")
                        .disabled(saving || drafts.allSatisfy { $0.title.trimmingCharacters(in: .whitespaces).isEmpty })
                }
            }
        }
        // Seeded here rather than in an initialiser so re-opening the sheet always starts from what is
        // saved right now, not from whatever the previous presentation left behind.
        .task {
            guard drafts.isEmpty else { return }
            let restored = Self.drafts(from: existing, templates: templates)
            drafts = restored.isEmpty ? [Draft()] : restored
        }
    }

    private func exerciseCard(_ draft: Binding<Draft>) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                TextField("Exercise", text: draft.title)
                    .font(StrandFont.headline)
                Stepper(value: draft.workSets, in: 1...20) {
                    Text("\(draft.wrappedValue.workSets) work sets")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                }
                HStack {
                    Text("Primary muscle")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Picker("Primary muscle", selection: draft.muscle) {
                        ForEach(HevyMuscleGroup.allCases, id: \.self) { Text(LocalizedStringKey($0.label)).tag($0) }
                    }
                    .labelsHidden()
                }
                Text("Effort scale")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Picker("Effort scale", selection: draft.usesRIR) {
                    Text("RIR").tag(true); Text("RPE").tag(false)
                }
                .pickerStyle(.segmented)
                TextField(draft.wrappedValue.usesRIR ? "Optional RIR (0–4)" : "Optional RPE (6–10)",
                          text: draft.effort)
                    #if os(iOS)
                    .keyboardType(.decimalPad)
                    #endif
            }
        }
    }

    // MARK: - The mapping (pure, so it can be tested without a form)

    /// The rating one draft contributes, or nil when the field was left empty.
    ///
    /// RIR is converted to the RPE scale the rest of the app weights sets on (`10 − RIR`), because the
    /// muscle map and Strength Load price proximity to failure and must not learn a second scale. A
    /// value outside its scale is an error rather than a silent drop: a typed "12" meant something.
    static func rating(for draft: Draft) throws -> Double? {
        let text = draft.effort.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty else { return nil }
        guard let value = Double(text), value.isFinite else {
            throw DraftError.effortOutOfRange(exercise: draft.title)
        }
        let rpe = draft.usesRIR ? 10 - value : value
        guard (6...10).contains(rpe) else { throw DraftError.effortOutOfRange(exercise: draft.title) }
        return rpe
    }

    /// The catalogue entry and the workout one filled-in form describes.
    ///
    /// The workout id is the session's own window (or the entry being edited), so saving twice replaces
    /// the entry instead of adding a second copy of the same session.
    static func makeEntry(drafts: [Draft], session: UnifiedTrainingSession,
                          existingId: String?, now: Int)
        throws -> (templates: [HevyExerciseTemplate], workout: HevyWorkout) {
        let valid = drafts.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !valid.isEmpty else { throw DraftError.noExercise }
        var templates: [HevyExerciseTemplate] = []
        var exercises: [HevyExercise] = []
        for (index, draft) in valid.enumerated() {
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = title.lowercased().filter { $0.isLetter || $0.isNumber }
            let template = HevyExerciseTemplate(id: "manual.\(draft.muscle.rawValue).\(normalized)",
                                                title: title, type: "reps_only",
                                                primaryMuscleGroup: draft.muscle,
                                                secondaryMuscleGroups: [], equipment: .other,
                                                isCustom: true)
            let rpe = try rating(for: draft)
            let sets = (0..<draft.workSets).map {
                HevySet(index: $0, type: .normal, weightKg: nil, reps: nil,
                        distanceM: nil, durationS: nil, rpe: rpe, customMetric: nil)
            }
            templates.append(template)
            exercises.append(HevyExercise(index: index, title: title, templateId: template.id,
                                          supersetId: nil, notes: nil, sets: sets))
        }
        let workout = HevyWorkout(id: existingId ?? "manual-\(session.row.startTs)-\(session.row.endTs)",
                                  title: session.row.sport, routineId: nil, notes: nil,
                                  startTs: session.row.startTs, endTs: session.row.endTs,
                                  updatedAtTs: now, createdAtTs: now, exercises: exercises,
                                  source: .manual)
        return (templates, workout)
    }

    /// The form that re-opens onto an entry already saved. Work sets, muscle and rating come back from
    /// what was stored, so an edit changes one field instead of retyping the session.
    static func drafts(from workout: HevyWorkout?,
                       templates: [String: HevyExerciseTemplate]) -> [Draft] {
        guard let workout else { return [] }
        return workout.exercises.map { exercise in
            var draft = Draft()
            draft.title = exercise.title
            draft.workSets = max(1, exercise.workingSets.count)
            draft.muscle = exercise.templateId.flatMap { templates[$0]?.primaryMuscleGroup } ?? .other
            // Stored on the RPE scale; offered back on the same scale so the number does not change
            // meaning between saving and editing.
            if let rpe = exercise.workingSets.compactMap(\.rpe).first {
                draft.usesRIR = false
                draft.effort = rpe.formatted(.number.precision(.fractionLength(0...1)))
            }
            return draft
        }
    }

    private func save() async {
        saveError = nil
        guard let store = await repo.storeHandle() else {
            saveError = String(localized: "The training database is unavailable. Try again in a moment.")
            return
        }
        let entry: (templates: [HevyExerciseTemplate], workout: HevyWorkout)
        do {
            entry = try Self.makeEntry(drafts: drafts, session: session, existingId: existing?.id,
                                       now: Int(Date().timeIntervalSince1970))
        } catch DraftError.noExercise {
            saveError = String(localized: "Add at least one exercise before saving.")
            return
        } catch {
            saveError = String(localized: "Enter RIR between 0 and 4, or RPE between 6 and 10.")
            return
        }
        saving = true
        do {
            _ = try await store.upsertHevyExerciseTemplates(entry.templates)
            _ = try await store.upsertStrengthWorkouts([entry.workout])
            await onSaved()
            dismiss()
        } catch {
            saving = false
            saveError = String(localized: "The strength details could not be saved. Try again.")
        }
    }
}

#if DEBUG
/// Deterministic editor target for visual QA. It uses the same Health-only demo envelope that appears
/// on the Strength screen, so screenshots exercise the production editor without fabricating form state.
struct GenericStrengthDetailsDemoHost: View {
    @EnvironmentObject private var repo: Repository
    @State private var session: UnifiedTrainingSession?

    var body: some View {
        Group {
            if let session {
                GenericStrengthDetailsSheet(session: session, onSaved: {})
            } else {
                ProgressView()
                    .task {
                        let result = await repo.trainingSessions(days: 120)
                        session = result.sessions.first {
                            $0.kind == .strength && $0.components.contains {
                                WorkoutSource.isAppleHealth($0.row.source)
                            }
                        } ?? Self.sampleSession
                    }
            }
        }
    }

    /// A read-only fallback for simulators whose demo database predates the Health-only seed row.
    private static var sampleSession: UnifiedTrainingSession {
        let end = Int(Date().timeIntervalSince1970) - 86_400
        let row = WorkoutRow(startTs: end - 2_700, endTs: end,
                             sport: "Functional strength training", source: WorkoutSource.appleHealthSource,
                             durationS: 2_700, energyKcal: 260, avgHr: 118, maxHr: 157,
                             strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        let component = TrainingSessionComponent(id: "demo-health-strength", row: row, metadata: nil)
        return UnifiedTrainingSession(id: "demo-health-strength", kind: .strength, row: row,
                                      components: [component], fusionOrigin: "demo")
    }
}
#endif
