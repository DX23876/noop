import SwiftUI
import StrandDesign

/// Route rows for the active workout: distance and pace as live metric rows, plus one status line for the
/// GPS state. The status stays visible while paused and when permission or signal is missing, so a
/// GPS-labelled start never fails silently.
struct LiveWorkoutRouteCard: View {
    @ObservedObject var recorder: GpsWorkoutRecorder
    let isEnabled: Bool
    @EnvironmentObject private var app: AppModel
    @Environment(\.openURL) private var openURL
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""

    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                  override: distanceSystemRaw)
    }

    var body: some View {
        if isEnabled {
            let captured = recorder.pointCount > 0
            let distance = LiveWorkoutMetricRow.split(
                UnitFormatter.distanceFromMeters(recorder.distanceM, system: distanceUnitSystem))
            LiveWorkoutMetricRow(value: captured ? distance.value : "—",
                                 unit: captured ? distance.unit : (distanceUnitSystem == .imperial ? "mi" : "km"),
                                 caption: nil,
                                 symbol: "point.topleft.down.to.point.bottomright.curvepath.fill",
                                 tint: captured ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let speed = app.workoutDisplayedSpeedMps
                let elapsed = app.activeWorkout?.elapsed(at: context.date) ?? 0
                let average = elapsed > 0 && recorder.distanceM > 0 ? recorder.distanceM / elapsed : nil
                motionRow(speed: speed, caption: String(localized: "Current · last 30 seconds"))
                motionRow(speed: average, caption: String(localized: "Workout average"))
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in statusLine(at: context.date) }
        }
    }

    private func motionRow(speed: Double?, caption: String) -> some View {
        let usesSpeed = WorkoutCatalog.usesSpeedReadout(for: app.activeWorkout?.sport ?? "")
        let formatted = usesSpeed
            ? (UnitFormatter.speedFromKilometersPerHour(speed.map { $0 * 3.6 }, system: distanceUnitSystem) ?? "—")
            : UnitFormatter.paceFromSecPerKm(speed.map { 1000 / $0 }, system: distanceUnitSystem)
        let parts = LiveWorkoutMetricRow.split(formatted)
        return LiveWorkoutMetricRow(value: parts.value, unit: parts.unit, caption: caption,
                                    symbol: "speedometer", tint: speed == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
    }

    private func statusLine(at now: Date) -> some View {
        let status = status(at: now)
        return HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.tint)
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text(status.title)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(status.detail)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                #if os(iOS)
                if recorder.state == .denied {
                    Button("Open Settings", action: openSettings)
                        .font(StrandFont.footnote.weight(.semibold))
                        .tint(StrandPalette.accent)
                        .padding(.top, NoopMetrics.space1)
                }
                #endif
            }
            Spacer(minLength: 0)
            if recorder.state == .acquiring || recorder.state == .requestingPermission {
                ProgressView().controlSize(.small).tint(status.tint)
            }
        }
        .font(StrandFont.footnote)
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .combine)
    }

    private func status(at now: Date) -> (symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey, tint: Color) {
        if recorder.state == .recording, !recorder.isStationary,
           recorder.lastLocationAt.map({ now.timeIntervalSince($0) > 10 }) ?? true {
            return ("exclamationmark.triangle.fill", "GPS interrupted",
                    "Waiting for location updates to resume.", StrandPalette.statusWarningForeground)
        }
        return switch recorder.state {
        case .idle:
            ("location", "Route ready", "GPS starts with the workout.", StrandPalette.textSecondary)
        case .requestingPermission:
            ("location.circle", "Allow location access", "Grant access to record this route.", StrandPalette.accent)
        case .acquiring:
            ("location.circle.fill", "Finding GPS", "Workout time is already recording.", StrandPalette.accent)
        case .recording:
            ("location.fill", "Route recording", "Distance and pace update as you move.", StrandPalette.statusPositive)
        case .paused:
            ("pause.circle.fill", "Route paused", "No new route points are recorded while paused.", StrandPalette.statusWarningForeground)
        case .denied:
            ("location.slash.fill", "Location access is off",
             recorder.pointCount > 1 ? "Only the captured route will be saved." : "The workout will be saved without a route.",
             StrandPalette.statusWarningForeground)
        case .unavailable:
            ("location.slash", "GPS unavailable",
             recorder.pointCount > 1 ? "Only the captured route will be saved." : "The workout will be saved without a route.",
             StrandPalette.statusWarningForeground)
        case .failed:
            ("exclamationmark.triangle.fill", "GPS interrupted", "Waiting for location updates to resume.", StrandPalette.statusWarningForeground)
        }
    }

    #if os(iOS)
    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
    #endif
}
