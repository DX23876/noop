import Foundation

// MARK: - Elevation gain and loss from a barometer, as OpenTracks counts them
//
// A faithful port of OpenTracks (Apache License 2.0, https://github.com/OpenTracksApp/OpenTracks):
// `sensors/PressureSensorUtils.java` and `sensors/sensorData/AggregatorBarometer.java`. The numbers, the
// order of operations and the test vectors are theirs; only the language changed.
//
//   1. Each new pressure reading is smoothed against the previous RAW reading:
//        next = 0.3 · current + 0.7 · previous
//   2. Pressure becomes altitude through the standard atmosphere (Android `SensorManager.getAltitude`
//      with p0 = 1013.25 hPa):  h = 44330 · (1 − (p / p0)^(1 / 5.255))
//   3. A change smaller than 3 m from the last ACCEPTED reading is noise and is ignored. A larger one
//      counts exactly 3 m, up or down, and the accepted reading moves by those 3 m — not to the new
//      reading — so a fast climb is counted in 3 m steps over the following readings.
//
// Why a barometer and not GPS altitude: GPS altitude wanders by 10–20 m, and summing those wanderings
// turns a flat walk into a hilly one. Pressure resolves height changes of decimetres; its weakness, a slow
// drift as the weather changes, is far below 3 m over a workout.
//
// NOOP's one addition, outside the port: `restartBaseline()`. A paused workout does not count height, so
// after a pause the next reading becomes the new baseline (a lift ride during a pause is not a climb).

public struct BarometricElevationCounter: Codable, Equatable, Sendable {

    /// OpenTracks `ALTITUDE_CHANGE_DIFF_M`: everything above is a meaningful change in altitude.
    public static let altitudeChangeThresholdM = 3.0
    /// OpenTracks `EXPONENTIAL_SMOOTHING`: the weight of the new reading.
    public static let exponentialSmoothing = 0.3
    /// Android `SensorManager.PRESSURE_STANDARD_ATMOSPHERE`, hPa.
    public static let standardPressureHPa = 1013.25

    public private(set) var gainM = 0.0
    public private(set) var lossM = 0.0
    /// OpenTracks `lastAcceptedSensorValue`, hPa.
    private var lastAcceptedHPa: Double?
    /// OpenTracks `Aggregator.previous`: the last raw reading seen, hPa.
    private var previousHPa: Double?

    public init() {}

    /// One pressure reading in hPa. Returns the gain and loss this reading added (each 0 or 3 m).
    @discardableResult
    public mutating func add(pressureHPa current: Double) -> (gainM: Double, lossM: Double) {
        guard current.isFinite, current > 0 else { return (0, 0) }
        defer { previousHPa = current }
        guard let previous = previousHPa, let lastAccepted = lastAcceptedHPa else {
            lastAcceptedHPa = current
            return (0, 0)
        }
        let smoothed = Self.exponentialSmoothing * current + (1 - Self.exponentialSmoothing) * previous
        guard let change = Self.computeChange(lastAcceptedHPa: lastAccepted, currentHPa: smoothed) else {
            return (0, 0)
        }
        lastAcceptedHPa = change.acceptedHPa
        let gain = max(change.altitudeChangeM, 0)
        let loss = max(-change.altitudeChangeM, 0)
        gainM += gain
        lossM += loss
        return (gain, loss)
    }

    /// The next reading becomes the baseline; totals are kept. Called when a paused workout resumes.
    public mutating func restartBaseline() {
        lastAcceptedHPa = nil
        previousHPa = nil
    }

    // MARK: - PressureSensorUtils

    /// OpenTracks `computeChanges`: nil below the threshold, otherwise exactly ±3 m and the pressure that
    /// height corresponds to.
    public static func computeChange(lastAcceptedHPa: Double,
                                     currentHPa: Double) -> (altitudeChangeM: Double, acceptedHPa: Double)? {
        let last = altitudeM(pressureHPa: lastAcceptedHPa)
        let current = altitudeM(pressureHPa: currentHPa)
        let change = current - last
        guard abs(change) >= altitudeChangeThresholdM else { return nil }
        let step = change > 0 ? altitudeChangeThresholdM : -altitudeChangeThresholdM
        return (step, pressureHPa(altitudeM: last + step))
    }

    /// Android `SensorManager.getAltitude(p0, p)`.
    public static func altitudeM(pressureHPa p: Double) -> Double {
        44330.0 * (1.0 - pow(p / standardPressureHPa, 1.0 / 5.255))
    }

    /// OpenTracks `getBarometricPressure`.
    public static func pressureHPa(altitudeM h: Double) -> Double {
        standardPressureHPa * pow(1.0 - 0.0065 * h / 288.15, 5.255)
    }
}
