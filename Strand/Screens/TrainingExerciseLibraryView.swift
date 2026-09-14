import SwiftUI
import StrandDesign
import StrandTraining
import UniformTypeIdentifiers

/// Searchable, offline-first exercise library. Provider content is displayed with its source;
/// user-created exercises remain fully local and can be edited without an account.
struct TrainingExerciseLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    let exercises: [TrainingExercise]
    let onSave: (TrainingExercise) -> Void

    @State private var query = ""
    @State private var equipment = "all"
    @State private var selected: TrainingExercise?
    @State private var showingNewExercise = false
    @State private var showingCatalogImporter = false
    @State private var showingExerciseDB = false
    @State private var message: String?
    @AppStorage("training.favoriteExerciseIds") private var favoritePayload = ""

    var body: some View {
        List {
            if !favoriteExercises.isEmpty && query.isEmpty && equipment == "all" {
                Section("Favorites") {
                    ForEach(favoriteExercises) { row($0) }
                }
            }

            Section("All exercises") {
                if filteredExercises.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text("No matching exercises")
                            .font(StrandFont.subhead.weight(.semibold))
                        Text("Try another search or add your own exercise.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredExercises) { row($0) }
                }
            }
        }
        .navigationTitle(Text("Exercise library"))
        .searchable(text: $query, prompt: Text("Exercise, muscle or equipment"))
        .safeAreaInset(edge: .top) { equipmentFilter }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New exercise") { showingNewExercise = true }
                    Button("ExerciseDB source") { showingExerciseDB = true }
                    Button("Import licensed catalog") { showingCatalogImporter = true }
                } label: { Label("Add", systemImage: "plus") }
            }
        }
        .sheet(item: $selected) { exercise in
            NavigationStack {
                TrainingExerciseDetailView(exercise: exercise, isFavorite: favorites.contains(exercise.id)) {
                    toggleFavorite(exercise.id)
                }
            }
        }
        .sheet(isPresented: $showingNewExercise) {
            NavigationStack {
                TrainingCustomExerciseEditor { exercise in
                    onSave(exercise)
                    showingNewExercise = false
                }
            }
        }
        .sheet(isPresented: $showingExerciseDB) {
            NavigationStack {
                ExerciseDBSourceView { values in
                    values.forEach(onSave)
                    message = String(localized: "The selected exercises were added.")
                    showingExerciseDB = false
                }
            }
        }
        .fileImporter(isPresented: $showingCatalogImporter, allowedContentTypes: [.json]) { result in
            importCatalog(result)
        }
        .alert("Exercise library", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private var equipmentFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip("All", id: "all")
                ForEach(equipmentOptions, id: \.self) { value in
                    filterChip(value.replacingOccurrences(of: "-", with: " ").capitalized, id: value)
                }
            }
            .padding(.horizontal, NoopMetrics.screenPadding)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func filterChip(_ title: String, id: String) -> some View {
        Button(title) { equipment = id }
            .font(StrandFont.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(equipment == id ? Color.white : StrandPalette.textSecondary)
            .background(equipment == id ? StrandPalette.accent : StrandPalette.surfaceRaised,
                        in: Capsule())
            .buttonStyle(.plain)
    }

    private func row(_ exercise: TrainingExercise) -> some View {
        Button { selected = exercise } label: {
            HStack(spacing: 12) {
                Image(systemName: modeIcon(exercise.mode))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(StrandPalette.accent)
                    .background(StrandPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 3) {
                    Text(exercise.title)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(metadata(exercise))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                if favorites.contains(exercise.id) {
                    Image(systemName: "star.fill").foregroundStyle(StrandPalette.metricAmber)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var filteredExercises: [TrainingExercise] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return exercises.filter { exercise in
            let equipmentMatches = equipment == "all" || exercise.equipmentIds.contains(equipment)
            let queryMatches = needle.isEmpty
                || exercise.title.localizedCaseInsensitiveContains(needle)
                || (exercise.primaryMuscleId?.localizedCaseInsensitiveContains(needle) ?? false)
                || exercise.secondaryMuscleIds.contains { $0.localizedCaseInsensitiveContains(needle) }
                || exercise.equipmentIds.contains { $0.localizedCaseInsensitiveContains(needle) }
            return equipmentMatches && queryMatches
        }
    }

    private var equipmentOptions: [String] {
        Array(Set(exercises.flatMap(\.equipmentIds))).sorted()
    }

    private var favorites: Set<String> {
        Set(favoritePayload.split(separator: "\n").map(String.init))
    }

    private var favoriteExercises: [TrainingExercise] {
        exercises.filter { favorites.contains($0.id) }
    }

    private func toggleFavorite(_ id: String) {
        var values = favorites
        if !values.insert(id).inserted { values.remove(id) }
        favoritePayload = values.sorted().joined(separator: "\n")
    }

    private func importCatalog(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let archive = try ExerciseCatalogArchive.decode(Data(contentsOf: url))
            guard archive.rights.allowsOfflineCache else {
                message = String(localized: "This catalog does not allow local storage.")
                return
            }
            archive.exercises.forEach(onSave)
            message = String(localized: "The exercise catalog was imported.")
        } catch {
            message = String(localized: "The exercise catalog could not be imported.")
        }
    }

    private func metadata(_ exercise: TrainingExercise) -> String {
        let muscle = exercise.primaryMuscleId?.replacingOccurrences(of: "_", with: " ").capitalized
            ?? String(localized: "Other")
        let equipment = exercise.equipmentIds.first?.replacingOccurrences(of: "-", with: " ").capitalized
            ?? String(localized: "No equipment")
        return "\(muscle) · \(equipment)"
    }

    private func modeIcon(_ mode: TrainingMeasurementMode) -> String {
        switch mode {
        case .duration: return "timer"
        case .distanceDuration: return "point.topleft.down.to.point.bottomright.curvepath"
        case .bodyweightReps, .repetitions: return "figure.strengthtraining.traditional"
        default: return "dumbbell.fill"
        }
    }
}

private struct TrainingExerciseDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let exercise: TrainingExercise
    let isFavorite: Bool
    let onToggleFavorite: () -> Void

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                NoopCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(exercise.title).font(StrandFont.title1)
                                Text(modeTitle(exercise.mode))
                                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                            }
                            Spacer()
                            Button(action: onToggleFavorite) {
                                Image(systemName: isFavorite ? "star.fill" : "star")
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(isFavorite ? StrandPalette.metricAmber : StrandPalette.textSecondary)
                        }
                        LabeledContent("Primary muscle", value: muscle(exercise.primaryMuscleId))
                        if !exercise.secondaryMuscleIds.isEmpty {
                            LabeledContent("Also involved", value: exercise.secondaryMuscleIds.map(muscle).joined(separator: ", "))
                        }
                        LabeledContent("Equipment", value: exercise.equipmentIds.isEmpty
                                       ? String(localized: "No equipment")
                                       : exercise.equipmentIds.map(muscle).joined(separator: ", "))
                    }
                }

                if let raw = exercise.mediaId, let url = URL(string: raw), url.scheme == "https" {
                    NoopCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Exercise media", systemImage: "play.rectangle")
                                .font(StrandFont.subhead.weight(.semibold))
                            Text("Media stays with its provider and is opened only when you request it. It is not copied into workout history.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            Link("Open provider media", destination: url)
                                .font(StrandFont.subhead.weight(.semibold))
                        }
                    }
                }

                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    SectionHeader("How to perform it", overline: "Instructions")
                    NoopCard {
                        if exercise.instructions.isEmpty {
                            Text("Instructions are not available for this exercise yet. You can still use it for logging.")
                                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(exercise.instructions.enumerated()), id: \.offset) { index, instruction in
                                    HStack(alignment: .top, spacing: 10) {
                                        Text("\(index + 1)")
                                            .font(StrandFont.caption.weight(.bold))
                                            .frame(width: 24, height: 24)
                                            .background(StrandPalette.accent.opacity(0.12), in: Circle())
                                        Text(instruction).font(StrandFont.subhead)
                                    }
                                }
                            }
                        }
                    }
                }

                NoopCard {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Content source").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                        Text(sourceTitle).font(StrandFont.subhead.weight(.semibold))
                        Text(sourceExplanation).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
            .padding(NoopMetrics.screenPadding)
        }
        .navigationTitle(Text("Exercise"))
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }

    private func muscle(_ value: String?) -> String {
        guard let value else { return String(localized: "Other") }
        return value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func modeTitle(_ mode: TrainingMeasurementMode) -> String {
        switch mode {
        case .weightReps: return String(localized: "Weight and repetitions")
        case .bodyweightReps: return String(localized: "Bodyweight repetitions")
        case .weightedBodyweight: return String(localized: "Weighted bodyweight")
        case .assistedBodyweight: return String(localized: "Assisted bodyweight")
        case .repetitions: return String(localized: "Repetitions")
        case .duration: return String(localized: "Duration")
        case .distanceDuration: return String(localized: "Distance and duration")
        }
    }

    private var sourceTitle: String {
        switch exercise.source {
        case .noop: return "NOOP"
        case .user: return String(localized: "Created by you")
        case .exerciseDB: return "ExerciseDB"
        case .imported: return String(localized: "Imported")
        }
    }

    private var sourceExplanation: String {
        switch exercise.source {
        case .noop: return String(localized: "Included in the offline starter library.")
        case .user: return String(localized: "Stored locally with your training data.")
        case .exerciseDB: return String(localized: "Provider content is shown only under the provider's applicable rights.")
        case .imported: return String(localized: "Imported metadata keeps its original source reference.")
        }
    }
}

