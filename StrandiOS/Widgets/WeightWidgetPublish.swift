#if os(iOS)
import Foundation
import WidgetKit
import StrandAnalytics
import StrandDesign
import StrandCore

/// Publishes the weight widgets' payload from the one `WeightTracker` snapshot the weight page shows, worded in the
/// wearer's language and unit. Called when the page loads and after every weigh-in; writes and reloads only when
/// something the widgets draw changed.
@MainActor
enum WeightWidgetPublisher {
    /// Builds the snapshot the page would show and publishes it: after a weigh-in and when the app comes to the front.
    static func refresh(repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        let plan = DietPlan.decode(UserDefaults.standard.string(forKey: DietPlan.storageKey))
        let snapshot = await WeightTrackerPreparation.snapshot(store: store, reader: repo.storeReader(store),
                                                               goals: CoachGoalStore.shared, prefs: GoalPreferences.standard,
                                                               plan: plan)
        publish(snapshot)
    }

    /// `nil` means the store answered and holds no weigh-ins: the widgets and Today's tile then drop what they
    /// showed rather than keep a deleted weight on the home screen. Callers that could not reach the store do not
    /// publish at all.
    static func publish(_ s: WeightTracker.Snapshot?, now: Date = Date()) {
        guard let s else {
            if WeightWidgetSnapshot.clear() {
                for kind in WeightWidgetSnapshot.kinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
            }
            return
        }
        let units = UnitSystem(rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        let unit = units == .imperial ? "lb" : "kg"
        func number(_ kg: Double) -> String {
            (units == .imperial ? kg * UnitFormatter.poundsPerKilogram : kg).formatted(.number.precision(.fractionLength(1)))
        }
        func signed(_ kg: Double) -> String {
            let text = number(abs(kg))
            return kg > 0.05 ? "+" + text : kg < -0.05 ? "−" + text : text
        }
        let rate = s.forecast.rateKgPerWeek ?? s.rates.currentKgPerWeek
        let rateLine = rate.map { String(localized: "\(signed($0)) \(unit) a week") }
        let locale = AppLanguage.activeLocale
        let thisMonth = s.months.first
        let previous = s.months.dropFirst().first
        var month: [WeightWidgetSnapshot.Figure] = []
        if let m = thisMonth, m.enough {
            if let low = m.low { month.append(.init(label: String(localized: "Lowest"), value: number(low.kg))) }
            if let avg = m.averageKg { month.append(.init(label: String(localized: "Average"), value: number(avg))) }
            if let vs = m.vsPreviousKg, let p = previous {
                month.append(.init(label: String(localized: "vs \(p.start.formatted(.dateTime.month(.abbreviated).locale(locale)))"),
                                   value: signed(vs)))
            }
            if let change = m.trendChangeKg { month.append(.init(label: String(localized: "Trend change"), value: signed(change))) }
        }
        var figures: [WeightWidgetSnapshot.Figure] = [
            .init(label: String(localized: "Last"), value: number(s.latest.kg)),
            .init(label: String(localized: "Trend"), value: number(s.trendKg)),
        ]
        if let r = s.rates.currentKgPerWeek { figures.append(.init(label: String(localized: "Per week"), value: signed(r))) }
        if let low = s.week?.low { figures.append(.init(label: String(localized: "Week low"), value: number(low.kg))) }
        if let m = s.milestones {
            figures.append(.init(label: String(localized: "Progress"), value: "\(Int((m.progress * 100).rounded())) %"))
            if let next = m.next { figures.append(.init(label: String(localized: "Next stop"), value: number(next))) }
        } else if let month30 = s.changes.first(where: { $0.days == 30 }) {
            figures.append(.init(label: String(localized: "30 days"), value: signed(month30.kg)))
        }
        let cutoff = now.addingTimeInterval(-30 * 86_400)
        let line = s.trend.filter { $0.date >= cutoff }.map { units == .imperial ? $0.kg * UnitFormatter.poundsPerKilogram : $0.kg }
        let events = s.events.filter { $0.phase == .upcoming }.compactMap { e -> WeightWidgetSnapshot.Event? in
            guard let date = WeightSeries.date(forDay: e.event.day) else { return nil }
            return .init(id: e.event.id, name: e.event.name, date: date, expected: e.predictedKg.map(number),
                         rateLine: rate.map { String(localized: "at \(signed($0)) \(unit) a week") })
        }
        let snapshot = WeightWidgetSnapshot(
            unit: unit, trend: number(s.trendKg), trendSettled: s.trendSettled, rateLine: rateLine,
            latest: number(s.latest.kg), latestDate: s.latest.date,
            monthLabel: (thisMonth?.start ?? now).formatted(.dateTime.month(.wide).locale(locale)),
            month: month, figures: figures, line: line, events: events, updated: now)
        if snapshot.save() {
            for kind in WeightWidgetSnapshot.kinds { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
        }
    }
}
#endif
