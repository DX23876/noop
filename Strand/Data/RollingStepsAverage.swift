import Foundation
import SwiftUI
import StrandDesign
import WhoopStore
import StrandCore

/// Calendar-day window, never 30 observed rows. Missing observations are not zero.
struct RollingStepsAverage: Equatable {
    let mean: Double?
    let observedDays: Int

    static func startDay(ending day: String) -> String? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let end = formatter.date(from: day),
              let start = calendar.date(byAdding: .day, value: -29, to: end) else { return nil }
        return formatter.string(from: start)
    }

    static func calculate(readings: [(day: String, value: Double)], ending day: String) -> Self {
        guard let start = startDay(ending: day) else { return .init(mean: nil, observedDays: 0) }
        var byDay: [String: Double] = [:]
        for reading in readings where reading.day >= start && reading.day <= day
            && reading.value.isFinite && reading.value >= 0 {
            byDay[reading.day] = reading.value
        }
        return .init(mean: byDay.isEmpty ? nil : byDay.values.reduce(0, +) / Double(byDay.count),
                     observedDays: byDay.count)
    }
}

extension Repository {
    /// Shared by the detail and rolling tile: measured strap, phone import, then strap estimate
    /// (`MetricResolver.resolvedSteps`).
    func resolvedSteps(from: String, to: String) async -> MetricSeriesResolution {
        await MetricResolver.resolvedSteps(store: await storeHandle(), actualWhoopSource: deviceId, from: from, to: to)
    }
}

/// Loads only when explicitly enabled. Task identity follows the selected day and repository refresh.
struct RollingStepsAverageCard: View {
    let day: String
    /// The Card-transparency setting, as the caller resolved it; 1 (opaque) where a screen has none.
    var surfaceOpacity: Double = 1
    /// Liquid Today draws "Your cards" with `TodayDashboardRow` on `TodayCardSurface`; this card joins
    /// them there instead of keeping its own layout. Classic keeps the original.
    var dashboardRowStyle = false
    @EnvironmentObject private var repo: Repository
    @State private var result: RollingStepsAverage?
    @State private var resultDay: String?

    var body: some View {
        let current = resultDay == day ? result : nil
        let meanText = current?.mean.map {
            $0.formatted(.number.locale(AppLanguage.activeLocale).precision(.fractionLength(0)))
        } ?? "—"
        let daysText = current.map { String(localized: "\($0.observedDays) of 30 days") } ?? "—"
        NavigationLink(value: TabRoute.metricSourced(key: "steps", source: MetricCatalog.combinedStepsSource)) {
            if dashboardRowStyle {
                TodayDashboardRow(
                    systemImage: DashboardCard.stepsAverage30.icon,
                    title: DashboardCard.stepsAverage30.title,
                    subtitle: daysText,
                    value: meanText,
                    tint: StrandPalette.metricCyan,
                    progress: current.map { Double($0.observedDays) / 30 },
                    isPlaceholder: meanText == "—"
                )
                .padding(.horizontal, NoopMetrics.space4)
                .padding(.vertical, NoopMetrics.space3)
                .contentShape(Rectangle())
                .background(TodayCardSurface(tint: StrandPalette.metricCyan, surfaceOpacity: surfaceOpacity))
            } else {
            HStack(spacing: 12) {
                Image(systemName: DashboardCard.stepsAverage30.icon)
                    .foregroundStyle(StrandPalette.metricCyan)
                VStack(alignment: .leading, spacing: 4) {
                    Text(DashboardCard.stepsAverage30.title)
                        .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Text(daysText)
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 8)
                Text(meanText)
                    .font(StrandFont.number(20)).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(14)
            .background(NoopPanelSurface(tint: StrandPalette.metricCyan, cornerRadius: 20,
                                         surfaceOpacity: surfaceOpacity))
            }
        }
        .buttonStyle(.plain)
        .task(id: "\(day)|\(repo.refreshSeq)") {
            guard let start = RollingStepsAverage.startDay(ending: day) else { return }
            let readings = await repo.resolvedSteps(from: start, to: day)
            guard !Task.isCancelled else { return }
            result = RollingStepsAverage.calculate(readings: readings.values, ending: day)
            resultDay = day
        }
    }
}
