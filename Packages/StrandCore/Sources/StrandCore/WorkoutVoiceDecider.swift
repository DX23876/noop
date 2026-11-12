import Foundation
import StrandAnalytics

/// What the live workout's voice says each second, decided in one place for iOS (`WorkoutVoiceCoach`) and the
/// Android core: the announcement schedule (`WorkoutFeedbackSchedule`), the opt-in range warnings
/// (`WorkoutRangeAlertEngine`) with their priority (zone, then pace or speed), the one-minute cooldown and the short
/// silence after a phase cue. It decides only; each platform words and speaks the result.
public struct WorkoutVoiceDecider: Sendable {
    /// The wearer's choices for this workout, read once a tick.
    public struct Settings: Equatable, Sendable {
        public var voiceEnabled: Bool
        /// Announcement distance in the wearer's unit (0, 0.5, 1 or 2); 0 announces by time only.
        public var distanceInterval: Double
        public var timeIntervalSeconds: Double
        public var imperial: Bool
        public var usesRoute: Bool
        public var heartRateAlert: Bool
        public var motionAlert: Bool
        /// Pace range in seconds per unit (fastest, slowest), for sports read as pace.
        public var paceRange: ClosedRange<Double>?
        /// Speed range in km/h, for sports read as speed.
        public var speedRangeKmh: ClosedRange<Double>?

        public init(voiceEnabled: Bool, distanceInterval: Double, timeIntervalSeconds: Double, imperial: Bool,
                    usesRoute: Bool, heartRateAlert: Bool, motionAlert: Bool, paceRange: ClosedRange<Double>?,
                    speedRangeKmh: ClosedRange<Double>?) {
            self.voiceEnabled = voiceEnabled; self.distanceInterval = distanceInterval
            self.timeIntervalSeconds = timeIntervalSeconds; self.imperial = imperial; self.usesRoute = usesRoute
            self.heartRateAlert = heartRateAlert; self.motionAlert = motionAlert; self.paceRange = paceRange
            self.speedRangeKmh = speedRangeKmh
        }
    }

    /// The running workout at one tick.
    public struct Snapshot: Sendable {
        public var now: Double
        public var elapsedSeconds: Int
        public var distanceMeters: Double?
        public var distanceFresh: Bool
        public var isPaused: Bool
        /// The zone (1 to 5) of the latest fresh heart rate, nil without one.
        public var zone: Int?
        public var targetZone: Int?
        public var speedMps: Double?
        public var usesSpeed: Bool
        public var coachingSuppressed: Bool

        public init(now: Double, elapsedSeconds: Int, distanceMeters: Double?, distanceFresh: Bool, isPaused: Bool,
                    zone: Int?, targetZone: Int?, speedMps: Double?, usesSpeed: Bool, coachingSuppressed: Bool = false) {
            self.now = now; self.elapsedSeconds = elapsedSeconds; self.distanceMeters = distanceMeters
            self.distanceFresh = distanceFresh; self.isPaused = isPaused; self.zone = zone; self.targetZone = targetZone
            self.speedMps = speedMps; self.usesSpeed = usesSpeed; self.coachingSuppressed = coachingSuppressed
        }
    }

    public enum Warning: String, Sendable { case zoneAbove, zoneBelow, faster, slower }

    public enum Decision: Equatable, Sendable {
        /// A range warning; the platform shows it and speaks it when the voice is on.
        case warning(Warning)
        /// A scheduled announcement; `distanceMeters` is set when a distance mark was reached.
        case announce(distanceMeters: Double?)
    }

    private var schedule = WorkoutFeedbackSchedule()
    private var heartRate = WorkoutRangeAlertEngine()
    private var motion = WorkoutRangeAlertEngine()
    private var lastWarningAt = -Double.infinity
    private var mutedUntil = -Double.infinity
    private var voiceWasEnabled = false

    public init() {}

    /// Auto-pause is for GPS running and cycling only, where standing still means a real stop.
    public static func supportsAutoPause(sport: String, gps: Bool) -> Bool {
        gps && ["Running", "Cycling", "Mountain biking"].contains(sport)
    }

    /// Starts a workout (or a restore) without speaking a backlog.
    public mutating func begin(settings: Settings, snapshot: Snapshot) {
        self = WorkoutVoiceDecider()
        voiceWasEnabled = settings.voiceEnabled
        prime(settings, snapshot)
    }

    /// A phase cue spoke: range and split speech wait eight seconds behind it.
    public mutating func phaseCue(at now: Double) { mutedUntil = now + 8 }

    public mutating func tick(settings: Settings, snapshot s: Snapshot) -> Decision? {
        if settings.voiceEnabled != voiceWasEnabled {
            voiceWasEnabled = settings.voiceEnabled
            prime(settings, s)
        }
        let event = schedule.update(distance: s.distanceMeters ?? 0, seconds: Double(s.elapsedSeconds),
                                    distanceFresh: s.distanceFresh, everyMeters: meters(settings),
                                    everySeconds: settings.timeIntervalSeconds, paused: s.isPaused)
        guard s.now >= mutedUntil else { return nil }
        if let warning = warning(settings, s), s.now - lastWarningAt >= 60 {
            lastWarningAt = s.now
            return .warning(warning)
        }
        guard settings.voiceEnabled, !s.isPaused, let event else { return nil }
        if case .distance(let m) = event { return .announce(distanceMeters: m) }
        return .announce(distanceMeters: nil)
    }

    private func meters(_ settings: Settings) -> Double {
        settings.usesRoute ? settings.distanceInterval * (settings.imperial ? 1609.344 : 1000) : 0
    }

    private mutating func prime(_ settings: Settings, _ s: Snapshot) {
        schedule.prime(distance: s.distanceMeters ?? 0, seconds: Double(s.elapsedSeconds),
                       everyMeters: meters(settings), everySeconds: settings.timeIntervalSeconds)
    }

    private mutating func warning(_ settings: Settings, _ s: Snapshot) -> Warning? {
        if s.coachingSuppressed {
            _ = heartRate.update(value: nil, range: nil, now: s.now, paused: true)
            _ = motion.update(value: nil, range: nil, now: s.now, paused: true)
            return nil
        }
        let target = s.targetZone.flatMap { (1...5).contains($0) ? Double($0) : nil }
        let hrRange = settings.heartRateAlert ? target.map { $0...$0 } : nil
        let hr = heartRate.update(value: s.zone.map(Double.init), range: hrRange, now: s.now, paused: s.isPaused)
        var speedRange: ClosedRange<Double>?
        if settings.motionAlert, settings.usesRoute {
            if s.usesSpeed {
                speedRange = settings.speedRangeKmh.map { ($0.lowerBound / 3.6)...($0.upperBound / 3.6) }
            } else {
                let unit = settings.imperial ? 1609.344 : 1000
                speedRange = settings.paceRange.map { (unit / $0.upperBound)...(unit / $0.lowerBound) }
            }
        }
        let m = motion.update(value: s.speedMps, range: speedRange, now: s.now, paused: s.isPaused)
        if let hr { return hr == .above ? .zoneAbove : .zoneBelow }
        if let m { return m == .above ? .faster : .slower }
        return nil
    }
}
