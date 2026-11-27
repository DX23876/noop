import Foundation

/// When Hevy is asked on its own (Discord 2026-11-27: a pull by hand for every logged workout). The wearer picks
/// how often; each platform wakes in its own way (WorkManager on Android, a background refresh and the next
/// foreground on Apple) and asks this rule whether a run is due, so a wake that comes early, or a pull by hand a
/// moment before, does not start a second run.
public enum HevyAutoImport {
    /// How often the wearer wants new Hevy workouts brought in.
    public enum Interval: String, CaseIterable, Codable, Sendable {
        case off
        case sixHours = "6h"
        case twelveHours = "12h"
        case daily = "24h"

        /// Seconds between runs; nil when off.
        public var seconds: Int? {
            switch self {
            case .off: return nil
            case .sixHours: return 6 * 3_600
            case .twelveHours: return 12 * 3_600
            case .daily: return 24 * 3_600
            }
        }
    }

    /// The preference key both platforms store the choice under.
    public static let intervalKey = "hevy.autoImportInterval"
    /// Off until the wearer picks an interval: every NOOP automation that reaches the network is opt-in, as the
    /// Hevy connection itself and the folder backup are. Nothing runs without a key either way.
    public static let defaultInterval: Interval = .off

    /// The stored choice, the default for anything unreadable.
    public static func interval(_ raw: String?) -> Interval {
        raw.flatMap(Interval.init(rawValue:)) ?? defaultInterval
    }

    /// A wake up to a tenth of the interval early still counts: Android's periodic work and Apple's background
    /// refresh both run near, not at, the time asked for, and skipping such a wake would push the run a whole
    /// interval later.
    public static func isDue(lastRun: Int?, now: Int, interval: Interval) -> Bool {
        guard let seconds = interval.seconds else { return false }
        guard let lastRun, lastRun <= now else { return true }
        return now - lastRun >= seconds - seconds / 10
    }

    /// The earliest moment the next run is due, for a background request's begin date; nil when off.
    public static func nextDue(lastRun: Int?, now: Int, interval: Interval) -> Int? {
        guard let seconds = interval.seconds else { return nil }
        guard let lastRun, lastRun <= now else { return now }
        return max(now, lastRun + seconds - seconds / 10)
    }

    /// Hevy's answers that no later run can change without the wearer: no key, a key Hevy rejects, an account
    /// its API does not serve. An automatic run that meets one stops asking until the wearer acts in Data Sources.
    public static func needsWearer(_ error: String?) -> Bool {
        ["notConnected", "unauthorized", "notPro"].contains(error ?? "")
    }
}
