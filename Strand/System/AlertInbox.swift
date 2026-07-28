import Foundation

/// Records recent, user-facing local alerts in the bell without coupling the alert engines to SwiftUI.
/// This is intentionally separate from scheduled reminders: only an event that actually happened calls
/// this bridge. A denied system-notification permission therefore hides the banner, never the local log.
enum AlertInbox {
    enum Kind: String {
        case batteryLow = "battery-low"
        case batteryRuntime = "battery-runtime"
        case batteryFull = "battery-full"
        case batteryCritical = "battery-critical"
        case batteryBedtime = "battery-bedtime"
        case illness = "illness"
        case inactivity = "inactivity"
        case smartAlarm = "smart-alarm"

        var lifetime: TimeInterval {
            switch self {
            case .batteryLow, .batteryRuntime, .batteryCritical: return 3 * 24 * 60 * 60
            case .batteryFull, .batteryBedtime:                  return 24 * 60 * 60
            case .illness:                     return 2 * 24 * 60 * 60
            case .inactivity, .smartAlarm:     return 24 * 60 * 60
            }
        }

        var deepLink: String? {
            switch self {
            case .batteryLow, .batteryRuntime, .batteryFull, .batteryCritical, .batteryBedtime:
                return NavRouter.Destination.devices.rawValue
            case .illness, .inactivity, .smartAlarm: return nil
            }
        }
    }

    /// Safe from the BLE and notification callbacks, which do not all run on the main actor.
    static func post(_ kind: Kind, title: String, message: String, now: Date = Date()) {
        let key = "\(kind.rawValue):\(dayKey(now))"
        let expiresAt = now.addingTimeInterval(kind.lifetime)
        Task { @MainActor in
            UpdateStore.shared.postOrRefreshAlert(
                key: key, title: title, message: message,
                deepLink: kind.deepLink, expiresAt: expiresAt, now: now
            )
        }
    }

    private static func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = .current
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
