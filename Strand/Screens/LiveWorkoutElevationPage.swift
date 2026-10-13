import SwiftUI
import StrandDesign

/// The live elevation page, like the Workout app's: height climbed and descended, the current height and
/// grade, and the profile so far. Shown only for a GPS workout; without a barometer it says so instead of
/// guessing from GPS.
struct LiveWorkoutElevationPage: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(UnitPrefs.systemKey) private var units = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceUnits = ""
    /// The route's heights so far, rebuilt every few seconds off the view's body.
    @State private var series: WorkoutElevationSeries?
    @State private var reading = LiveElevationReading()

    /// How often the page re-reads the barometer and rebuilds the profile.
    static let refreshSeconds = 5

    private var system: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: units) ?? .metric, override: distanceUnits)
    }

    var body: some View {
        if WorkoutAltimeter.isAvailable {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let gain = parts(reading.ascentM)
                    LiveWorkoutMetricRow(value: gain.value, unit: gain.unit,
                                         caption: String(localized: "Elevation gain"), symbol: "arrow.up.right",
                                         tint: tint(reading.ascentM))
                    let loss = parts(reading.descentM)
                    LiveWorkoutMetricRow(value: loss.value, unit: loss.unit,
                                         caption: String(localized: "Elevation loss"), symbol: "arrow.down.right",
                                         tint: tint(reading.descentM))
                    let current = parts(reading.altitudeM)
                    LiveWorkoutMetricRow(value: current.value, unit: current.unit,
                                         caption: String(localized: "Current elevation"), symbol: "mountain.2",
                                         tint: tint(reading.altitudeM))
                    let grade = LiveWorkoutMetricRow.split(series?.currentGrade.map(UnitFormatter.gradePercent) ?? "— %")
                    LiveWorkoutMetricRow(value: grade.value, unit: grade.unit,
                                         caption: String(localized: "Grade · last 50 m"), symbol: "angle",
                                         tint: series?.currentGrade.map(ElevationGradeStyle.color(forGrade:))
                                             ?? StrandPalette.textTertiary)
                    if let series, series.totalDistanceM >= 50 {
                        ElevationProfileGraph(samples: series.drawable(maxPoints: 160), system: system,
                                              isAbsolute: series.isAbsolute, height: 120, allowsScrub: false)
                            .padding(.top, NoopMetrics.space4)
                    }
                }
                .screenPadding().padding(.vertical, NoopMetrics.space2)
            }
            .task { await refreshWhileVisible() }
        } else {
            LiveElevationUnavailableView()
        }
    }

    /// Re-reads the totals and rebuilds the series every `refreshSeconds` while the page is on screen.
    private func refreshWhileVisible() async {
        while !Task.isCancelled {
            reading = LiveElevationReading(ascentM: model.workoutRecording.ascentM,
                                           descentM: model.workoutRecording.descentM,
                                           altitudeM: model.workoutAltimeter.altitudeM)
            series = WorkoutElevationSeries.make(points: model.gpsRecorder.measuredPoints)
            try? await Task.sleep(for: .seconds(Self.refreshSeconds))
        }
    }

    private func parts(_ meters: Double?) -> (value: String, unit: String) {
        LiveWorkoutMetricRow.split(meters.map { UnitFormatter.elevationFromMeters($0, system: system) }
            ?? (system == .imperial ? "— ft" : "— m"))
    }

    private func tint(_ meters: Double?) -> Color {
        meters == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary
    }
}
