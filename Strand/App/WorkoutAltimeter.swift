import Foundation
import StrandAnalytics
#if os(iOS)
import CoreMotion
#endif

/// The iPhone barometer during a GPS workout: counts elevation gain and loss with OpenTracks' method
/// (`BarometricElevationCounter`) and keeps the latest height for each route point.
///
/// Two CoreMotion streams, both on-device:
///   • relative altitude, which carries the raw pressure the counter needs and a smooth height change
///     since the stream started (the shape of the profile and the grade);
///   • absolute altitude (iOS 15+), Apple's fusion of barometer and GPS, for the height above sea level.
///
/// Without a barometer (every Mac, an unauthorised Motion & Fitness permission) nothing is reported, and
/// the workout shows no elevation rather than a guessed one. A paused workout keeps the streams running
/// but counts nothing; on resume the counter starts from a new baseline.
///
/// Not observable: the workout's recording timeline holds the totals the screens show, and the live page
/// reads the heights on its own refresh.
@MainActor
final class WorkoutAltimeter {

    /// Gain and loss counted since the last call to `start`/`restore`, in metres; nil until the first reading.
    private(set) var gainM: Double?
    private(set) var lossM: Double?
    /// Height above sea level, metres, from Apple's barometer and GPS fusion. nil until it settles.
    private(set) var altitudeM: Double?
    /// Apple's stated accuracy of `altitudeM`, metres.
    private(set) var altitudeAccuracyM: Double?
    /// Barometric height relative to where this stream started, metres.
    private(set) var relativeAltitudeM: Double?
    /// Fires with the gain and loss one reading added, while the workout is not paused.
    var onElevation: ((Double, Double) -> Void)?

    private var counter = BarometricElevationCounter()
    private var paused = false
    private var running = false
    #if os(iOS)
    private var altimeter: CMAltimeter?
    #endif

    /// Whether this device can count elevation at all.
    static var isAvailable: Bool {
        #if os(iOS)
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return false }
        switch CMAltimeter.authorizationStatus() {
        case .denied, .restricted: return false
        default: return true
        }
        #else
        return false
        #endif
    }

    func start() {
        stop()
        counter = BarometricElevationCounter()
        gainM = nil
        lossM = nil
        altitudeM = nil
        altitudeAccuracyM = nil
        relativeAltitudeM = nil
        paused = false
        beginUpdates()
    }

    /// Re-arm after an in-flight workout was restored from disk. The totals live in the workout's
    /// recording timeline; only new readings are counted from here.
    func restore(paused: Bool) {
        start()
        self.paused = paused
    }

    func pause() {
        paused = true
    }

    func resume() {
        guard paused else { return }
        paused = false
        counter.restartBaseline()
    }

    func stop() {
        #if os(iOS)
        altimeter?.stopRelativeAltitudeUpdates()
        altimeter?.stopAbsoluteAltitudeUpdates()
        altimeter = nil
        #endif
        running = false
    }

    private func beginUpdates() {
        #if os(iOS)
        guard Self.isAvailable, !running else { return }
        let altimeter = CMAltimeter()
        self.altimeter = altimeter
        running = true
        altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
            guard let data else { return }
            // CoreMotion reports kilopascals; OpenTracks counts in hectopascals.
            let hPa = data.pressure.doubleValue * 10
            let relative = data.relativeAltitude.doubleValue
            MainActor.assumeIsolated { self?.receive(pressureHPa: hPa, relativeAltitudeM: relative) }
        }
        if CMAltimeter.isAbsoluteAltitudeAvailable() {
            altimeter.startAbsoluteAltitudeUpdates(to: .main) { [weak self] data, _ in
                guard let data, data.altitude.isFinite else { return }
                let altitude = data.altitude
                let accuracy = data.accuracy.isFinite && data.accuracy >= 0 ? data.accuracy : nil
                MainActor.assumeIsolated {
                    self?.altitudeM = altitude
                    self?.altitudeAccuracyM = accuracy
                }
            }
        }
        #endif
    }

    private func receive(pressureHPa: Double, relativeAltitudeM: Double) {
        if relativeAltitudeM.isFinite { self.relativeAltitudeM = relativeAltitudeM }
        guard !paused else { return }
        let added = counter.add(pressureHPa: pressureHPa)
        gainM = counter.gainM
        lossM = counter.lossM
        onElevation?(added.gainM, added.lossM)
    }
}
