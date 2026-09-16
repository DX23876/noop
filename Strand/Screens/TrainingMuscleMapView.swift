import SwiftUI
import MuscleMap
import StrandDesign
import StrandTraining

enum TrainingMuscleMapAppearance {
    static let scale = HeatmapColorScale(
        colors: [StrandPalette.hairline, StrandPalette.metricCyan,
                 StrandPalette.accent, StrandPalette.effortColor],
        interpolation: .easeInOut)

    static let style = BodyViewStyle(
        defaultFillColor: StrandPalette.hairline.opacity(0.65),
        strokeColor: StrandPalette.textTertiary.opacity(0.22), strokeWidth: 0.5,
        selectionColor: StrandPalette.accent,
        selectionStrokeColor: StrandPalette.accent, selectionStrokeWidth: 1.5,
        headColor: StrandPalette.hairline.opacity(0.75),
        hairColor: StrandPalette.textTertiary.opacity(0.45))

    static func muscle(_ id: String) -> Muscle? {
        switch id {
        case "chest": return .chest
        case "upper_chest": return .upperChest
        case "lower_chest": return .lowerChest
        case "serratus": return .serratus
        case "front_delts": return .frontDeltoid
        case "side_delts": return .deltoids
        case "rear_delts": return .rearDeltoid
        case "rotator_cuff": return .rotatorCuff
        case "triceps": return .triceps
        case "biceps": return .biceps
        case "forearms": return .forearm
        case "lats", "upper_back": return .upperBack
        case "rhomboids": return .rhomboids
        case "traps": return .trapezius
        case "upper_traps": return .upperTrapezius
        case "lower_traps": return .lowerTrapezius
        case "lower_back": return .lowerBack
        case "abdominals": return .abs
        case "upper_abs": return .upperAbs
        case "lower_abs": return .lowerAbs
        case "obliques": return .obliques
        case "quadriceps": return .quadriceps
        case "inner_quadriceps": return .innerQuad
        case "outer_quadriceps": return .outerQuad
        case "hamstrings": return .hamstring
        case "glutes", "abductors": return .gluteal
        case "hip_flexors": return .hipFlexors
        case "adductors": return .adductors
        case "calves": return .calves
        case "tibialis": return .tibialis
        case "neck": return .neck
        default: return nil
        }
    }

    static func intensities(_ values: [String: Double]) -> [MuscleIntensity] {
        let maximum = max(0.01, values.values.max() ?? 0.01)
        var merged: [Muscle: Double] = [:]
        for (key, value) in values {
            guard let muscle = muscle(key) else { continue }
            merged[muscle] = max(merged[muscle] ?? 0, value / maximum)
        }
        return merged.map { MuscleIntensity(muscle: $0.key, intensity: $0.value) }
    }

    static func boundedIntensities(_ values: [String: Double]) -> [MuscleIntensity] {
        var merged: [Muscle: Double] = [:]
        for (key, value) in values {
            guard let muscle = muscle(key) else { continue }
            merged[muscle] = max(merged[muscle] ?? 0, min(1, max(0, value)))
        }
        return merged.map { MuscleIntensity(muscle: $0.key, intensity: $0.value) }
    }

    static func ids(for renderedMuscle: Muscle) -> [String] {
        TrainingMuscleCatalog.all.compactMap { muscle($0.id) == renderedMuscle ? $0.id : nil }
    }
}

struct TrainingMiniMusclePreview: View {
    let values: [String: Double]

    var body: some View {
        HStack(spacing: 2) {
            body(.front)
            body(.back)
        }
        .frame(width: 72, height: 82)
        .accessibilityLabel(String(localized: "Planned muscle involvement"))
    }

    private func body(_ side: BodySide) -> some View {
        MuscleMap.BodyView(gender: .male, side: side, style: TrainingMuscleMapAppearance.style)
            .heatmap(TrainingMuscleMapAppearance.intensities(values),
                     colorScale: TrainingMuscleMapAppearance.scale)
            .showSubGroups()
    }
}

