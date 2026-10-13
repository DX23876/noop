import XCTest
@testable import StrandAnalytics

/// The OpenTracks test vectors (Apache License 2.0), ported unchanged:
/// `androidTest/.../sensors/PressureSensorUtilsTest.java` and `.../sensorData/AggregatorBarometerTest.java`.
final class BarometricElevationTests: XCTestCase {

    /// OpenTracks `altitudeChanges_none`: real data at 500 Hz, phone stationary.
    static let stationaryHPa: [Double] = [
        1015.6876, 1015.699, 1015.70905, 1015.71075, 1015.7224, 1015.72, 1015.7373, 1015.7481, 1015.74133,
        1015.73553, 1015.7462, 1015.74896, 1015.752, 1015.754, 1015.7456, 1015.73303, 1015.7288, 1015.7239,
        1015.7298, 1015.7387, 1015.72534, 1015.72577, 1015.72797, 1015.71796, 1015.7113, 1015.7097, 1015.7096,
        1015.7013, 1015.7072, 1015.71063, 1015.7088, 1015.7115, 1015.713, 1015.7121, 1015.7062, 1015.7062,
        1015.6994, 1015.69617, 1015.68945, 1015.698, 1015.6913, 1015.69696, 1015.69293, 1015.6955, 1015.6928,
        1015.6939, 1015.68787, 1015.6881, 1015.68536, 1015.68726, 1015.6879, 1015.6904, 1015.6937, 1015.69476,
        1015.7046, 1015.7019, 1015.7079, 1015.71124, 1015.71216, 1015.71436, 1015.7171, 1015.7186, 1015.7186,
        1015.7246, 1015.72046, 1015.7211, 1015.72375, 1015.7194, 1015.72125, 1015.7161, 1015.71185, 1015.7188,
        1015.721, 1015.7252, 1015.72266, 1015.7236, 1015.72614, 1015.7266, 1015.7344, 1015.7376, 1015.7337,
        1015.7253, 1015.71875, 1015.7219, 1015.7219, 1015.7317, 1015.7284, 1015.73444, 1015.73584, 1015.7369,
        1015.73254, 1015.7369, 1015.7336, 1015.73254, 1015.73676, 1015.74176, 1015.74506, 1015.7478, 1015.755,
        1015.7515, 1015.7543, 1015.7459, 1015.7468, 1015.7492, 1015.74585, 1015.74756, 1015.74756, 1015.75085,
        1015.754, 1015.75336, 1015.7568, 1015.75165, 1015.761, 1015.7527, 1015.75684, 1015.7635, 1015.7585,
        1015.7552, 1015.7475, 1015.74506, 1015.7542, 1015.75586, 1015.74176, 1015.74414, 1015.7501, 1015.751,
        1015.7478, 1015.755, 1015.75836, 1015.7592, 1015.75256, 1015.7559, 1015.76654, 1015.76154, 1015.766,
        1015.77014, 1015.76904, 1015.76013, 1015.7674, 1015.76514, 1015.7674, 1015.7635, 1015.76404, 1015.7607,
        1015.754, 1015.7574, 1015.7607, 1015.7607, 1015.7607, 1015.754, 1015.7567, 1015.7616, 1015.7643, 1015.7666,
        1015.7609, 1015.766, 1015.76764, 1015.755, 1015.75757, 1015.74927, 1015.74927, 1015.7426, 1015.745,
        1015.745, 1015.7409, 1015.7376, 1015.7326, 1015.74164, 1015.74664, 1015.745, 1015.7459, 1015.7502,
        1015.7493, 1015.7476, 1015.7493, 1015.751, 1015.7601, 1015.76434, 1015.766, 1015.756, 1015.7617, 1015.7623,
        1015.76404, 1015.76733, 1015.7607, 1015.7623, 1015.76337, 1015.7584, 1015.7573, 1015.7502, 1015.7534,
        1015.7534, 1015.7601, 1015.75684, 1015.7518, 1015.75574, 1015.7524, 1015.7507, 1015.7484, 1015.7502,
        1015.7534, 1015.7623, 1015.75903, 1015.75574, 1015.75574, 1015.7573, 1015.7524, 1015.75574, 1015.75574,
        1015.7607, 1015.7573, 1015.754, 1015.74677, 1015.754, 1015.75574, 1015.75903, 1015.7573, 1015.7551,
        1015.7573, 1015.754, 1015.7507, 1015.7374, 1015.739, 1015.73566, 1015.73566, 1015.7367, 1015.7417,
        1015.7417, 1015.739, 1015.74835, 1015.74567, 1015.7517, 1015.74066, 1015.7374, 1015.739, 1015.7417,
        1015.73065, 1015.72894, 1015.73505, 1015.73334, 1015.74005, 1015.74005, 1015.7367, 1015.7434, 1015.744,
        1015.7423, 1015.7384, 1015.739, 1015.7374, 1015.7374, 1015.7374, 1015.7341, 1015.73505, 1015.7341,
        1015.7267, 1015.72833, 1015.7234, 1015.7167, 1015.725, 1015.7217, 1015.7234, 1015.73004, 1015.7324,
        1015.7423, 1015.74005, 1015.73505, 1015.73004, 1015.739, 1015.7417, 1015.74567, 1015.74066, 1015.74146,
        1015.74146, 1015.73816, 1015.7274, 1015.72906, 1015.7274, 1015.7341, 1015.739, 1015.744, 1015.7417,
        1015.7374, 1015.7324, 1015.73816, 1015.74146, 1015.7374, 1015.7341, 1015.7365, 1015.7365, 1015.74146,
        1015.74414, 1015.7475, 1015.7448, 1015.74146, 1015.74585, 1015.7475, 1015.75146, 1015.75146, 1015.7591,
        1015.75476, 1015.7614, 1015.75476, 1015.7492, 1015.74817, 1015.7498, 1015.7515, 1015.75586, 1015.7509,
        1015.7448, 1015.7525, 1015.7581, 1015.7592
    ]

