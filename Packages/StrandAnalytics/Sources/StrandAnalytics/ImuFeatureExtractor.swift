import Foundation
import WhoopProtocol

// ImuFeatureExtractor.swift — activity features from decoded WHOOP 5/MG raw 6-axis IMU (#423).
//
// The 5/MG offload buffer decodes (WhoopProtocol.Whoop5RawImu) to 100 Hz 3-axis accel (g) + 3-axis gyro
// (°/s). At 100 Hz the accelerometer resolves gait cadence, impact/jerk, and rotational energy that the
// 1 Hz gravity vector physically cannot (a 1.8 Hz step rate is above the 1 Hz stream's Nyquist limit).
// This turns a window of raw samples into a compact activity-feature vector for coarse sport / HAR
// classification — the real-IMU upgrade path the coarse `WorkoutTypeClassifier` (1 Hz proxy) was built
// to accept behind `WorkoutTypeClassifying`.
//
// Per the repo's derived-signal rule: cadence here is a `autocorrelation` peak on the accel-magnitude AC
// over a genuinely high-rate stream (not a fixed-N-per-record buffer), reported with its own strength so
// a caller can ignore a weak/absent peak; it is a FEATURE, never fed to a physiological gate. Validated
// to recover MULTIPLE injected cadences, not one lucky match (see ImuFeatureExtractorTests).

/// Compact activity features over a window of raw IMU samples.
public struct ImuActivityFeatures: Equatable, Sendable, Codable {
    /// RMS of the accel-magnitude AC (gravity removed), in g — overall movement intensity.
    public let accelEnergyG: Double
    /// Mean gyroscope magnitude over the window, in °/s — rotational intensity.
    public let gyroEnergyDps: Double
    /// RMS of the accel first-difference (jerk), in g/sample — impact / explosiveness (jumps, foot-strike).
    public let jerkRms: Double
    /// Dominant cadence in the gait band (`cadenceBand`), Hz — nil when no rhythmic peak clears
    /// `minCadenceStrength`. Multiply by 60 for steps/min.
    public let cadenceHz: Double?
    /// Normalized strength (0…1) of that cadence peak — high = rhythmic (walk/run/cycle), low = bursty
    /// (strength) or still.
    public let cadenceStrength: Double
    public let sampleCount: Int

    public init(accelEnergyG: Double, gyroEnergyDps: Double, jerkRms: Double,
                cadenceHz: Double?, cadenceStrength: Double, sampleCount: Int) {
        self.accelEnergyG = accelEnergyG; self.gyroEnergyDps = gyroEnergyDps; self.jerkRms = jerkRms
        self.cadenceHz = cadenceHz; self.cadenceStrength = cadenceStrength; self.sampleCount = sampleCount
    }
}

public enum ImuFeatureExtractor {

    /// Cadence search band, Hz — human gait/pedal foot rate (≈72–210 steps/min). Below the IMU Nyquist.
    public static let cadenceBand: ClosedRange<Double> = 1.2...3.5
    /// A cadence peak below this normalized autocorrelation strength is treated as "no rhythm" (→ nil Hz).
    public static let minCadenceStrength = 0.20

    /// Extract features from `samples` (from one or more `Whoop5ImuFrame`s, in order) at `sampleRateHz`.
    public static func extract(_ samples: [RawImuSample], sampleRateHz: Int) -> ImuActivityFeatures {
        let n = samples.count
        guard n >= 8, sampleRateHz > 0 else {
            return ImuActivityFeatures(accelEnergyG: 0, gyroEnergyDps: 0, jerkRms: 0,
                                       cadenceHz: nil, cadenceStrength: 0, sampleCount: n)
        }
        let amag = samples.map { ($0.ax * $0.ax + $0.ay * $0.ay + $0.az * $0.az).squareRoot() }
        let gmag = samples.map { ($0.gx * $0.gx + $0.gy * $0.gy + $0.gz * $0.gz).squareRoot() }

        let gyroEnergy = gmag.reduce(0, +) / Double(n)
        // Accel AC: remove the DC (≈gravity) then RMS.
        let mean = amag.reduce(0, +) / Double(n)
        let ac = amag.map { $0 - mean }
        let accelEnergy = (ac.reduce(0) { $0 + $1 * $1 } / Double(n)).squareRoot()
        // Jerk: RMS of |accel| first difference.
        var jerkSq = 0.0
        for i in 1..<n { let d = amag[i] - amag[i - 1]; jerkSq += d * d }
        let jerk = (jerkSq / Double(n - 1)).squareRoot()

        // Cadence: normalized autocorrelation of the AC series over the gait-band lags; the strongest
        // peak's frequency + strength. Strength = peak ACF / zero-lag ACF (0…1), so it's amplitude-scale
        // free (a faint but rhythmic walk and a hard one both read as rhythmic).
        let ac0 = ac.reduce(0) { $0 + $1 * $1 }
        var bestFreq: Double? = nil, bestStrength = 0.0
        if ac0 > 0 {
            let loLag = max(1, Int((Double(sampleRateHz) / cadenceBand.upperBound).rounded()))
            let hiLag = min(n - 1, Int((Double(sampleRateHz) / cadenceBand.lowerBound).rounded()))
            if loLag < hiLag {
                for lag in loLag...hiLag {
                    var s = 0.0
                    for i in 0..<(n - lag) { s += ac[i] * ac[i + lag] }
                    let strength = s / ac0
                    if strength > bestStrength { bestStrength = strength; bestFreq = Double(sampleRateHz) / Double(lag) }
                }
            }
        }
        let cadence = bestStrength >= minCadenceStrength ? bestFreq : nil
        return ImuActivityFeatures(accelEnergyG: accelEnergy, gyroEnergyDps: gyroEnergy, jerkRms: jerk,
                                   cadenceHz: cadence, cadenceStrength: max(0, bestStrength), sampleCount: n)
    }

    /// Convenience: extract over the concatenated samples of decoded IMU frames.
    public static func extract(frames: [Whoop5ImuFrame]) -> ImuActivityFeatures {
        let rate = frames.first?.sampleRateHz ?? 100
        return extract(frames.flatMap { $0.samples }, sampleRateHz: rate)
    }
}
