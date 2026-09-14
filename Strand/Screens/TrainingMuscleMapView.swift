import SwiftUI
import MuscleMap
import StrandDesign
import StrandTraining

/// Detailed primary-muscle map for native workouts. It deliberately does not split left and right:
/// the logger records exercise work, not side-specific anatomy evidence.
struct TrainingMuscleMapCard: View {
    let workouts: [NativeWorkout]
    let exercises: [TrainingExercise]
    @State private var days = 7
    @State private var side = BodySide.front
    @AppStorage("training.bodyFigure") private var figureRaw = BodyGender.male.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack {
                SectionHeader("Muscle map", overline: "Primary work sets")
                Spacer()
                Picker("Period", selection: $days) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("All").tag(0)
                }.labelsHidden().pickerStyle(.menu)
            }
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack(spacing: 8) {
                        Picker("Body side", selection: $side) {
                            Text("Front").tag(BodySide.front)
                            Text("Back").tag(BodySide.back)
                        }.pickerStyle(.segmented)
                        Menu {
                            Button("Male figure") { figureRaw = BodyGender.male.rawValue }
                            Button("Female figure") { figureRaw = BodyGender.female.rawValue }
                        } label: {
                            Image(systemName: "figure.stand").frame(width: 34, height: 30)
                        }.buttonStyle(.bordered)
                    }
                    MuscleMap.BodyView(gender: BodyGender(rawValue: figureRaw) ?? .male, side: side,
                             style: mapStyle)
                        .heatmap(intensities, colorScale: mapScale)
                        .showSubGroups()
                        .animated(duration: 0.25)
                        .frame(height: 270)
                        .accessibilityLabel(String(localized: "Muscle map from completed primary working sets"))
                    if counts.isEmpty {
                        Text("Complete working sets to build your map.")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    } else if !untrained.isEmpty {
                        Text("Not trained in this period: \(untrained.prefix(5).joined(separator: ", "))")
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    }
                    Text("Each completed working set counts once for the exercise's primary muscle. Secondary muscles and left/right differences are not estimated.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    Link("Body geometry: MuscleMap · MIT License",
                         destination: URL(string: "https://github.com/melihcolpan/MuscleMap")!)
                        .font(StrandFont.caption)
                }
            }
        }
    }

    private var counts: [String: Int] {
        let cutoff = days == 0 ? Int.min : Int(Date().timeIntervalSince1970) - days * 86_400
        let definitions = Dictionary(uniqueKeysWithValues: exercises.map { ($0.id, $0) })
        var result: [String: Int] = [:]
        for workout in workouts where workout.startedAt >= cutoff {
            for exercise in workout.exercises {
                guard let muscle = definitions[exercise.exerciseId]?.primaryMuscleId else { continue }
                result[muscle, default: 0] += exercise.sets.filter {
                    $0.isCompleted && $0.phase == .work
                }.count
            }
        }
        return result
    }

    private var intensities: [MuscleIntensity] {
        let maximum = max(1, counts.values.max() ?? 1)
        return counts.compactMap { key, value in
            mapMuscle(key).map { MuscleIntensity(muscle: $0, intensity: Double(value) / Double(maximum)) }
        }
    }

    private var untrained: [String] {
        let present = Set(counts.keys)
        return TrainingMuscleCatalog.all
            .filter { $0.parentId != nil && !present.contains($0.id) }
            .map(\.name).sorted()
    }

    private var mapScale: HeatmapColorScale {
        HeatmapColorScale(colors: [StrandPalette.hairline, StrandPalette.metricCyan,
                                   StrandPalette.accent, StrandPalette.effortColor],
                          interpolation: .easeInOut)
    }

    private var mapStyle: BodyViewStyle {
        BodyViewStyle(defaultFillColor: StrandPalette.hairline.opacity(0.65),
                      strokeColor: StrandPalette.textTertiary.opacity(0.22), strokeWidth: 0.5,
                      selectionColor: StrandPalette.accent,
                      selectionStrokeColor: StrandPalette.accent, selectionStrokeWidth: 1.5,
                      headColor: StrandPalette.hairline.opacity(0.75),
                      hairColor: StrandPalette.textTertiary.opacity(0.45))
    }

    private func mapMuscle(_ id: String) -> Muscle? {
        switch id {
        case "chest": return .chest
        case "upper_chest": return .upperChest
        case "lower_chest": return .lowerChest
        case "front_delts": return .frontDeltoid
        case "side_delts": return .deltoids
        case "rear_delts": return .rearDeltoid
        case "triceps": return .triceps
        case "biceps": return .biceps
        case "forearms": return .forearm
        case "lats", "upper_back": return .upperBack
        case "traps": return .trapezius
        case "lower_back": return .lowerBack
        case "abdominals": return .abs
        case "obliques": return .obliques
        case "quadriceps": return .quadriceps
        case "hamstrings": return .hamstring
        case "glutes": return .gluteal
        case "adductors": return .adductors
        case "calves": return .calves
        case "tibialis": return .tibialis
        case "neck": return .neck
        default: return nil
        }
    }
}

struct TrainingActivityHeatmap: View {
    let workouts: [NativeWorkout]
    private let columns = Array(repeating: GridItem(.fixed(7), spacing: NoopMetrics.space1), count: 7)

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Consistency", overline: "Past year")
            NoopCard {
                VStack(alignment: .leading, spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(rows: columns, spacing: NoopMetrics.space1) {
                            ForEach(days, id: \.day) { value in
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(color(minutes: value.minutes))
                                    .frame(width: 7, height: 7)
                                    .accessibilityLabel("\(value.day), \(Int(value.minutes.rounded())) minutes")
                            }
                        }.frame(height: 67)
                    }
                    Text("Darker squares mean more time logged. Empty days are rest or no workout.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private var days: [(day: String, minutes: Double)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        var byDay: [String: Double] = [:]
        for workout in workouts {
            let date = Date(timeIntervalSince1970: TimeInterval(workout.startedAt))
            let day = Self.dayFormatter.string(from: date)
            byDay[day, default: 0] += Double(max(0, workout.endedAt - workout.startedAt)) / 60
        }
        return (0..<364).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let day = Self.dayFormatter.string(from: date)
            return (day, byDay[day] ?? 0)
        }
    }

    private func color(minutes: Double) -> Color {
        guard minutes > 0 else { return StrandPalette.hairline.opacity(0.55) }
        let fraction = min(1, max(0.18, minutes / 90))
        return StrandPalette.accent.opacity(0.25 + fraction * 0.75)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
