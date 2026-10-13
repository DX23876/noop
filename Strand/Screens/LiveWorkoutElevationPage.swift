import SwiftUI
import StrandDesign

/// The live elevation page, like the Workout app's: height climbed and descended, the current height and
/// grade, and the profile so far. Shown only for a GPS workout; without a barometer it says so instead of
/// guessing from GPS.
struct LiveWorkoutElevationPage: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(UnitPrefs.systemKey) private var units = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceUnits = ""

    private var system: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: units) ?? .metric, override: distanceUnits)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if WorkoutAltimeter.isAvailable {
                    TimelineView(.periodic(from: .now, by: 5)) { _ in content }
                } else {
                    Text("This device has no barometer, so NOOP shows no elevation rather than guessing it from GPS.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, NoopMetrics.space4)
                }
            }
            .screenPadding().padding(.vertical, NoopMetrics.space2)
        }
    }

    @ViewBuilder private var content: some View {
        let recording = model.workoutRecording
        let altimeter = model.workoutAltimeter
        let series = WorkoutElevationSeries.make(points: model.gpsRecorder.measuredPoints)
        row(recording.ascentM, caption: String(localized: "Elevation gain"), symbol: "arrow.up.right")
        row(recording.descentM, caption: String(localized: "Elevation loss"), symbol: "arrow.down.right")
        row(altimeter.altitudeM, caption: String(localized: "Current elevation"), symbol: "mountain.2")
        let grade = series?.currentGrade
        let gradeParts = LiveWorkoutMetricRow.split(grade.map(UnitFormatter.gradePercent) ?? "— %")
        LiveWorkoutMetricRow(value: gradeParts.value, unit: gradeParts.unit,
                             caption: String(localized: "Grade · last 50 m"), symbol: "angle",
                             tint: grade.map(ElevationProfileGraph.color(forGrade:)) ?? StrandPalette.textTertiary)
        if let series, series.totalDistanceM >= 50 {
            ElevationProfileGraph(samples: series.drawable(maxPoints: 160), system: system,
                                  isAbsolute: series.isAbsolute, height: 120, allowsScrub: false)
                .padding(.top, NoopMetrics.space4)
        }
    }

    private func row(_ meters: Double?, caption: String, symbol: String) -> some View {
        let parts = LiveWorkoutMetricRow.split(meters.map { UnitFormatter.elevationFromMeters($0, system: system) }
            ?? (system == .imperial ? "— ft" : "— m"))
        return LiveWorkoutMetricRow(value: parts.value, unit: parts.unit, caption: caption, symbol: symbol,
                                    tint: meters == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
    }
}
