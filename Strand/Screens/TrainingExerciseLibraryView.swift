import SwiftUI
import StrandDesign
import StrandTraining
import UniformTypeIdentifiers

/// Searchable, offline-first exercise library. Provider content is displayed with its source;
/// user-created exercises remain fully local and can be edited without an account.
struct TrainingExerciseLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    let exercises: [TrainingExercise]
    var performance: TrainingPerformanceHistory = .empty
    /// Present only while a workout is running, so the library can add straight into it.
    var onAddToWorkout: ((TrainingExercise) -> Void)?
    let onSave: (TrainingExercise) -> Void

    @State private var query = ""
    @State private var equipment = "all"
    @State private var region: TrainingBodyRegion?
    @State private var measurement: TrainingMeasurementMode?
    @State private var muscle: String?
    @State private var selected: TrainingExercise?
    @State private var showingNewExercise = false
    @State private var showingCatalogImporter = false
    @State private var showingExerciseDB = false
    @State private var showingMediaManager = false
    @State private var message: String?
    @AppStorage("training.favoriteExerciseIds") private var favoritePayload = ""

    var body: some View {
        List {
            if !favoriteExercises.isEmpty && query.isEmpty && !hasActiveFilters {
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
                    Picker("Body region", selection: $region) {
                        Text("Any body region").tag(TrainingBodyRegion?.none)
                        ForEach(TrainingBodyRegion.allCases.filter { $0 != .other }) { value in
                            Text(TrainingDisplayNames.region(value)).tag(TrainingBodyRegion?.some(value))
                        }
                    }
                    Picker("Muscle", selection: $muscle) {
                        Text("Any muscle").tag(String?.none)
                        ForEach(TrainingMuscleCatalog.all) { item in
                            Text(TrainingDisplayNames.muscle(item.id)).tag(String?.some(item.id))
                        }
                    }
                    Picker("Type", selection: $measurement) {
                        Text("Any type").tag(TrainingMeasurementMode?.none)
                        ForEach(TrainingMeasurementMode.allCases, id: \.rawValue) { value in
                            Text(TrainingDisplayNames.measurement(value)).tag(TrainingMeasurementMode?.some(value))
                        }
                    }
                    if hasActiveFilters {
                        Divider()
                        Button("Clear filters") { clearFilters() }
                    }
                } label: {
                    Label("Filter", systemImage: hasActiveFilters
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New exercise") { showingNewExercise = true }
                    Button("ExerciseDB source") { showingExerciseDB = true }
                    Button("Import licensed catalog") { showingCatalogImporter = true }
                    Button("Exercise media") { showingMediaManager = true }
                } label: { Label("Add", systemImage: "plus") }
            }
        }
        .sheet(item: $selected) { exercise in
            NavigationStack {
                TrainingExerciseDetailView(
                    exercise: exercise, isFavorite: favorites.contains(exercise.id),
                    records: performance.records(for: exercise.id, mode: exercise.mode),
                    recent: Array(performance.entries(for: exercise.id).reversed().prefix(5)),
                    onAddToWorkout: onAddToWorkout.map { add in
                        { add(exercise); selected = nil }
                    },
                    onToggleFavorite: { toggleFavorite(exercise.id) })
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
        .sheet(isPresented: $showingMediaManager) {
            NavigationStack { ExerciseMediaManagementView() }
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
                filterChip(String(localized: "All"), id: "all")
                if !availableEquipment.isEmpty {
                    filterChip(String(localized: "My equipment"), id: "available")
                }
                ForEach(equipmentOptions, id: \.self) { value in
                    filterChip(TrainingDisplayNames.equipment(value), id: value)
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

    private var hasActiveFilters: Bool {
        region != nil || muscle != nil || measurement != nil || equipment != "all"
    }

    private func clearFilters() {
        region = nil
        muscle = nil
        measurement = nil
        equipment = "all"
    }

    /// The region comes from the reviewed anatomy where there is one, so a filter can never disagree
    /// with the muscle map; an unmapped exercise falls back to its own primary muscle.
    private func bodyRegion(_ exercise: TrainingExercise) -> TrainingBodyRegion {
        if let anatomy = TrainingMuscleProjection.anatomy(for: exercise) { return anatomy.bodyRegion }
        return TrainingBodyRegion.forMuscles([exercise.primaryMuscleId].compactMap { $0 })
    }

    private func matchesMuscle(_ exercise: TrainingExercise, _ muscleId: String) -> Bool {
        if exercise.primaryMuscleId == muscleId { return true }
        if exercise.secondaryMuscleIds.contains(muscleId) { return true }
        guard let anatomy = TrainingMuscleProjection.anatomy(for: exercise) else { return false }
        return anatomy.primaryMuscleIds.contains(muscleId) || anatomy.secondaryMuscleIds.contains(muscleId)
    }

    private var filteredExercises: [TrainingExercise] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return exercises.filter { exercise in
            let regionMatches = region == nil || bodyRegion(exercise) == region
            let muscleMatches = muscle.map { matchesMuscle(exercise, $0) } ?? true
            let measurementMatches = measurement == nil || exercise.mode == measurement
            let equipmentMatches = equipment == "all"
                || (equipment == "available" && matchesAvailableEquipment(exercise))
                || exercise.equipmentIds.map(TrainingDisplayNames.canonicalEquipment).contains(equipment)
            let queryMatches = needle.isEmpty
                || exercise.title.localizedCaseInsensitiveContains(needle)
                || (exercise.primaryMuscleId?.localizedCaseInsensitiveContains(needle) ?? false)
                || TrainingDisplayNames.muscle(exercise.primaryMuscleId).localizedCaseInsensitiveContains(needle)
                || exercise.equipmentIds.contains { TrainingDisplayNames.equipment($0).localizedCaseInsensitiveContains(needle) }
                || exercise.secondaryMuscleIds.contains { $0.localizedCaseInsensitiveContains(needle) }
                || exercise.equipmentIds.contains { $0.localizedCaseInsensitiveContains(needle) }
            return regionMatches && muscleMatches && measurementMatches && equipmentMatches && queryMatches
        }
    }

    private var equipmentOptions: [String] {
        Array(Set(exercises.flatMap(\.equipmentIds).map(TrainingDisplayNames.canonicalEquipment))).sorted()
    }

    private var availableEquipment: Set<String> {
        TrainingPreferences.availableEquipment
    }

    private func matchesAvailableEquipment(_ exercise: TrainingExercise) -> Bool {
        TrainingPreferences.exercise(exercise, matches: availableEquipment)
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
        let muscle = TrainingDisplayNames.muscle(exercise.primaryMuscleId)
        let equipment = exercise.equipmentIds.first.map(TrainingDisplayNames.equipment)
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
    let records: TrainingPerformanceHistory.Records
    let recent: [TrainingPerformanceHistory.Entry]
    let onAddToWorkout: (() -> Void)?
    let onToggleFavorite: () -> Void
    @ObservedObject private var media = ExerciseMediaStore.shared
    @State private var showingMediaManager = false

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
                                       : exercise.equipmentIds.map(TrainingDisplayNames.equipment).joined(separator: ", "))
                    }
                }

                if let item = ExerciseMediaRegistry.shared.media(for: exercise) {
                    NoopCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Exercise media", systemImage: "play.rectangle")
                                .font(StrandFont.subhead.weight(.semibold))
                            ExerciseMediaView(media: item, minHeight: 150, maxHeight: 280)
                        }
                    }
                } else if exercise.mediaId != nil {
                    NoopCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Exercise media", systemImage: "play.rectangle")
                                .font(StrandFont.subhead.weight(.semibold))
                            Text("Optional exercise media has not been downloaded. Logging works without it and media is never copied into workout history.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            Button("Manage exercise media") { showingMediaManager = true }
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

                yourHistory

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
        .safeAreaInset(edge: .bottom) {
            if let onAddToWorkout {
                Button(action: onAddToWorkout) {
                    Label("Add to workout", systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                .padding(NoopMetrics.screenPadding)
                .background(.ultraThinMaterial)
            }
        }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(isPresented: $showingMediaManager) {
            NavigationStack { ExerciseMediaManagementView() }
        }
    }

    /// Everything this exercise has produced so far, from native and resolved imported sessions alike.
    @ViewBuilder private var yourHistory: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Your history", overline: "This exercise")
            NoopCard {
                if records.sessionCount == 0 {
                    Text("No sessions with this exercise yet. Once you log one, its records and history appear here.")
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                                  spacing: 10) {
                            historyFact(String(localized: "Sessions"), records.sessionCount.formatted())
                            historyFact(String(localized: "Heaviest"), records.heaviestSetKg
                                .map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) kg" } ?? "—")
                            historyFact(String(localized: "Best 1RM · est."), records.bestEstimatedOneRepMaxKg
                                .map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) kg" } ?? "—")
                        }
                        if !recent.isEmpty {
                            Divider().overlay(StrandPalette.hairline)
                            ForEach(Array(recent.enumerated()), id: \.offset) { _, entry in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(Date(timeIntervalSince1970: TimeInterval(entry.startTs)), style: .date)
                                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                                    if !entry.isNative {
                                        Text("Imported").font(StrandFont.caption)
                                            .foregroundStyle(StrandPalette.textTertiary)
                                    }
                                    Spacer()
                                    Text(sessionSummary(entry)).font(StrandFont.caption.monospacedDigit())
                                        .foregroundStyle(StrandPalette.textSecondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        if records.bestEstimatedOneRepMaxKg != nil {
                            Text("The estimated one-rep maximum is a projection from your logged sets, not a lift you performed.")
                                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func historyFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(StrandFont.number(18)).foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func sessionSummary(_ entry: TrainingPerformanceHistory.Entry) -> String {
        let working = entry.workingSets
        let best = working.compactMap(\.weightKg).filter { $0 > 0 }.max()
        let sets = String(localized: "\(working.count) sets")
        guard let best else { return sets }
        return "\(sets) · \(best.formatted(.number.precision(.fractionLength(0...1)))) kg"
    }

    private func muscle(_ value: String?) -> String {
        TrainingDisplayNames.muscle(value)
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

struct ExerciseMediaManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var media = ExerciseMediaStore.shared
    @State private var showingDisclosure = false
    @State private var manifest: MediaManifest?

    var body: some View {
        Form {
            Section("Optional exercise media") {
                Text("Exercise logging, routines and analytics work without media. NOOP does not bundle, host or mirror these files.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                stateRow
            }
            Section("Source and rights") {
                LabeledContent("Source", value: media.provider.source.host ?? media.provider.source.absoluteString)
                LabeledContent("Rights holder", value: media.provider.rightsHolder)
                if let manifest {
                    LabeledContent("Downloaded files", value: manifest.fileCount.formatted())
                    LabeledContent("Archive checksum", value: String(manifest.archiveSHA256.prefix(16)))
                }
                Text(media.provider.attribution).font(StrandFont.caption)
                Text(media.provider.rightsStatus).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Text("A user-initiated download does not create any additional licence through NOOP.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            Section("Controls") {
                if media.isWithdrawn {
                    Label("NOOP has withdrawn this media provider. Exercises, routines and analytics are unaffected.",
                          systemImage: "nosign")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                } else {
                    Toggle("Disable this media provider", isOn: Binding(get: { media.isDisabled }, set: { media.setDisabled($0) }))
                }
                if media.isAvailable {
                    Button("Delete downloaded media", role: .destructive) { media.deleteMedia() }
                } else if !media.isDisabled {
                    Button(media.canResumeDownload ? "Resume download" : "Download media") {
                        showingDisclosure = true
                    }
                }
                if case .downloading = media.state { Button("Cancel download", role: .cancel) { media.cancel() } }
            }
        }
        .navigationTitle(Text("Exercise media"))
        .task(id: media.state) { manifest = media.installedManifest() }
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .sheet(isPresented: $showingDisclosure) {
            NavigationStack {
                ExerciseMediaDisclosureView(provider: media.provider) {
                    showingDisclosure = false
                    media.download()
                }
            }
        }
    }

    @ViewBuilder private var stateRow: some View {
        switch media.state {
        case .unavailable: Label("Not downloaded", systemImage: "arrow.down.circle")
        case .ready(let bytes): Label(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), systemImage: "checkmark.circle")
        case .downloading(let progress): ProgressView("Downloading", value: progress)
        case .installing: ProgressView { Text("Checking and installing") }
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
        case .disabled: Label("Provider disabled", systemImage: "nosign")
        }
    }
}

/// Everything the wearer must see before an external media download starts. The download begins only
/// from this screen's explicit confirmation.
private struct ExerciseMediaDisclosureView: View {
    @Environment(\.dismiss) private var dismiss
    let provider: ExerciseMediaStore.Provider
    let onDownload: () -> Void

    var body: some View {
        Form {
            Section("Source and rights") {
                LabeledContent("Download endpoint") {
                    Text(provider.source.absoluteString)
                        .font(StrandFont.caption)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                LabeledContent("Rights holder", value: provider.rightsHolder)
                Text(provider.attribution).font(StrandFont.caption)
                Text(provider.rightsStatus)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.statusWarning)
            }
            Section("Download") {
                LabeledContent("Approximate size",
                               value: ByteCountFormatter.string(fromByteCount: provider.approximateBytes,
                                                                countStyle: .file))
                Text("The files are downloaded directly from this external source into private storage on this device and are excluded from backups. A network connection is required.")
                Text("NOOP does not bundle, host, mirror or proxy these files. A download you start does not create any additional licence through NOOP.")
                Text("Training, routines, workout logging and analytics work fully without media. You can delete the downloaded files at any time.")
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
        }
        .navigationTitle(Text("Download external media?"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Download from external source", action: onDownload)
            }
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
                                Text(exercise.primaryMuscleId.map(TrainingDisplayNames.muscle)
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
                    ForEach(TrainingMuscleCatalog.all) { muscle in Text(TrainingDisplayNames.muscle(muscle.id)).tag(muscle.id) }
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
