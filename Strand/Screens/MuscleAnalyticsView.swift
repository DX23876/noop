import SwiftUI
import MuscleMap
import StrandAnalytics
import StrandDesign
import StrandTraining

struct MuscleAnalyticsView: View {
    let history: ResolvedStrengthHistory
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                MuscleAnalyticsSurface(history: history, compact: false)
                Link("Body geometry: MuscleMap · MIT License",
                     destination: URL(string: "https://github.com/melihcolpan/MuscleMap")!)
                    .font(StrandFont.caption)
            }
            .padding(NoopMetrics.screenPadding)
        }
        .navigationTitle("Muscle analytics")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

struct MuscleAnalyticsSurface: View {
    enum Mode: String, CaseIterable, Identifiable {
        case balance, fatigue, strength
        var id: String { rawValue }
        var label: String {
            switch self {
            case .balance: return String(localized: "Balance")
            case .fatigue: return String(localized: "Fatigue")
            case .strength: return String(localized: "Strength")
            }
        }
    }

    struct Selection: Identifiable {
        let id: String
    }

    let history: ResolvedStrengthHistory
    let compact: Bool
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = MuscleAnalyticsModel()
    @State private var mode = Mode.balance
    @State private var side = BodySide.front
    @State private var selection: Selection?
    @AppStorage("training.bodyFigure") private var figureRaw = BodyGender.male.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Picker("View", selection: $mode) {
                ForEach(Mode.allCases) { option in Text(option.label).tag(option) }
            }
            .pickerStyle(.segmented)

