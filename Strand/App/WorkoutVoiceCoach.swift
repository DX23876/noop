import Foundation
import StrandAnalytics
import WhoopProtocol

/// Session-owned offline speech and opt-in, fresh-data range warnings, including while minimized.
/// Off by default; changing settings primes the schedule rather than speaking a backlog.
///
/// It only reads what the workout already measures. Heart rate and Effort are spoken only when they were
/// actually received, so a run without a strap is announced as distance, pace and time alone.
@MainActor
final class WorkoutVoiceCoach {
    static let enabledKey = "workout.voice.enabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? false }

    /// What the coach needs from the running workout at each tick.
    struct Snapshot {
        var elapsedSeconds: Int
        /// Route distance, nil when the workout records no route.
        var distanceMeters: Double?
        var samples: [HRSample]
        var bpm: Int?
        var targetZone: Int?
        var zoneSet: HRZoneSet
        /// Effort already formatted for display, nil until heart rate has produced one.
        var effort: String?
        var now: Date = .now
        var isPaused = false
        var sport = "Running"
        var currentSpeedMps: Double?
        var cadence: Double?
        var distanceFresh = false
        var completedSplit: WorkoutRecordingTimeline.Section?
        var splitLengthM: Double?
        var splitAverageBpm: Int?
        var coachingSuppressed = false
    }

    /// Reads the running workout; nil once it has ended.
    var snapshot: ((Date) -> Snapshot?)?
    var onWarning: ((String, Bool) -> Void)?
    var onTick: ((Date) -> Void)?

    private let speaker = WorkoutSpeaker()
    private var isActive = false
    private var workoutID: UUID?
    private var schedule = WorkoutFeedbackSchedule()
    private var wasEnabled = false
    private var heartRateAlert = WorkoutRangeAlertEngine()
    private var motionAlert = WorkoutRangeAlertEngine()
    private var cadenceAlert = WorkoutRangeAlertEngine()
    private var lastWarningAt = Date.distantPast
    private var feedbackMutedUntil = Date.distantPast
    private var usesRoute = false
    private var system: UnitSystem = .metric
    private var loop: Task<Void, Never>?