private struct ExerciseDBSourceView: View {
    @Environment(\.dismiss) private var dismiss
    let onImport: ([TrainingExercise]) -> Void
    @AppStorage("training.exerciseDB.endpoint") private var endpoint =
        "https://oss.exercisedb.dev/api/v1/exercises"
    @AppStorage("training.exerciseDB.header") private var headerName = "x-rapidapi-key"
    @State private var key = ""
    @State private var results: [TrainingExercise] = []
    @State private var selected = Set<String>()
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var hasStoredKey = false

    var body: some View {
        Form {
            Section {
                TextField("HTTPS exercise endpoint", text: $endpoint)
                    .trainingTechnicalTextInput()
                TextField("API key header", text: $headerName)
                    .trainingTechnicalTextInput()
                SecureField(hasStoredKey ? "Stored key — enter to replace" : "API key, if required", text: $key)
                if hasStoredKey {
                    Button("Remove stored key", role: .destructive) {
                        ExerciseDBCredentials.clear(); hasStoredKey = false; key = ""
                    }
                }
                Button {
                    Task { await load() }
                } label: {
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                    else { Label("Load exercises", systemImage: "arrow.down.circle").frame(maxWidth: .infinity) }
                }
                .disabled(loading || !endpoint.lowercased().hasPrefix("https://"))
            } header: {
                Text("Personal provider access")
            } footer: {
                Text("The free ExerciseDB endpoint does not require a key. A personal key for another compatible provider is stored in this device's Keychain. NOOP requests one page only and sends no workout or health data.")
            }

            if !results.isEmpty {
                Section {
                    Button(selected.count == results.count ? "Clear selection" : "Select all") {
                        selected = selected.count == results.count ? [] : Set(results.map(\.id))
                    }
                    ForEach(results) { exercise in
                        Toggle(isOn: Binding(get: { selected.contains(exercise.id) }, set: { enabled in
                            if enabled { selected.insert(exercise.id) } else { selected.remove(exercise.id) }
                        })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(exercise.title)
                                Text(exercise.primaryMuscleId?.replacingOccurrences(of: "_", with: " ").capitalized
                                     ?? String(localized: "Muscle not mapped"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("Preview") }
                  footer: { Text("Only selected exercise definitions are stored. Workout rows retain the exercise id, not instructions or media files.") }
            }

            if let errorMessage {
                Section { Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }
        }
        .navigationTitle(Text("ExerciseDB"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add selected") { onImport(results.filter { selected.contains($0.id) }) }
                    .disabled(selected.isEmpty)
            }
        }
        .onAppear { hasStoredKey = ExerciseDBCredentials.read() != nil }
    }

    @MainActor private func load() async {
        loading = true; errorMessage = nil
        let supplied = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !supplied.isEmpty {
            guard ExerciseDBCredentials.save(supplied) else {
                loading = false; errorMessage = String(localized: "The API key could not be saved securely.")
                return
            }
            hasStoredKey = true
        }
        do {
            let values = try await ExerciseDBProviderClient.fetch(
                endpoint: endpoint, key: supplied.isEmpty ? ExerciseDBCredentials.read() : supplied,
                headerName: headerName)
            results = values
            selected = Set(values.map(\.id))
        } catch {
            errorMessage = String(localized: "The provider could not be reached or returned an unsupported response.")
        }
        loading = false
    }
}

private extension View {
    @ViewBuilder
    func trainingTechnicalTextInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }
}

private struct TrainingCustomExerciseEditor: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (TrainingExercise) -> Void
    @State private var name = ""
    @State private var mode = TrainingMeasurementMode.weightReps
    @State private var primaryMuscle = "chest"
    @State private var equipment = ""
    @State private var instruction = ""
    @State private var unilateral = false

    var body: some View {
        Form {
            Section("Exercise") {
                TextField("Name", text: $name)
                Picker("Tracking", selection: $mode) {
                    ForEach(TrainingMeasurementMode.allCases, id: \.rawValue) { value in
                        Text(modeLabel(value)).tag(value)
                    }
                }
                Toggle("Track left and right separately", isOn: $unilateral)
            }
            Section("Muscle and equipment") {
                Picker("Primary muscle", selection: $primaryMuscle) {
                    ForEach(TrainingMuscleCatalog.all) { muscle in Text(muscle.name).tag(muscle.id) }
                }
                TextField("Equipment, optional", text: $equipment)
            }
            Section("Instructions") {
                TextField("One clear instruction, optional", text: $instruction, axis: .vertical)
            }
            Section {
                Text("Custom exercises stay on this device and can be used in routines and freestyle workouts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(Text("New exercise"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    let equipmentIds = equipment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? [] : [equipment.lowercased().replacingOccurrences(of: " ", with: "-")]
                    let instructions = instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? [] : [instruction.trimmingCharacters(in: .whitespacesAndNewlines)]
                    onSave(TrainingExercise(id: "user:\(UUID().uuidString.lowercased())", title: trimmed,
                        mode: mode, primaryMuscleId: primaryMuscle, equipmentIds: equipmentIds,
                        instructions: instructions, isUnilateral: unilateral, source: .user))
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func modeLabel(_ value: TrainingMeasurementMode) -> String {
        switch value {
        case .weightReps: return String(localized: "Weight and repetitions")
        case .bodyweightReps: return String(localized: "Bodyweight repetitions")
        case .weightedBodyweight: return String(localized: "Weighted bodyweight")
        case .assistedBodyweight: return String(localized: "Assisted bodyweight")
        case .repetitions: return String(localized: "Repetitions")
        case .duration: return String(localized: "Duration")
        case .distanceDuration: return String(localized: "Distance and duration")
        }
    }
}