/// The shared detailed muscle map for every strength source. It deliberately does not split left and
/// right: the logs describe an exercise, not side-specific anatomy evidence.
struct TrainingMuscleMapCard: View {
    let history: ResolvedStrengthHistory
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Muscle analytics", overline: "All strength sources")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    MuscleAnalyticsSurface(history: history, compact: true)
                    NoopButton("Explore muscles", systemImage: "figure.strengthtraining.traditional",
                               kind: .secondary) {
                        showingDetails = true
                    }
                    Link("Body geometry: MuscleMap · MIT License",
                         destination: URL(string: "https://github.com/melihcolpan/MuscleMap")!)
                        .font(StrandFont.caption)
                }
            }
        }
        .sheet(isPresented: $showingDetails) {
            NavigationStack { MuscleAnalyticsView(history: history) }
        }
    }
}

/// One day of the Consistency heatmap. Computed once per history load (`TrainingActivityDay.pastYear`),
/// because the heatmap body is re-evaluated whenever its parent redraws and a year of date formatting per
/// redraw is measurable while a workout is being logged.
struct TrainingActivityDay: Hashable, Sendable {
    let day: String
    let minutes: Double

    static func pastYear(sessions: [ResolvedStrengthSession], weekStart: TrainingWeekStart,
                         now: Date = Date()) -> [TrainingActivityDay] {
        var calendar = Calendar.current
        calendar.firstWeekday = weekStart == .sunday ? 1 : 2
        let today = calendar.startOfDay(for: now)
        let earliest = calendar.date(byAdding: .day, value: -363, to: today) ?? today
        let start = calendar.dateInterval(of: .weekOfYear, for: earliest)?.start ?? earliest
        let count = (calendar.dateComponents([.day], from: start, to: today).day ?? 363) + 1
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        var byDay: [String: Double] = [:]
        for session in sessions {
            let day = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(session.startTs)))
            byDay[day, default: 0] += Double(max(0, session.endTs - session.startTs)) / 60
        }
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let day = formatter.string(from: date)
            return TrainingActivityDay(day: day, minutes: byDay[day] ?? 0)
        }
    }
}

struct TrainingActivityHeatmap: View {
    let days: [TrainingActivityDay]
    private let rows = Array(repeating: GridItem(.fixed(7), spacing: NoopMetrics.space1), count: 7)

    var body: some View {
        let values = days
        let activeDays = values.filter { $0.minutes > 0 }.count
        let totalMinutes = values.reduce(0) { $0 + $1.minutes }
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Consistency", overline: "Past year")
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    // Each column is one calendar week starting on the chosen training week start, so a
                    // row always holds the same weekday.
                    // Opens on the current week: the most recent training is what a glance is for, and a
                    // year that starts at its oldest edge looked empty whenever history was shorter.
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHGrid(rows: rows, spacing: NoopMetrics.space1) {
                                ForEach(values, id: \.day) { value in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(color(minutes: value.minutes))
                                        .frame(width: 7, height: 7)
                                        .id(value.day)
                                }
                            }.frame(height: 67)
                        }
                        .onAppear { if let last = values.last { proxy.scrollTo(last.day, anchor: .trailing) } }
                        .onChange(of: values.count) { _ in
                            if let last = values.last { proxy.scrollTo(last.day, anchor: .trailing) }
                        }
                    }
                    // 370 unlabeled squares are not navigable with VoiceOver; one summary carries the facts.
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Training days in the past year: \(activeDays). Time logged: \(durationText(totalMinutes))."))
                    Text("Darker squares mean more time logged. Empty days are rest or no workout.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private func durationText(_ minutes: Double) -> String {
        Duration.seconds(Int((minutes * 60).rounded()))
            .formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    private func color(minutes: Double) -> Color {
        guard minutes > 0 else { return StrandPalette.hairline.opacity(0.55) }
        let fraction = min(1, max(0.18, minutes / 90))
        return StrandPalette.accent.opacity(0.25 + fraction * 0.75)
    }

}
