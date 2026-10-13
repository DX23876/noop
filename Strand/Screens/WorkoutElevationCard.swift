import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

/// The elevation of a finished workout: the profile over distance, how far it climbed and descended, the
/// steepest grade and, for a walk or run, the pace it equals on the flat (Minetti 2002). Shown when the
/// workout has a measured climb or a route with heights; otherwise not at all.
struct WorkoutElevationCard: View {
    let series: WorkoutElevationSeries?
    let elevation: WorkoutElevationRow?
    let sport: String
    let system: UnitSystem
    /// Read once here rather than on every render: the steepest climb and the whole route's flat pace walk
    /// every point of the route.
    private let gait: ExerciseVO2max.Gait?
    private let steepest: Double?
    private let flatPace: Double?

    init(series: WorkoutElevationSeries?, elevation: WorkoutElevationRow?, sport: String, system: UnitSystem) {
        self.series = series
        self.elevation = elevation
        self.sport = sport
        self.system = system
        let gait = WorkoutElevationSeries.gait(forSport: sport)
        self.gait = gait
        steepest = series.flatMap { GradeAdjustedPace.extremes($0.grades)?.maxUp }
        flatPace = gait.flatMap { series?.wholeGradeAdjustedPace(gait: $0) }
    }

    private var ascent: Double? { elevation?.ascentM }
    private var descent: Double? { elevation?.descentM }

    var body: some View {
        if series != nil || ascent != nil {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Elevation",
                              trailing: ascent.map { "↑ " + UnitFormatter.elevationFromMeters($0, system: system) })
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                        if let series {
                            ElevationProfileGraph(samples: series.drawable(), system: system,
                                                  isAbsolute: series.isAbsolute)
                        }
                        HStack(alignment: .top, spacing: 0) {
                            WorkoutElevationStat(title: String(localized: "Climbed"), value: format(ascent))
                            WorkoutElevationStat(title: String(localized: "Descended"), value: format(descent))
                            WorkoutElevationStat(title: String(localized: "Steepest"),
                                                 value: steepest.map(UnitFormatter.gradePercent),
                                                 tint: steepest.map(ElevationGradeStyle.color(forGrade:)))
                            if gait != nil {
                                WorkoutElevationStat(title: String(localized: "On the flat"),
                                                     value: flatPace.map { UnitFormatter.paceFromSecPerKm($0, system: system) })
                            }
                        }
                    }
                }
                if let note = sourceNote {
                    Text(note)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func format(_ meters: Double?) -> String? {
        meters.map { UnitFormatter.elevationFromMeters($0, system: system) }
    }

    /// One short line on where the climb came from, and what "on the flat" means when it is shown.
    private var sourceNote: String? {
        let origin: String? = switch elevation?.source {
        case WorkoutElevationSource.barometer: String(localized: "Counted from your iPhone's barometer.")
        case WorkoutElevationSource.appleHealth: String(localized: "Climb from Apple Health.")
        case WorkoutElevationSource.file: String(localized: "Climb from the imported file.")
        default: nil
        }
        guard gait != nil, series != nil else { return origin }
        let flat = String(localized: "On the flat: the pace this effort equals on level ground (Minetti 2002).")
        return [origin, flat].compactMap { $0 }.joined(separator: " ")
    }
}