    /// Starts session maintenance even with speech off. Priming prevents any old announcements on restore.
    func begin(usesRoute: Bool, workoutID: UUID) {
        stop()
        self.workoutID = workoutID
        self.usesRoute = usesRoute
        system = Self.distanceSystem()
        isActive = true
        wasEnabled = Self.isEnabled
        schedule = WorkoutFeedbackSchedule()
        if let state = snapshot?(.now) { primeSchedule(state) }
        heartRateAlert = WorkoutRangeAlertEngine()
        motionAlert = WorkoutRangeAlertEngine()
        cadenceAlert = WorkoutRangeAlertEngine()
        lastWarningAt = .distantPast
        feedbackMutedUntil = .distantPast
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.tick()
            }
        }
    }

    func paused() {
        guard isActive else { return }
        speaker.stop()
        guard Self.isEnabled else { return }
        say(String(localized: "Workout paused."))
    }

    func resumed() {
        guard isActive else { return }
        guard Self.isEnabled else { return }
        say(String(localized: "Workout resumed."))
    }

    /// Phase cues take priority over range/split announcements; do not queue stale speech behind them.
    func phaseChanged(_ text: String, at now: Date) {
        feedbackMutedUntil = now.addingTimeInterval(8)
        speaker.stop()
        if Self.isEnabled { say(text) }
    }

    /// Speaks the recap and stops. `elapsedSeconds` is active time.
    func ended(workoutID: UUID, elapsedSeconds: Int, distanceMeters: Double?, sport: String = "Running", averageBpm: Int? = nil,
               personalBest: WorkoutPersonalBest.Result? = nil) {
        guard isActive, self.workoutID == workoutID else { return }
        loop?.cancel()
        loop = nil
        isActive = false
        self.workoutID = nil
        guard Self.isEnabled else { speaker.stop(); return }
        let recap = WorkoutAnnouncementText.summary(elapsedSeconds: elapsedSeconds, distanceMeters: distanceMeters,
                                            system: system, usesSpeed: WorkoutCatalog.usesSpeedReadout(for: sport),
                                            averageBpm: averageBpm)
        let best = personalBest.map { String(localized: "New best recorded split: \(WorkoutAnnouncementText.duration(Int($0.current.seconds.rounded()))).") }
        say([recap, best].compactMap { $0 }.joined(separator: " "))
    }

    /// Stops without a word (discard, or a session too short to keep).
    func stop() {
        loop?.cancel()
        loop = nil
        isActive = false
        workoutID = nil
        speaker.stop()
    }

    /// Freeze announcements during persistence; keep the recap armed until the commit succeeds.
    func preparingToSave() {
        loop?.cancel()
        loop = nil
        speaker.stop()
    }

    private func tick() {
        let now = Date.now
        onTick?(now)
        guard isActive, let state = snapshot?(now) else { return }
        let enabled = Self.isEnabled
        if enabled != wasEnabled {
            speaker.stop()
            primeSchedule(state)
            wasEnabled = enabled
        }
        let event = schedule.update(distance: state.distanceMeters ?? 0, seconds: Double(state.elapsedSeconds),
                                    distanceFresh: state.distanceFresh, everyMeters: distanceInterval,
                                    everySeconds: WorkoutFeedbackPreferences.timeInterval(), paused: state.isPaused)
        // Zone > pace/speed > cadence; one cue per cooldown prevents overlapping phone warnings.
        guard state.now >= feedbackMutedUntil else { return }
        let warning = warning(state)
        if let warning, state.now.timeIntervalSince(lastWarningAt) >= 60 {
            lastWarningAt = state.now
            onWarning?(warning.text, warning.isZone)
            if enabled { say(warning.text) }
            return
        }
        guard enabled, !state.isPaused, let event else { return }
        let distance: Double? = if case .distance(let meters) = event { meters } else { nil }
        let split = state.completedSplit.flatMap { section in
            guard let distance, let length = state.splitLengthM, distanceInterval == length,
                  abs(distance - Double(section.index) * length) < 0.01 else { return nil as WorkoutRecordingTimeline.Section? }
            return section
        }
        say(WorkoutAnnouncementText.feedback(distanceMeters: distance, elapsedSeconds: state.elapsedSeconds,
                                             speedMps: state.currentSpeedMps, bpm: state.bpm,
                                             usesSpeed: WorkoutCatalog.usesSpeedReadout(for: state.sport), system: system,
                                             splitSpeedMps: split?.speedMps,
                                             splitAverageBpm: split == nil ? nil : state.splitAverageBpm))
    }

    private var distanceInterval: Double {
        usesRoute ? WorkoutFeedbackPreferences.distanceInterval() * (system == .imperial ? 1609.344 : 1000) : 0
    }

    private func primeSchedule(_ state: Snapshot) {
        schedule.prime(distance: state.distanceMeters ?? 0, seconds: Double(state.elapsedSeconds),
                       everyMeters: distanceInterval, everySeconds: WorkoutFeedbackPreferences.timeInterval())
    }

    private func warning(_ state: Snapshot) -> (text: String, isZone: Bool)? {
        let defaults = UserDefaults.standard
        let now = state.now.timeIntervalSince1970
        if state.coachingSuppressed {
            _ = heartRateAlert.update(value: nil, range: nil, now: now, paused: true)
            _ = motionAlert.update(value: nil, range: nil, now: now, paused: true)
            _ = cadenceAlert.update(value: nil, range: nil, now: now, paused: true)
            return nil
        }
        // Use the canonical zone resolver, including its edge tolerance and inclusive top zone.
        let target = state.targetZone.flatMap { (1...5).contains($0) ? Double($0) : nil }
        let hrRange = defaults.bool(forKey: WorkoutFeedbackPreferences.heartRateAlertKey)
            ? target.map { $0...$0 } : nil
        let hr = heartRateAlert.update(value: state.bpm.map { Double(state.zoneSet.zoneNumber(forBPM: Double($0))) },
                                       range: hrRange, now: now, paused: state.isPaused)
        var speedRange: ClosedRange<Double>?
        if defaults.bool(forKey: WorkoutFeedbackPreferences.motionAlertKey), usesRoute {
            if WorkoutCatalog.usesSpeedReadout(for: state.sport) {
                speedRange = WorkoutFeedbackPreferences.range(low: WorkoutFeedbackPreferences.lowSpeedKey,
                    high: WorkoutFeedbackPreferences.highSpeedKey, fallback: 15...30, bounds: 1...100).map { ($0.lowerBound / 3.6)...($0.upperBound / 3.6) }
            } else {
                let unit = system == .imperial ? 1609.344 : 1000
                speedRange = WorkoutFeedbackPreferences.range(low: WorkoutFeedbackPreferences.fastPaceKey,
                    high: WorkoutFeedbackPreferences.slowPaceKey, fallback: 300...420, bounds: 120...1800)
                    .map { (unit / $0.upperBound)...(unit / $0.lowerBound) }
            }
        }
        let motion = motionAlert.update(value: state.currentSpeedMps, range: speedRange, now: now, paused: state.isPaused)
        let cadenceRange = WorkoutFeedbackPreferences.cadenceWarningRange(defaults)
        let cadence = cadenceAlert.update(value: state.cadence, range: cadenceRange, now: now, paused: state.isPaused)
        if let hr {
            return (hr == .above ? String(localized: "Above your target zone. Ease off.")
                                : String(localized: "Below your target zone. Pick it up."), true)
        }
        if let motion {
            return (motion == .above ? String(localized: "Faster than your target range.")
                                    : String(localized: "Slower than your target range."), false)
        }
        if let cadence {
            return (cadence == .above ? String(localized: "Cadence above your target range.")
                                     : String(localized: "Cadence below your target range."), false)
        }
        return nil
    }

    private func say(_ text: String) {
        speaker.speak(text, locale: WorkoutAnnouncementText.appLocale)
    }

    /// Mean heart rate of the samples since `since`, nil when none arrived (no strap, or a dropout).
    nonisolated static func averageBpm(_ samples: [HRSample], since: Int) -> Int? {
        let recent = samples.filter { $0.ts >= since }
        guard !recent.isEmpty else { return nil }
        return Int((Double(recent.reduce(0) { $0 + $1.bpm }) / Double(recent.count)).rounded())
    }

    private static func distanceSystem() -> UnitSystem {
        let defaults = UserDefaults.standard
        let system = UnitSystem(rawValue: defaults.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        return UnitPrefs.resolveDistance(system: system,
                                         override: defaults.string(forKey: UnitPrefs.distanceSystemKey) ?? "")
    }
}
