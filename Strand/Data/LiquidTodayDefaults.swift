import Foundation

// MARK: - Liquid Today's fresh layout (2026-10 redesign)
//
// Classic and Liquid Today share the same `today.*` preference keys, so a layout a user saved on one
// shows on the other. What they no longer share is the FRESH default: Liquid leads with its hero and
// a calmer stack, Classic keeps its long-standing order. The distinction lives only here, in how an
// UNSET key reads, so no stored value is ever migrated or rewritten:
//
// - A key that has never been written reads as Liquid's default on Liquid and Classic's on Classic.
// - The moment the user saves the corresponding group in Customise, the stored value wins on both.
//
// Display-only. Analysis migration required: no.

/// Whether a Key Metrics list came from the user or from a default. The difference decides what an empty
/// tile does: an automatic one without a value is left out, an explicitly chosen one stays as "—".
struct LiquidKeyMetricSelection: Equatable {
    let metrics: [KeyMetric]
    let isExplicit: Bool
}

enum LiquidTodayDefaults {
    /// Hero, then the day's story (Momentum, Goals), the numbers, energy, workouts, live heart rate while
    /// a strap streams, and the user's own cards. The self-gating extras follow; every section a later
    /// version adds still back-fills through `TodayLayoutPrefs.decodeOrder` once a layout is saved.
    static let sectionOrder: [TodaySection] = [
        .hero, .synthesis, .goals, .keyMetrics, .trainingLoad, .energy, .workouts, .heartRate, .yourCards,
        .coach, .liveSession, .menstrualCycle, .journal, .addedCards, .recoveryVitals, .dataSources,
    ]

    /// Recovery Vitals stays available and editable, but starts hidden: HRV, resting heart rate and
    /// respiration are already Key Metrics.
    static let hiddenSections: [TodaySection] = [.recoveryVitals]

    /// Never rendered by Liquid Today, whatever a saved layout says. Data Sources keeps its route in
    /// Settings; the Arrange sheet opened from Liquid does not offer it.
    static let excludedSections: Set<TodaySection> = [.dataSources]

    /// Calories is left out because the Energy card already leads with the same total, and Charge,
    /// Effort and Rest because the hero rings directly above already show them. Only an untouched layout
    /// uses this; an explicit selection keeps every tile it names.
    static let keyMetrics: [KeyMetric] = KeyMetric.defaultOrder.filter {
        ![.calories, .charge, .effort, .rest].contains($0)
    }

    static let keyMetricsColumns = 2

    static let dashboardCards: [DashboardCard] = [.stress, .fitnessAge, .vitality]

    // MARK: Sections

    /// A layout counts as customised once either section key has been written. `hiddenRaw` is compared
    /// with nil, not with "", because unhiding everything writes an explicit empty string.
    static func isLayoutCustomised(orderRaw: String?, hiddenRaw: String?) -> Bool {
        let order = (orderRaw ?? "").trimmingCharacters(in: .whitespaces)
        return !order.isEmpty || hiddenRaw != nil
    }

    /// Full order (visible and hidden) and hidden set as Liquid presents them, for rendering and for
    /// seeding the editor.
    static func layout(orderRaw: String?, hiddenRaw: String?) -> (order: [TodaySection], hidden: Set<TodaySection>) {
        let order: [TodaySection]
        let hidden: Set<TodaySection>
        if isLayoutCustomised(orderRaw: orderRaw, hiddenRaw: hiddenRaw) {
            order = TodayLayoutPrefs.decodeOrder(orderRaw ?? "")
            hidden = Set(TodayLayoutPrefs.decodeHidden(hiddenRaw ?? ""))
        } else {
            order = sectionOrder
            hidden = Set(hiddenSections)
        }
        return (order.filter { !excludedSections.contains($0) }, hidden)
    }

    static func visibleSections(orderRaw: String?, hiddenRaw: String?) -> [TodaySection] {
        let resolved = layout(orderRaw: orderRaw, hiddenRaw: hiddenRaw)
        return resolved.order.filter { !resolved.hidden.contains($0) }
    }

    // MARK: Key Metrics

    static func keyMetricSelection(_ raw: String?) -> LiquidKeyMetricSelection {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return LiquidKeyMetricSelection(metrics: keyMetrics, isExplicit: false) }
        return LiquidKeyMetricSelection(metrics: KeyMetricPrefs.decodeEnabled(trimmed), isExplicit: true)
    }

    /// Tiles with a value first, in the selection's own order. Empty tiles follow only when the user chose
    /// them; an automatic selection drops them so the grid never fills with dashes.
    static func arrangedKeyMetrics(_ selection: LiquidKeyMetricSelection,
                                   hasValue: (KeyMetric) -> Bool) -> [KeyMetric] {
        let populated = selection.metrics.filter(hasValue)
        guard selection.isExplicit else { return populated }
        return populated + selection.metrics.filter { !hasValue($0) }
    }

    /// Columns for the grid: the stored choice when there is one, two otherwise, one at accessibility
    /// text sizes so labels are never clipped.
    static func keyMetricsColumns(_ raw: Int?, accessibilitySize: Bool) -> Int {
        guard !accessibilitySize else { return 1 }
        return raw.map(KeyMetricPrefs.columns) ?? keyMetricsColumns
    }

    // MARK: Your Cards

    static func dashboardCards(_ raw: String?) -> [DashboardCard] {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? dashboardCards : DashboardCardPrefs.decodeEnabled(trimmed)
    }

    // MARK: Workouts

    /// How many of the newest workouts the grouped card lists; `All` opens the full history.
    static let workoutRows = 5

    /// The Effort band word for a stored 0–100 Effort, uppercased for a row's overline: the same edges as
    /// the app's other Effort words (on 0–21: Light below 6, Moderate from 6, Strenuous from 10, High from
    /// 14), whichever display scale is chosen. nil when there is no Effort.
    static func effortBandWord(stored: Double?) -> String? {
        guard let stored, stored.isFinite else { return nil }
        let word: String
        switch stored * 21 / 100 {
        case ..<6:  word = String(localized: "Light")
        case ..<10: word = String(localized: "Moderate")
        case ..<14: word = String(localized: "Strenuous")
        default:    word = String(localized: "High")
        }
        return word.uppercased(with: AppLanguage.activeLocale)
    }
}
