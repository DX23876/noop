import Foundation

/// Opt-in Today capabilities for the Trends and Overview dashboards. Core reference-screen content is
/// intentionally absent from this list; all thirteen cases start off, so enabling nothing leaves each
/// reference-matched layout unchanged. Trends and Overview keep separate keys, since a section toggled
/// on in one style must not silently appear in the other.
enum DashboardExtraSection: String, CaseIterable, Identifiable {
    case liveSession
    case momentum
    case goals
    case keyMetrics
    case journal
    case menstrualCycle
    case energyDetail
    case workoutsList
    case heartRate
    case recoveryVitals
    case yourCards
    case dataSources
    case addedCards

    var id: String { rawValue }

    var label: String {
        switch self {
        case .liveSession:   return String(localized: "Live session")
        case .momentum:      return "Momentum"
        case .goals:         return String(localized: "Goals")
        case .keyMetrics:    return String(localized: "More metrics")
        case .journal:       return String(localized: "Journal")
        case .menstrualCycle: return String(localized: "Menstrual cycle")
        case .energyDetail:  return String(localized: "Energy breakdown")
        case .workoutsList:  return String(localized: "More workouts")
        case .heartRate:     return String(localized: "Heart rate")
        case .recoveryVitals:return String(localized: "Recovery vitals")
        case .yourCards:     return String(localized: "Your cards")
        case .dataSources:   return String(localized: "Data sources")
        case .addedCards:    return String(localized: "Added cards")
        }
    }

    var detail: String {
        switch self {
        case .liveSession:   return String(localized: "Start a focused live session from your dashboard.")
        case .momentum:      return String(localized: "Your full Momentum recommendation and feed.")
        case .goals:         return String(localized: "This week's goal progress and today's actions.")
        case .keyMetrics:    return String(localized: "Additional daily metrics beyond the dashboard summary.")
        case .journal:       return String(localized: "Your last 7 days of journal entries.")
        case .menstrualCycle: return String(localized: "Cycle phase, if cycle tracking is on.")
        case .energyDetail:  return String(localized: "Basal, active and total burn, not just the total.")
        case .workoutsList:  return String(localized: "The last few workouts, not only the most recent.")
        case .heartRate:     return String(localized: "A compact heart-rate timeline for today.")
        case .recoveryVitals:return String(localized: "HRV, resting heart rate, breathing and blood oxygen.")
        case .yourCards:     return String(localized: "Your selected dashboard cards in this layout.")
        case .dataSources:   return String(localized: "Sync and data-source status.")
        case .addedCards:    return String(localized: "Selected sleep cards from the Sleep tab.")
        }
    }

    /// `dashboard` distinguishes Trends from Overview so each keeps its own on/off state.
    static func storageKey(_ section: DashboardExtraSection, dashboard: String) -> String {
        "\(dashboard).extra.\(section.rawValue)"
    }
}

/// The dashboard editor deliberately owns a separate layout from Classic/Liquid Today: the two
/// reference layouts have different fixed building blocks, but users can still reorder or hide every
/// block. Extras begin hidden; moving one to "Shown" is its opt-in action.
enum DashboardLayoutSection: String, CaseIterable, Identifiable {
    case coach, hero, trendsChart, metricStrip, activity
    case overview, focus, health
    case liveSession, momentum, goals, keyMetrics, energyDetail, workoutsList, heartRate, recoveryVitals, yourCards, menstrualCycle, journal, dataSources, addedCards

    var id: String { rawValue }
    /// An "extra" starts hidden (see `DashboardLayoutPrefs.hidden`). Momentum is deliberately NOT one:
    /// it is the app's "what matters right now" surface, and an unset dashboard that hides it reproduces
    /// exactly the gap this closes.
    var isExtra: Bool {
        switch self {
        case .coach, .hero, .trendsChart, .metricStrip, .activity, .overview, .focus, .health, .momentum: false
        default: true
        }
    }
    var title: String {
        switch self {
        case .coach: return String(localized: "Coach")
        case .hero: return String(localized: "Charge / Effort / Rest")
        case .trendsChart: return String(localized: "Your trends")
        case .metricStrip: return String(localized: "Key Metrics")
        case .activity: return String(localized: "Recent activity")
        case .overview: return String(localized: "Today at a glance")
        case .focus: return String(localized: "Today's focus")
        case .health: return String(localized: "Your health")
        default: return DashboardExtraSection(rawValue: rawValue)?.label ?? rawValue
        }
    }
    var icon: String {
        switch self {
        case .coach: return "sparkles"
        case .hero: return "gauge.with.dots.needle.67percent"
        case .trendsChart: return "chart.xyaxis.line"
        case .metricStrip, .keyMetrics: return "square.grid.2x2"
        case .activity, .workoutsList: return "figure.run"
        case .overview: return "circle.grid.3x3"
        case .focus: return "rectangle.3.group"
        case .health, .recoveryVitals: return "heart.text.square"
        case .liveSession: return "figure.run.circle"
        case .momentum: return "sparkles"
        case .goals: return "target"
        case .energyDetail: return "flame.fill"
        case .heartRate: return "waveform.path.ecg"
        case .yourCards: return "rectangle.stack"
        case .menstrualCycle: return "drop.degreesign"
        case .journal: return "book.closed"
        case .dataSources: return "externaldrive.connected.to.line.below"
        case .addedCards: return "rectangle.stack.badge.plus"
        }
    }
    static func defaultOrder(for dashboard: String) -> [Self] {
        let extras: [Self] = [.liveSession, .goals, .keyMetrics, .energyDetail, .workoutsList, .heartRate, .recoveryVitals, .yourCards, .menstrualCycle, .journal, .dataSources, .addedCards]
        // Overview leads with the Coach card too: it had no Coach surface at all beyond the header icon,
        // while Trends has carried one since it shipped. Momentum sits directly under each dashboard's
        // own blocks: it is the app's "what matters right now" surface, and leaving it an opt-in extra
        // was half of why it never appeared here (the other half was that nothing published a feed).
        // All of these are reorderable and hideable like any other non-extra block.
        return dashboard == "trends"
            ? [.coach, .hero, .trendsChart, .metricStrip, .activity, .momentum] + extras
            : [.coach, .overview, .focus, .health, .momentum] + extras
    }
}

enum DashboardLayoutPrefs {
    static let noneHiddenSentinel = "__none__"
    static func orderKey(_ dashboard: String) -> String { "\(dashboard).dashboard.sectionOrder" }
    static func hiddenKey(_ dashboard: String) -> String { "\(dashboard).dashboard.hiddenSections" }
    static func order(_ raw: String, dashboard: String) -> [DashboardLayoutSection] {
        let defaults = DashboardLayoutSection.defaultOrder(for: dashboard)
        let decoded = raw.split(separator: ",").compactMap { DashboardLayoutSection(rawValue: String($0)) }
        var result = decoded.filter { defaults.contains($0) }
        for item in defaults where !result.contains(item) { result.append(item) }
        return result
    }
    static func hidden(_ raw: String, dashboard: String) -> Set<DashboardLayoutSection> {
        if raw == noneHiddenSentinel { return [] }
        if raw.isEmpty { return Set(DashboardLayoutSection.defaultOrder(for: dashboard).filter(\.isExtra)) }
        return Set(raw.split(separator: ",").compactMap { DashboardLayoutSection(rawValue: String($0)) })
    }
    static func encode(_ items: [DashboardLayoutSection]) -> String { items.map(\.rawValue).joined(separator: ",") }
    static func encodeHidden(_ items: [DashboardLayoutSection]) -> String {
        items.isEmpty ? noneHiddenSentinel : encode(items)
    }
}
