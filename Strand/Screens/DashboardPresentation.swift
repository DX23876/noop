import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Data identity includes corrections to existing rows, source switches and profile changes.
struct DashboardLoadKey: Hashable {
    let revision: SleepPresentationRevision
    let selection: String
    let preferences: String
    let profile: String
    /// Readiness reads the Training Load lanes, which land after the daily rows (`Repository.readinessLoadContext`).
    let readinessLoad: ReadinessLoadContext?
    @MainActor init(repo: Repository, selection: String, preferences: String, profile: ProfileStore) {
        revision = SleepPresentationRevision(repo: repo)
        readinessLoad = repo.readinessLoadContext
        self.selection = selection; self.preferences = preferences
        self.profile = "\(profile.dateOfBirth)-\(profile.sex)-\(profile.weightKg)-\(profile.heightCm)-\(profile.hrMax)-\(profile.stepTicksPerStep)"
    }
}

/// One day-specific Rest value shared by Sleep and every Today design. A manual correction updates the
/// daily row before background analysis rewrites metricSeries, so dashboards must not prefer that stale
/// series point during the interim.
enum DashboardRestScore {
    static func value(day: String, days: [DailyMetric],
                      importedSleep: [String: ImportedSleepFigures]) -> Double? {
        if let imported = importedSleep[day]?.performancePct { return imported }
        guard let daily = days.last(where: { $0.day == day }) else { return nil }
        return AnalyticsEngine.Rest.composite(daily: daily)
    }
}

/// A high-frequency AppModel publisher has no dependency edge into the dashboard's parent body.
struct DashboardCycleReadout: View {
    var compact = false
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack {
            Text(model.cyclePhase.map { DashboardMomentum.cyclePhaseTitle($0.phase) }
                 ?? String(localized: "Learning your pattern"))
                .font(compact ? StrandFont.footnote : StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            if let result = model.cyclePhase, let lo = result.cycleDayLow, let hi = result.cycleDayHigh {
                (lo == hi ? Text("~day \(lo)") : Text("~day \(lo)-\(hi)"))
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }
}

private struct DashboardActiveKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var dashboardIsActive: Bool {
        get { self[DashboardActiveKey.self] }
        set { self[DashboardActiveKey.self] = newValue }
    }
}

private struct DashboardAnimationVisibility: ViewModifier {
    @Binding var visible: Bool
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content
                .onAppear { visible = true }
                .onDisappear { visible = false }
                .onScrollVisibilityChange(threshold: 0.01) { value in
                    Task { @MainActor in if visible != value { visible = value } }
                }
        } else {
            content.onAppear { visible = true }.onDisappear { visible = false }
        }
    }
}
extension View {
    func dashboardAnimationVisibility(_ visible: Binding<Bool>) -> some View {
        modifier(DashboardAnimationVisibility(visible: visible))
    }
}

/// A tapped Effort readout keeps its day even when that day has no computed value.
/// Analysis migration required: no. This gates presentation; scoring and persisted values are unchanged.
struct DashboardEffortReadout: Hashable {
    let day: String
    let value: Double?

    static func resolve(day: String, storedDay: String?, stored: Double?,
                        live: DashboardEffortReadout?, currentDay: String, isToday: Bool = true) -> Self {
        let liveValue = isToday && day == currentDay && live?.day == day ? live?.value : nil
        return Self(day: day, value: StrainScorer.effectiveEffort(
            live: liveValue, stored: storedDay == day ? stored : nil))
    }

    /// Explicitly missing selected-day values never fall back to a historical point.
    var point: (day: String, value: Double)? { value.map { (day, $0) } }
}

/// Restart the lightweight Effort read on data/profile/day changes and when Today becomes active.
struct DashboardEffortLoadKey: Hashable {
    let load: DashboardLoadKey
    let active: Bool
}
