import SwiftUI
import StrandDesign

/// Isolates high-frequency footpod, cadence and power updates from the rest of the live workout screen:
/// only these rows observe `LiveState`, so a sensor packet re-renders them and nothing else.
struct LiveWorkoutSensorCard: View {
    @EnvironmentObject private var live: LiveState
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""

    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                  override: distanceSystemRaw)
    }

    var body: some View {
        if live.hasSensorMetrics {
            if let speed = UnitFormatter.speedFromKilometersPerHour(live.sensorSpeedKmh,
                                                                    system: distanceUnitSystem) {
                let parts = LiveWorkoutMetricRow.split(speed)
                LiveWorkoutMetricRow(value: parts.value, unit: parts.unit, symbol: "gauge.with.needle")
            }
            if let cadence = LiveState.formatCadence(live.sensorCadence) {
                LiveWorkoutMetricRow(value: "\(cadence)", unit: "/min", symbol: "metronome")
            }
            if let power = LiveState.formatPowerWatts(live.sensorPowerWatts) {
                LiveWorkoutMetricRow(value: "\(power)", unit: "W", symbol: "bolt.fill")
            }
        }
    }
}
