import Foundation
import StrandAnalytics
import WhoopProtocol

/// The live workout's spoken feedback: a sentence on each kilometre (or mile) with a route, every ten minutes
/// without one, a word on pause and resume, and a recap at the end. On by default, silent unless headphones
/// are connected, and switched off for the session from the start panel (`enabledKey`).
///
/// It only reads what the workout already measures. Heart rate and Effort are spoken only when they were
/// actually received, so a run without a strap is announced as distance, pace and time alone.
@MainActor
final class WorkoutVoiceCoach {
    static let enabledKey = "workout.voice.enabled"
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    /// Spacing of the time-based announcement for workouts without a route.
    static let intervalSeconds = 600

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
    }

    /// Reads the running workout; nil once it has ended.
    var snapshot: (() -> Snapshot?)?

    private let speaker = WorkoutSpeaker()
    private var planner: WorkoutAnnouncementPlanner?
    private var system: UnitSystem = .metric
    /// Wall-clock second of the last announcement, the start of the heart-rate average for the next one.
    private var markTs = 0
    private var loop: Task<Void, Never>?

    /// Starts listening to a workout. Does nothing when the wearer switched announcements off. A workout
    /// restored after the app was relaunched is `resuming`: the splits it already covered count as announced,
    /// so the voice picks up at the next one instead of reading out the past.
    func begin(usesRoute: Bool, resuming: Bool = false) {
        stop()
        guard Self.isEnabled else { return }
        system = Self.distanceSystem()
        let splitMeters = system == .imperial ? 1_609.344 : 1_000
        planner = WorkoutAnnouncementPlanner(mode: usesRoute
            ? .distance(splitMeters: splitMeters)
            : .time(intervalSeconds: Self.intervalSeconds))
        markTs = Int(Date().timeIntervalSince1970)
        if resuming, let state = snapshot?() {
            _ = planner?.update(distanceMeters: state.distanceMeters, elapsedSeconds: state.elapsedSeconds)
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
    }

    func paused() {
        guard planner != nil else { return }
        say(String(localized: "Workout paused."))
    }

    func resumed() {
        guard planner != nil else { return }
        say(String(localized: "Workout resumed."))
    }

    /// Speaks the recap and stops. `elapsedSeconds` is active time.
    func ended(elapsedSeconds: Int, distanceMeters: Double?) {
        guard planner != nil else { return }
        loop?.cancel()
        loop = nil
        planner = nil
        say(WorkoutAnnouncementText.summary(elapsedSeconds: elapsedSeconds, distanceMeters: distanceMeters,
                                            system: system))
    }

    /// Stops without a word (discard, or a session too short to keep).
    func stop() {
        loop?.cancel()
        loop = nil
        planner = nil
        speaker.stop()
    }

    private func tick() {
        guard var planner, let state = snapshot?() else { return }
        let event = planner.update(distanceMeters: state.distanceMeters, elapsedSeconds: state.elapsedSeconds)
        self.planner = planner
        guard let event else { return }
        let now = Int(Date().timeIntervalSince1970)
        let averageBpm = Self.averageBpm(state.samples, since: markTs)
        markTs = now
        let zoneLine = WorkoutAnnouncementText.zone(bpm: averageBpm ?? state.bpm, targetZone: state.targetZone,
                                                    zoneSet: state.zoneSet)
        switch event {
        case let .split(index, splits, splitSeconds, elapsedSeconds):
            say(WorkoutAnnouncementText.split(index: index, secondsPerSplit: splitSeconds / max(splits, 1),
                                              elapsedSeconds: elapsedSeconds, averageBpm: averageBpm,
                                              zoneLine: zoneLine, system: system))
        case let .interval(elapsedSeconds):
            say(WorkoutAnnouncementText.interval(elapsedSeconds: elapsedSeconds, averageBpm: averageBpm,
                                                 effort: state.effort, zoneLine: zoneLine))
        }
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
