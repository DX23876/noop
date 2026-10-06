import Foundation

/// Filters untrusted route fixes while preserving the original coordinates and measurements.
final class TrackFilter {
    private let maxAccuracyM: Double
    private let maxSpeedMps: Double
    private let requiresMotionEvidence: Bool
    private var last: RawFix?
    private var lastSeenMs: Int64?
    // App heuristics, not Apple-prescribed thresholds. Coarse positions require measured motion;
    // coordinate-only fallback is limited to precise fixes, never an indoor location search.
    private let stationarySpeedMps = 0.3
    private let maximumMotionAccuracyM = 25.0
    private let maximumPositionOnlyAccuracyM = 10.0
    private let plausibleWalkingSpeedMps = 0.5

    init(maxAccuracyM: Double = 50, maxSpeedMps: Double = 12, requiresMotionEvidence: Bool = false) {
        self.maxAccuracyM = maxAccuracyM
        self.maxSpeedMps = maxSpeedMps
        self.requiresMotionEvidence = requiresMotionEvidence
    }

    /// How a usable fix relates to the route: dropped, joined to the previous point, or a fresh anchor.
    enum Admission: Equatable {
        case rejected
        case joined(RouteMath.LatLng)
        case anchored(RouteMath.LatLng)
    }

    func accept(_ fix: RawFix, notBeforeMs: Int64? = nil) -> RouteMath.LatLng? {
        switch admit(fix, notBeforeMs: notBeforeMs) {
        case .rejected: return nil
        case .joined(let point), .anchored(let point): return point
        }
    }

    /// `afterGap` marks the first fixes after a stretch without usable measurements. The previous point
    /// is kept, so a gap the measured motion can explain is bridged like OpenTracks does, rather than
    /// losing everything walked in the meantime. A jump the motion cannot explain re-anchors instead,
    /// which keeps a reacquired position from becoming invented distance.
    func admit(_ fix: RawFix, notBeforeMs: Int64? = nil, afterGap: Bool = false) -> Admission {
        if let notBeforeMs, fix.tMs < notBeforeMs { return .rejected }
        guard hasUsableSignal(fix) else { return .rejected }
        if let lastSeenMs, fix.tMs <= lastSeenMs { return .rejected }
        lastSeenMs = fix.tMs
        guard let prev = last else {
            last = fix
            return .anchored(RouteMath.LatLng(fix.lat, fix.lon))
        }
        // The system's stationarity signal wins over coordinate drift and speed estimates.
        if fix.stationary { return .rejected }
        let hasSpeed = fix.hasValidSpeed
        let speed = fix.speedMps ?? 0
        let uncertainty = fix.speedAccuracyMps ?? 0
        if hasSpeed, speed + uncertainty <= stationarySpeedMps { return .rejected }

        let dt = (Double(fix.tMs) - Double(prev.tMs)) / 1000.0
        let d = RouteMath.haversineMeters(RouteMath.LatLng(prev.lat, prev.lon),
                                         RouteMath.LatLng(fix.lat, fix.lon))
        var explained = dt > 0 && d / dt <= maxSpeedMps
        if explained, hasSpeed, !(afterGap && dt > Self.measuredSpeedHorizonSeconds) {
            // Even a plausible running-speed ceiling cannot justify a coordinate jump that
            // contradicts the measured speed and the uncertainty at both endpoints. Across a longer gap
            // the instantaneous speed says nothing about the pace walked while unmeasured, so only the
            // sport's ceiling applies there.
            explained = d <= (speed + uncertainty) * dt + prev.accuracyM + fix.accuracyM
        }
        if afterGap, explained, d > Self.maximumBridgeM, dt > Self.maximumBridgeSeconds { explained = false }
        guard explained else { return afterGap ? reanchor(fix) : .rejected }
        // Reliable movement preserves short walking legs and corners even when positional
        // accuracy circles overlap. Without it, retain the conservative jitter fallback.
        let confidentlyMoving = hasSpeed && speed - uncertainty > stationarySpeedMps
        if !confidentlyMoving, d <= prev.accuracyM + fix.accuracyM { return .rejected }
        last = fix
        return .joined(RouteMath.LatLng(fix.lat, fix.lon))
    }

    /// OpenTracks starts a new segment only beyond 200 m; a short outage is bridged by any distance.
    static let maximumBridgeM = 200.0
    static let maximumBridgeSeconds = 30.0
    /// Beyond this a current speed no longer describes the whole leg since the previous point.
    static let measuredSpeedHorizonSeconds = 10.0

    private func reanchor(_ fix: RawFix) -> Admission {
        last = fix
        return .anchored(RouteMath.LatLng(fix.lat, fix.lon))
    }

    /// One route-admission rule for the filter and the recorder's signal state/segment boundary.
    func hasUsableSignal(_ fix: RawFix) -> Bool {
        guard fix.accuracyM.isFinite, fix.accuracyM >= 0,
              fix.accuracyM <= min(maxAccuracyM, maximumMotionAccuracyM),
              fix.lat.isFinite, (-90...90).contains(fix.lat),
              fix.lon.isFinite, (-180...180).contains(fix.lon) else { return false }
        if fix.hasValidSpeed, (fix.speedMps ?? 0) > maxSpeedMps { return false }
        let confidentlyMoving = !fix.stationary && fix.hasValidSpeed
            && (fix.speedMps ?? 0) - (fix.speedAccuracyMps ?? 0) > stationarySpeedMps
        if requiresMotionEvidence {
            // iPhone GNSS supplies speed uncertainty. A coordinate change alone is not proof that
            // a stationary phone moved, even when Core Location reports good horizontal accuracy.
            let confidentlyStopped = fix.hasValidSpeed
                && (fix.speedMps ?? 0) + (fix.speedAccuracyMps ?? 0) <= stationarySpeedMps
            // A walking-pace GNSS speed with a wide uncertainty is still a measured speed, which
            // Wi-Fi drift indoors does not supply. It only moves the route past the accuracy circles.
            let plausiblyMoving = !fix.stationary && fix.hasValidSpeed
                && (fix.speedMps ?? 0) >= plausibleWalkingSpeedMps
            return confidentlyMoving || confidentlyStopped || plausiblyMoving
                || (fix.stationary && fix.accuracyM <= maximumPositionOnlyAccuracyM)
        }
        return confidentlyMoving || fix.accuracyM <= maximumPositionOnlyAccuracyM
    }

    /// A restored route may only join a new fix if their elapsed time permits the displacement.
    func couldFollow(_ fix: RawFix, from lat: Double, _ lon: Double, at fromMs: Int64) -> Bool {
        let dt = (Double(fix.tMs) - Double(fromMs)) / 1000.0
        guard dt > 0 else { return false }
        let d = RouteMath.haversineMeters(RouteMath.LatLng(lat, lon), RouteMath.LatLng(fix.lat, fix.lon))
        return d / dt <= maxSpeedMps
    }
}
