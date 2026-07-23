import Foundation

/// Manual, user-set day-level activity status — independent of the computed Charge/Effort/Rest scores.
/// docs/noop-feature-spec.md §1.
struct ActivityStatus: Codable, Equatable {
    enum State: String, Codable, CaseIterable {
        case active, sick, injured, onBreak

        /// Status-chip / sheet label (docs/design/mockup-heute.html `.opt b`).
        var displayName: String {
            switch self {
            case .active:  return String(localized: "Active", comment: "ActivityStatus label")
            case .sick:    return String(localized: "Sick", comment: "ActivityStatus label")
            case .injured: return String(localized: "Injured", comment: "ActivityStatus label")
            case .onBreak: return String(localized: "On break", comment: "ActivityStatus label")
            }
        }

        /// Sheet-row subtitle (docs/design/mockup-heute.html `.opt span`).
        var subtitle: String {
            switch self {
            case .active:  return String(localized: "Normal training", comment: "ActivityStatus sheet subtitle")
            case .sick:    return String(localized: "Recovering from an illness", comment: "ActivityStatus sheet subtitle")
            case .injured: return String(localized: "No training suggestions", comment: "ActivityStatus sheet subtitle")
            case .onBreak: return String(localized: "Deliberately no training", comment: "ActivityStatus sheet subtitle")
            }
        }

        /// SF Symbol for the status chip / sheet row icon.
        var symbolName: String {
            switch self {
            case .active:  return "bolt.fill"
            case .sick:    return "bed.double.fill"
            case .injured: return "bandage.fill"
            case .onBreak: return "beach.umbrella.fill"
            }
        }
    }

    var state: State
    var validUntil: Date?   // nil = "bis geändert"
    var setAt: Date

    static let active = ActivityStatus(state: .active, validUntil: nil, setAt: .distantPast)

    /// True for the three exception states — training suggestions (propose_plan, suggestion cards) are
    /// suppressed for as long as this is true. Wiring the actual suppression into the coach tool-call
    /// path is a follow-up; this flag is the single source of truth callers should gate on.
    var suppressesTrainingSuggestions: Bool { state != .active }

    /// The duration choices offered when the user sets a non-active status, and how each maps to a
    /// concrete `validUntil`. Spec §1: "Heute" → end of today, "3 Tage" → +3 days, "Diese Woche" → end
    /// of the current calendar week, "Eigenes Datum" → the chosen date, "Bis geändert" → nil.
    enum Duration: Equatable {
        case today, threeDays, thisWeek, custom(Date), untilChanged

        func validUntil(from now: Date, calendar: Calendar = .current) -> Date? {
            switch self {
            case .today:
                let startOfToday = calendar.startOfDay(for: now)
                return calendar.date(byAdding: .day, value: 1, to: startOfToday)
            case .threeDays:
                return calendar.date(byAdding: .day, value: 3, to: now)
            case .thisWeek:
                guard let interval = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
                return interval.end
            case .custom(let date):
                return date
            case .untilChanged:
                return nil
            }
        }
    }

    /// Applies the automatic fallback rule (spec §1: "Beim Erreichen von validUntil fällt der Status
    /// automatisch auf .active zurück. Kein Reminder, kein Nachfragen — stiller Reset."). Pure — callers
    /// that read via `ActivityStatusStore.load` get the resolved value and the store persists it.
    func resolved(now: Date = Date()) -> ActivityStatus {
        guard state != .active, let validUntil, now >= validUntil else { return self }
        return .active
    }
}

/// UserDefaults-backed persistence. Injectable `UserDefaults` for test isolation, matching the repo's
/// `UserDefaults(suiteName:)` test convention (e.g. StrandTests/CaffeineDecayTests.swift).
enum ActivityStatusStore {
    static let key = "today.activityStatus"

    /// Reads the persisted status, applies the silent fallback, and — if the fallback changed anything —
    /// writes the resolved `.active` value back so a stale non-active state never survives past the next
    /// read even if nothing else re-saves it.
    static func load(from d: UserDefaults = .standard, now: Date = Date()) -> ActivityStatus {
        guard let data = d.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ActivityStatus.self, from: data) else {
            return .active
        }
        let resolved = decoded.resolved(now: now)
        if resolved != decoded { save(resolved, to: d) }
        return resolved
    }

    static func save(_ status: ActivityStatus, to d: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(status) else { return }
        d.set(data, forKey: key)
    }
}
