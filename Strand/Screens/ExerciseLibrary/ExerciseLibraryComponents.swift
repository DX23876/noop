import SwiftUI
import MuscleMap
import StrandDesign
import StrandTraining

/// A selectable capsule used by the library's filter rows.
struct ExerciseFilterChip: View {
    let title: String
    var systemImage: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
        }
        .font(StrandFont.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
        .background(selected ? StrandPalette.accent : StrandPalette.surfaceRaised, in: Capsule())
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One exercise in the library: its still (or its measurement symbol without media), name, main muscle and
/// equipment, and the mode's quick action. The still is decoded to its displayed size, so scrolling the
/// full library never decodes animations.
struct ExerciseLibraryRow: View {
    let exercise: TrainingExercise
    let subtitle: String
    let isFavorite: Bool
    let mode: ExerciseLibraryMode
    let onOpen: () -> Void
    let onAction: (() -> Void)?
    @ObservedObject private var media = ExerciseMediaStore.shared

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 3) {
                        Text(exercise.title)
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .multilineTextAlignment(.leading)
                        Text(subtitle)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if isFavorite {
                        Image(systemName: "star.fill").foregroundStyle(StrandPalette.metricAmber)
                            .accessibilityLabel(Text("Favorite"))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let onAction, let title = mode.actionTitle ?? (mode == .browse ? String(localized: "Add") : nil) {
                Button(action: onAction) {
                    Label(title, systemImage: mode.actionSymbol)
                        .labelStyle(.titleAndIcon)
                        .font(StrandFont.caption.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(StrandPalette.accent.opacity(0.14), in: Capsule())
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(title) \(exercise.title)"))
            } else {
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if media.isAvailable, let still = media.mediaURL(for: exercise, variant: .still) {
            ExerciseMediaThumbnail(url: still, side: 48)
        } else {
            Image(systemName: Self.modeIcon(exercise.mode))
                .frame(width: 48, height: 48)
                .foregroundStyle(StrandPalette.accent)
                .background(StrandPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    static func metadata(_ exercise: TrainingExercise) -> String {
        let muscle = TrainingDisplayNames.muscle(exercise.primaryMuscleId)
        let equipment = exercise.equipmentIds.first.map(TrainingDisplayNames.equipment)
            ?? String(localized: "No equipment")
        return "\(muscle) · \(equipment)"
    }

    static func modeIcon(_ mode: TrainingMeasurementMode) -> String {
        switch mode {
        case .duration: return "timer"
        case .distanceDuration: return "point.topleft.down.to.point.bottomright.curvepath"
        case .bodyweightReps, .repetitions: return "figure.strengthtraining.traditional"
        default: return "dumbbell.fill"
        }
    }
}

/// Find exercises by tapping a muscle on the body. The tapped group is outlined on the front and back
/// figures and listed with its exercise count; the exercises that target it come first, then the ones that
/// also train it. Tapping the group again, or "Clear selection", shows the whole body again.
struct ExerciseMusclePickerView: View {
    let exercises: [TrainingExercise]
    let mode: ExerciseLibraryMode
    let onPick: ((TrainingExercise) -> Void)?
    let onOpen: (TrainingExercise) -> Void
    @State private var selection: ExerciseMuscleGroup?
    @State private var query = ""
    @State private var counts: [ExerciseMuscleGroup: Int] = [:]
    @AppStorage("training.muscleMap.figure") private var figureRaw = BodyGender.male.rawValue

    var body: some View {
        List {
            Section {
                VStack(spacing: NoopMetrics.space3) {
                    HStack(spacing: NoopMetrics.space2) {
                        figure(.front)
                        figure(.back)
                    }
                    .frame(height: 280)
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(ExerciseMuscleGroup.allCases) { group in
                                    ExerciseFilterChip(title: "\(group.title) \(counts[group] ?? 0)",
                                                       selected: selection == group) {
                                        toggle(group)
                                    }
                                    .id(group)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .onChange(of: selection) { value in
                            if let value { withAnimation { proxy.scrollTo(value, anchor: .center) } }
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } footer: {
                Text("Choose a muscle to see the exercises that train it.")
            }

            if let selection {
                let matches = matching(selection)
                Section {
                    if matches.primary.isEmpty && matches.secondary.isEmpty {
                        Text("No exercises match.").foregroundStyle(StrandPalette.textSecondary)
                    }
                    ForEach(matches.primary) { row($0, involvement: String(localized: "Main target")) }
                    ForEach(matches.secondary) { row($0, involvement: String(localized: "Also trains")) }
                } header: {
                    HStack {
                        Text("Exercises for \(selection.title)")
                        Spacer()
                        Button("Clear selection") { self.selection = nil }
                            .font(StrandFont.caption.weight(.semibold))
                    }
                }
            }
        }
        .navigationTitle(Text("Find by muscle"))
        .searchable(text: $query, prompt: Text("Exercise or equipment"))
        .task(id: exercises.count) {
            // Every exercise is matched against every group once; keep that off the main thread.
            let all = exercises
            counts = await Task.detached(priority: .userInitiated) { ExerciseMuscleGroup.counts(all) }.value
        }
    }

    private func figure(_ side: BodySide) -> some View {
        MuscleMap.BodyView(gender: BodyGender(rawValue: figureRaw) ?? .male, side: side,
                           style: TrainingMuscleMapAppearance.style)
            .selected(selection?.renderedMuscles ?? [])
            .showSubGroups()
            .onMuscleSelected { muscle, _ in
                if let group = ExerciseMuscleGroup.group(for: muscle) { toggle(group) }
            }
            .accessibilityLabel(Text(side == .front ? "Front of body" : "Back of body"))
    }

    private func toggle(_ group: ExerciseMuscleGroup) {
        selection = selection == group ? nil : group
    }

    private func matching(_ group: ExerciseMuscleGroup) -> (primary: [TrainingExercise], secondary: [TrainingExercise]) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var primary: [TrainingExercise] = [], secondary: [TrainingExercise] = []
        for exercise in exercises {
            guard needle.isEmpty
                    || exercise.title.localizedCaseInsensitiveContains(needle)
                    || exercise.equipmentIds.contains(where: {
                        TrainingDisplayNames.equipment($0).localizedCaseInsensitiveContains(needle) })
            else { continue }
            switch group.involvement(of: exercise) {
            case .primary: primary.append(exercise)
            case .secondary: secondary.append(exercise)
            case nil: break
            }
        }
        return (primary, secondary)
    }

    private func row(_ exercise: TrainingExercise, involvement: String) -> some View {
        ExerciseLibraryRow(exercise: exercise,
                           subtitle: "\(involvement) · \(ExerciseLibraryRow.metadata(exercise))",
                           isFavorite: false, mode: mode,
                           onOpen: { onOpen(exercise) },
                           onAction: onPick.map { pick in { pick(exercise) } })
    }
}