            Text(question)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)

            HStack(spacing: NoopMetrics.space2) {
                Picker("Body side", selection: $side) {
                    Text("Front").tag(BodySide.front)
                    Text("Back").tag(BodySide.back)
                }
                .pickerStyle(.segmented)
                Menu {
                    Button("Male figure") { figureRaw = BodyGender.male.rawValue }
                    Button("Female figure") { figureRaw = BodyGender.female.rawValue }
                } label: {
                    Image(systemName: "figure.stand").frame(width: 34, height: 30)
                }
                .buttonStyle(.bordered)
            }

            MuscleMap.BodyView(
                gender: BodyGender(rawValue: figureRaw) ?? .male,
                side: side,
                style: TrainingMuscleMapAppearance.style)
                .heatmap(mapIntensities, colorScale: colorScale)
                .showSubGroups()
                .animated(duration: reduceMotion ? 0 : 0.25)
                .onMuscleSelected { muscle, _ in select(muscle) }
                .frame(height: compact ? 250 : 330)
                .accessibilityLabel(accessibilityLabel)

            if model.loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if currentMuscleIds.isEmpty {
                Text(emptyText)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                coverageRow
                if !compact { readingList }
            }

            Text(methodText)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .task(id: historyRevision) { await model.load(history: history, repo: repo) }
        .sheet(item: $selection) { item in
            NavigationStack {
                MuscleMetricDetailView(muscleId: item.id, mode: mode,
                                       balance: balance(item.id), fatigue: fatigue(item.id),
                                       strength: strength(item.id))
            }
        }
    }

    private var question: String {
        switch mode {
        case .balance: return String(localized: "How is your recent strength work distributed?")
        case .fatigue: return String(localized: "How much estimated training stimulus may still remain?")
        case .strength: return String(localized: "Where do suitable exercises show a clear strength trend?")
        }
    }

    private var methodText: String {
        switch mode {
        case .balance:
            return String(localized: "The past 28 days are compared with your own previous eight complete weeks. This is distribution, not an ideal physique.")
        case .fatigue:
            return String(localized: "Fatigue is an estimate from working sets and exponential decay. It does not measure recovery or readiness.")
        case .strength:
            return String(localized: "Strength uses RIR-corrected estimated 1RM trends. Each exercise is normalized to its own history before muscle evidence is combined.")
        }
    }

    private var emptyText: String {
        switch mode {
        case .balance: return String(localized: "Complete or import working sets to see their distribution.")
        case .fatigue: return String(localized: "No mapped working sets are available for a fatigue estimate.")
        case .strength: return String(localized: "At least four suitable sessions per exercise are needed for a strength trend.")
        }
    }

    private var accessibilityLabel: String {
        switch mode {
        case .balance: return String(localized: "Muscle balance from recent working sets")
        case .fatigue: return String(localized: "Estimated remaining muscle stimulus")
        case .strength: return String(localized: "Muscle strength trends from suitable exercises")
        }
    }

    private var currentMuscleIds: [String] {
        switch mode {
        case .balance: return model.balance?.readings.map(\.muscleId) ?? []
        case .fatigue: return model.fatigue?.readings.map(\.muscleId) ?? []
        case .strength: return model.strength?.readings.map(\.muscleId) ?? []
        }
    }

    private var coverage: MuscleMetricCoverage? {
        switch mode {
        case .balance: return model.balance?.coverage
        case .fatigue: return model.fatigue?.coverage
        case .strength: return model.strength?.coverage
        }
    }

    private var coverageRow: some View {
        HStack(spacing: NoopMetrics.space3) {
            if let coverage {
                Label("\(coverage.mappedSetCount) of \(coverage.workingSetCount) sets mapped",
                      systemImage: "figure.strengthtraining.traditional")
                Label("\(coverage.ratedSetCount) rated", systemImage: "dial.medium")
            }
            if mode == .balance, model.balance?.hasPersonalBaseline == false {
                Text("Baseline growing")
            }
        }
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textSecondary)
    }

    @ViewBuilder private var readingList: some View {
        VStack(spacing: 0) {
            ForEach(Array(currentMuscleIds.prefix(12)), id: \.self) { id in
                Button { selection = .init(id: id) } label: {
                    HStack {
                        Text(muscleName(id))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Text(summary(id))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .padding(.vertical, NoopMetrics.space2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private var mapIntensities: [MuscleIntensity] {
        switch mode {
        case .balance:
            return TrainingMuscleMapAppearance.intensities(Dictionary(uniqueKeysWithValues:
                (model.balance?.readings ?? []).map { ($0.muscleId, $0.effectiveSets) }))
        case .fatigue:
            return TrainingMuscleMapAppearance.boundedIntensities(Dictionary(uniqueKeysWithValues:
                (model.fatigue?.readings ?? []).map { ($0.muscleId, $0.relativeToTypicalSession) }))
        case .strength:
            var merged: [Muscle: (slope: Double, magnitude: Double)] = [:]
            for reading in model.strength?.readings ?? [] {
                guard reading.direction != .unclear,
                      reading.direction != .insufficientEvidence,
                      let muscle = TrainingMuscleMapAppearance.muscle(reading.muscleId),
                      let slope = reading.normalizedSlopePerWeek else { continue }
                let magnitude = abs(slope)
                if magnitude >= (merged[muscle]?.magnitude ?? -1) {
                    merged[muscle] = (slope, magnitude)
                }
            }
            return merged.map { muscle, value in
                let slope = value.slope
                let color: Color = slope > 0 ? StrandPalette.recovery100
                    : slope < 0 ? StrandPalette.statusCritical : StrandPalette.metricCyan
                return MuscleIntensity(muscle: muscle,
                    intensity: min(1, max(0.25, abs(slope) / 0.05)), color: color)
            }
        }
    }

    private var colorScale: HeatmapColorScale {
        switch mode {
        case .balance: return TrainingMuscleMapAppearance.scale
        case .fatigue: return .init(colors: [StrandPalette.hairline, StrandPalette.statusWarning,
                                             StrandPalette.effortColor], interpolation: .easeInOut)
        case .strength: return TrainingMuscleMapAppearance.scale
        }
    }

    private func select(_ muscle: Muscle) {
        let candidates = TrainingMuscleMapAppearance.ids(for: muscle)
        let best = candidates.max { score($0) < score($1) }
        if let best, currentMuscleIds.contains(best) { selection = .init(id: best) }
    }

    private func score(_ id: String) -> Double {
        switch mode {
        case .balance: return balance(id)?.effectiveSets ?? 0
        case .fatigue: return fatigue(id)?.relativeToTypicalSession ?? 0
        case .strength: return abs(strength(id)?.normalizedSlopePerWeek ?? 0)
        }
    }

    private func summary(_ id: String) -> String {
        switch mode {
        case .balance:
            guard let reading = balance(id) else { return "—" }
            return String(format: String(localized: "%1$.0f%% of recent work"),
                          reading.distributionShare * 100)
        case .fatigue:
            guard let reading = fatigue(id) else { return "—" }
            return String(format: String(localized: "%1$.0f%% of a typical session"),
                          reading.relativeToTypicalSession * 100)
        case .strength:
            guard let reading = strength(id) else {
                return String(localized: "Not assessable")
            }
            if reading.direction == .unclear { return String(localized: "Direction unclear") }
            guard let value = reading.normalizedSlopePerWeek else {
                return String(localized: "Not assessable")
            }
            return String(format: String(localized: "%1$+.1f%% per week"), value * 100)
        }
    }

    private func balance(_ id: String) -> MuscleBalanceReading? {
        model.balance?.readings.first { $0.muscleId == id }
    }

    private func fatigue(_ id: String) -> MuscleFatigueReading? {
        model.fatigue?.readings.first { $0.muscleId == id }
    }

    private func strength(_ id: String) -> MuscleStrengthReading? {
        model.strength?.readings.first { $0.muscleId == id }
    }

    private var historyRevision: String {
        let newest = history.sessions.first?.id ?? "empty"
        let oldest = history.sessions.last?.id ?? "empty"
        return "\(history.sessions.count)|\(newest)|\(oldest)"
    }
}

private struct MuscleMetricDetailView: View {
    let muscleId: String
    let mode: MuscleAnalyticsSurface.Mode
    let balance: MuscleBalanceReading?
    let fatigue: MuscleFatigueReading?
    let strength: MuscleStrengthReading?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section("Interpretation") { Text(interpretation) }
            if mode == .balance, let balance {
                Section("Distribution") {
                    LabeledContent("Effective sets", value: balance.effectiveSets.formatted(.number.precision(.fractionLength(1))))
                    LabeledContent("Recent share", value: balance.distributionShare.formatted(.percent.precision(.fractionLength(0))))
                    if let usual = balance.usualShare {
                        LabeledContent("Usual share", value: usual.formatted(.percent.precision(.fractionLength(0))))
                    }
                }
                evidence(balance.evidence)
            }
            if mode == .fatigue, let fatigue {
                Section("Estimate") {
                    LabeledContent("Compared with a typical session",
                                   value: fatigue.relativeToTypicalSession.formatted(.percent.precision(.fractionLength(0))))
                    LabeledContent("Decay time", value: String(format: String(localized: "%1$.0f hours"), fatigue.tauSeconds / 3_600))
                    LabeledContent("Decay basis", value: fatigue.usesPersonalTau
                                   ? String(localized: "Personal feedback")
                                   : String(localized: "Documented default"))
                }
                evidence(fatigue.evidence)
            }
            if mode == .strength, let strength {
                Section("Exercise evidence") {
                    ForEach(strength.exerciseEvidence) { item in
                        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                            Text(item.exerciseTitle)
                            Text(exerciseTrend(item))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(muscleName(muscleId))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
    }

    private var interpretation: String {
        switch mode {
        case .balance:
            switch balance?.state {
            case .belowUsual: return String(localized: "This muscle received a smaller share than usual for you.")
            case .withinUsualVariation: return String(localized: "This muscle is within your usual distribution.")
            case .aboveUsual: return String(localized: "This muscle received a larger share than usual for you.")
            case .baselineGrowing, nil: return String(localized: "Your personal distribution baseline is still growing.")
            }
        case .fatigue:
            return String(localized: "This is estimated remaining training stimulus, not measured recovery.")
        case .strength:
            switch strength?.direction {
            case .increasing: return String(localized: "Suitable exercises show a clear upward strength trend.")
            case .decreasing: return String(localized: "Suitable exercises show a clear downward strength trend.")
            case .stable: return String(localized: "Suitable exercises show little clear change.")
            case .unclear: return String(localized: "The available exercise trends disagree on direction.")
            case .insufficientEvidence, nil: return String(localized: "At least four suitable sessions per exercise are needed.")
            }
        }
    }

    @ViewBuilder private func evidence(_ rows: [MuscleMetricEvidence]) -> some View {
        Section("Recent contributing sessions") {
            ForEach(Array(rows.prefix(10))) { row in
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text(row.exerciseTitle)
                    Text(row.sessionTitle)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private func exerciseTrend(_ item: MuscleStrengthExerciseEvidence) -> String {
        guard item.pointCount >= StrengthProgress.minimumTrendPoints else {
            return String(format: String(localized: "%lld of 4 sessions"), item.pointCount)
        }
        guard !item.directionIsUnclear, let value = item.normalizedSlopePerWeek else {
            return String(localized: "Direction unclear")
        }
        return String(format: String(localized: "%1$+.1f%% per week · %2$lld sessions"),
                      value * 100, item.pointCount)
    }
}

private func muscleName(_ id: String) -> String {
    TrainingDisplayNames.muscle(id)
}
