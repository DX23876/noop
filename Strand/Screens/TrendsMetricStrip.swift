import SwiftUI
import StrandDesign
import WhoopStore

/// Four bare number/unit/label columns, no card chrome per item (unlike a `DashboardCard` row, which
/// carries an icon tile + subtitle + chevron) — the visually lighter strip the Trends dashboard reference
/// shows under its trend chart. Reads the same `DashboardCard` catalog for identity (title/icon/tint),
/// so a slot picked in Settings is titled and coloured identically to the "Your cards" row of the same
/// metric on Classic Today.
///
/// Deliberately simpler than `TodayView`'s own `dashboardValue(_:)`: this reads today's row directly
/// (measured value or "—"), without that function's many carry-forward / demo-harness / experimental
/// fallbacks — those exist to keep several years of edge cases honest on a screen that has loaded all
/// of their supporting state, which this lightweight strip does not. A quiet day here reads "—" rather
/// than inventing a stale carry.
struct TrendsMetricStrip: View {
    let cards: [DashboardCard]
    let day: DailyMetric?
    let appleDay: AppleDaily?
    let resolvedValue: ((DashboardCard) -> String)?

    init(cards: [DashboardCard], day: DailyMetric?, appleDay: AppleDaily?,
         resolvedValue: ((DashboardCard) -> String)? = nil) {
        self.cards = cards
        self.day = day
        self.appleDay = appleDay
        self.resolvedValue = resolvedValue
    }

    var body: some View {
        NoopCard(padding: NoopMetrics.cardPadding) {
            HStack(alignment: .top, spacing: 0) {
                ForEach(cards) { card in
                    NavigationLink(value: card.detailRoute(day: day, appleDay: appleDay)) {
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: card.icon)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(TrendsMetricStrip.tint(card))
                                Text(card.title)
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(resolvedValue?(card)
                                     ?? TrendsMetricStrip.valueText(card, day: day, appleDay: appleDay))
                                    .font(StrandFont.number(20))
                                    .foregroundStyle(StrandPalette.textPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                if !card.unit.isEmpty {
                                    Text(card.unit)
                                        .font(StrandFont.caption)
                                        .foregroundStyle(StrandPalette.textTertiary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    static func tint(_ card: DashboardCard) -> Color {
        switch card {
        case .hrv:                    return StrandPalette.metricPurple
        case .restingHr:              return StrandPalette.metricRose
        case .respiratory:            return StrandPalette.metricCyan
        case .steps:                  return StrandPalette.metricCyan
        case .bloodOxygen:            return StrandPalette.metricCyan
        case .skinTemp, .calories:    return StrandPalette.metricAmber
        case .weight:                 return StrandPalette.metricRose
        case .sleep:                  return StrandPalette.restColor
        case .stress:                 return StrandPalette.effortColor
        case .fitnessAge, .vo2max, .vitality, .coupled: return StrandPalette.chargeColor
        case .hydration:              return StrandPalette.metricCyan
        }
    }

    /// Today's own value only — see the type doc for why this is intentionally simpler than
    /// `TodayView.dashboardValue(_:)`.
    static func valueText(_ card: DashboardCard, day: DailyMetric?, appleDay: AppleDaily?) -> String {
        switch card {
        case .hrv:         return day?.avgHrv.map { "\(Int($0.rounded()))" } ?? "—"
        case .restingHr:   return day?.restingHr.map { "\($0)" } ?? "—"
        case .respiratory: return day?.respRateBpm.map {
            String(format: "%.1f", locale: AppLanguage.activeLocale, $0)
        } ?? "—"
        case .steps:
            let value = day?.steps ?? appleDay?.steps
            return value.map { "\($0)" } ?? "—"
        case .bloodOxygen: return day?.spo2Pct.map { "\(Int($0.rounded()))%" } ?? "—"
        case .skinTemp:    return day?.skinTempDevC.map {
            String(format: "%+.1f°", locale: AppLanguage.activeLocale, $0)
        } ?? "—"
        case .sleep:
            guard let m = day?.totalSleepMin else { return "—" }
            return String(localized: "\(Int(m) / 60)h \(Int(m) % 60)m")
        case .calories:    return day?.activeKcalEst.map { "\(Int($0.rounded()))" } ?? "—"
        case .stress:      return day?.strain.map { "\(Int($0.rounded()))" } ?? "—"
        case .fitnessAge, .vo2max, .vitality, .hydration, .weight, .coupled:
            // These need state this lightweight strip does not load (profile age, a hydration goal, a
            // weight-trend summary). Honest "—" rather than a guess; pick a different slot for these
            // today, or wire a dedicated resolver if a slot needs one later.
            return "—"
        }
    }
}
