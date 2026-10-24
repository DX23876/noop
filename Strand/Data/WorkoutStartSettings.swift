import Foundation
import StrandCore

/// The route and zone-coach choice an activity was last started with, so a quick start from the
/// Training tab repeats it and can say beforehand what it will do. Kept per activity: a walk with GPS
/// and an indoor cycle without it are each "the last time" for their own sport.
struct WorkoutStartSettings: Codable, Equatable {
    var gpsEnabled: Bool
    var targetZone: Int?

    static let key = "workout.startSettings"

    /// What a start uses before the activity was ever started: the catalogue's route default and no
    /// zone coach, so nothing buzzes that the wearer did not ask for.
    static func initial(for sport: WorkoutCatalog.Sport) -> WorkoutStartSettings {
        WorkoutStartSettings(gpsEnabled: sport.defaultGpsEnabled, targetZone: nil)
    }

    static func remembered(for sport: WorkoutCatalog.Sport,
                           in defaults: UserDefaults = .standard) -> WorkoutStartSettings {
        (stored(defaults)[storageKey(sport.name)] ?? initial(for: sport)).valid(for: sport)
    }

    static func record(_ settings: WorkoutStartSettings, for sport: WorkoutCatalog.Sport,
                       in defaults: UserDefaults = .standard) {
        var all = stored(defaults)
        all[storageKey(sport.name)] = settings.valid(for: sport)
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }

    /// No route for an activity that cannot record one, and only zones the coach knows.
    func valid(for sport: WorkoutCatalog.Sport) -> WorkoutStartSettings {
        WorkoutStartSettings(gpsEnabled: sport.supportsRoute && gpsEnabled,
                             targetZone: targetZone.flatMap { (1...5).contains($0) ? $0 : nil })
    }

    private static func storageKey(_ name: String) -> String { name.lowercased() }

    private static func stored(_ defaults: UserDefaults) -> [String: WorkoutStartSettings] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: WorkoutStartSettings].self, from: data)
        else { return [:] }
        return decoded
    }
}

/// Which activities the Training tab offers to start with one tap.
@MainActor
enum WorkoutQuickStart {
    static let maxActivities = 4
    static let minimumActivities = 3
    /// Offered until the wearer's own recents fill the list, so a first visit is not empty.
    static let starterNames = ["Walking", "Running", "Cycling"]

    /// The wearer's recent activities first, strength left out (it starts the logger from its own row),
    /// then the starter set to fill a short list.
    static func activities(recent: [String]) -> [WorkoutCatalog.Sport] {
        var picked: [WorkoutCatalog.Sport] = []
        func add(_ name: String) {
            guard picked.count < maxActivities, let sport = WorkoutCatalog.sport(named: name),
                  !ActiveSessionController.isStrengthSport(sport.name),
                  !picked.contains(where: { $0.name == sport.name }) else { return }
            picked.append(sport)
        }
        recent.forEach(add)
        for name in starterNames where picked.count < minimumActivities { add(name) }
        return picked
    }

    /// Starts an activity with the given settings and remembers them, with the recents, for next time.
    static func start(_ sport: WorkoutCatalog.Sport, with settings: WorkoutStartSettings,
                      session: ActiveSessionController, closingSheet: Bool = false) {
        let settings = settings.valid(for: sport)
        RecentSportsPrefs.recordSelection(sport.name)
        WorkoutStartSettings.record(settings, for: sport)
        session.requestCardio(sport: sport.name, targetZone: settings.targetZone,
                              gpsEnabled: settings.gpsEnabled, closingSheet: closingSheet)
    }
}
