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
                        stats
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

    private var stats: some View {
        let extremes = series.flatMap { GradeAdjustedPace.extremes($0.grades) }
        let gait = WorkoutElevationSeries.gait(forSport: sport)
        let flatPace = gait.flatMap { series?.wholeGradeAdjustedPace(gait: $0) }
        return HStack(alignment: .top, spacing: 0) {
            stat(String(localized: "Climbed"), ascent.map { UnitFormatter.elevationFromMeters($0, system: system) })
            stat(String(localized: "Descended"), descent.map { UnitFormatter.elevationFromMeters($0, system: system) })
            stat(String(localized: "Steepest"), extremes.map { UnitFormatter.gradePercent($0.maxUp) },
                 tint: extremes.map { ElevationProfileGraph.color(forGrade: $0.maxUp) })
            if gait != nil {
                stat(String(localized: "On the flat"), flatPace.map { UnitFormatter.paceFromSecPerKm($0, system: system) })
            }
        }
    }

    private func stat(_ title: String, _ value: String?, tint: Color? = nil) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(value ?? "–")
                .font(StrandFont.number(17))
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : (tint ?? StrandPalette.textPrimary))
                .lineLimit(1)
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// One short line on where the climb came from, and what "on the flat" means when it is shown.
    private var sourceNote: String? {
        let origin: String? = switch elevation?.source {
        case WorkoutElevationSource.barometer: String(localized: "Counted from your iPhone's barometer.")
        case WorkoutElevationSource.appleHealth: String(localized: "Climb from Apple Health.")
        case WorkoutElevationSource.file: String(localized: "Climb from the imported file.")
        default: nil
        }
        guard WorkoutElevationSeries.gait(forSport: sport) != nil, series != nil else { return origin }
        let flat = String(localized: "On the flat: the pace this effort equals on level ground (Minetti 2002).")
        return [origin, flat].compactMap { $0 }.joined(separator: " ")
    }
}