    /// OpenTracks `computeChanges_downhill`: a sudden drop of altitude.
    static let downhillHPa: [Double] = [1015, 1015.01, 1015.02, 1015.03, 1015.04, 1015.05, 1015.06, 1015.07, 1015.08,
                                        1015.09, 1015.10, 1015.11, 1015.12, 1015.13, 1018, 1018.1, 1018.1, 1018.1, 1018.1]

    func testStationaryReadingsNeverChangeAltitude() {
        let first = Self.stationaryHPa[0]
        for value in Self.stationaryHPa {
            XCTAssertNil(BarometricElevationCounter.computeChange(lastAcceptedHPa: first, currentHPa: value))
        }
    }

    func testComputeChangesDownhill() {
        var gain = 0.0, loss = 0.0
        var lastUsed = Self.downhillHPa[0]
        for value in Self.downhillHPa {
            if let change = BarometricElevationCounter.computeChange(lastAcceptedHPa: lastUsed, currentHPa: value) {
                gain += max(change.altitudeChangeM, 0)
                loss += max(-change.altitudeChangeM, 0)
                lastUsed = change.acceptedHPa
            }
        }
        XCTAssertEqual(gain, 0, accuracy: 0.01)
        XCTAssertEqual(loss, 15, accuracy: 0.01)
        XCTAssertEqual(lastUsed, 1016.80, accuracy: 0.01)
    }

    /// OpenTracks `getAltitudeGainLoss_downhill`: the same drop through the smoothing aggregator.
    func testAggregatorDownhill() {
        var counter = BarometricElevationCounter()
        for value in Self.downhillHPa { counter.add(pressureHPa: value) }
        XCTAssertEqual(counter.gainM, 0, accuracy: 0.01)
        XCTAssertEqual(counter.lossM, 15, accuracy: 0.01)
    }

    func testStationaryStreamCountsNothing() {
        var counter = BarometricElevationCounter()
        for value in Self.stationaryHPa { counter.add(pressureHPa: value) }
        XCTAssertEqual(counter.gainM, 0)
        XCTAssertEqual(counter.lossM, 0)
    }

    /// The mirror of the downhill vector counts the same height as gain.
    func testUphillMirrorCountsGain() {
        var counter = BarometricElevationCounter()
        for value in Self.downhillHPa.map({ 2030 - $0 }) { counter.add(pressureHPa: value) }
        XCTAssertEqual(counter.gainM, 15, accuracy: 0.01)
        XCTAssertEqual(counter.lossM, 0, accuracy: 0.01)
    }

    /// NOOP's addition: after a pause the first reading is a new baseline, so a height change that
    /// happened while paused is not counted; totals before the pause are kept.
    func testRestartBaselineIgnoresChangeDuringPause() {
        var counter = BarometricElevationCounter()
        for value in Self.downhillHPa { counter.add(pressureHPa: value) }
        counter.restartBaseline()
        for _ in 0..<10 { counter.add(pressureHPa: 1000) }
        XCTAssertEqual(counter.lossM, 15, accuracy: 0.01)
        XCTAssertEqual(counter.gainM, 0, accuracy: 0.01)
    }

    func testInvalidReadingsAreIgnored() {
        var counter = BarometricElevationCounter()
        counter.add(pressureHPa: .nan)
        counter.add(pressureHPa: -1)
        counter.add(pressureHPa: 0)
        XCTAssertEqual(counter.gainM, 0)
        XCTAssertEqual(counter.lossM, 0)
    }

    /// The two OpenTracks formulas are not exact inverses (44330 against 288.15 / 0.0065); the residue stays
    /// far below the 3 m step at any height a workout reaches.
    func testAltitudePressureRoundTrip() {
        for h in [-100.0, 0, 250, 1000, 3000] {
            let p = BarometricElevationCounter.pressureHPa(altitudeM: h)
            XCTAssertEqual(BarometricElevationCounter.altitudeM(pressureHPa: p), h, accuracy: 0.1)
        }
    }
}
