import SwiftUI
import StrandDesign

/// Route rows for the active workout: distance and pace as live metric rows, plus one status line for the
/// GPS state. The status stays visible while paused and when permission or signal is missing, so a
/// GPS-labelled start never fails silently.
struct LiveWorkoutRouteCard: View {
    @ObservedObject var recorder: GpsWorkoutRecorder
    let isEnabled: Bool
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
            let pace = LiveWorkoutMetricRow.split(
                UnitFormatter.paceFromSecPerKm(recorder.paceSecPerKm, system: distanceUnitSystem))
            LiveWorkoutMetricRow(value: captured ? distance.value : "—",
                                 unit: captured ? distance.unit : (distanceUnitSystem == .imperial ? "mi" : "km"),
                                 caption: nil,
                                 symbol: "point.topleft.down.to.point.bottomright.curvepath.fill",
                                 tint: captured ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            LiveWorkoutMetricRow(value: pace.unit.isEmpty ? "—" : pace.value,
                                 unit: pace.unit.isEmpty ? (distanceUnitSystem == .imperial ? "/mi" : "/km") : pace.unit,
                                 caption: nil,
                                 symbol: "speedometer",
                                 tint: pace.unit.isEmpty ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            statusLine
        }
    }

    private var statusLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
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

    private var status: (symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey, tint: Color) {
        switch recorder.state {
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
            ("location.slash.fill", "Location access is off", "The workout will be saved without a route.", StrandPalette.statusWarningForeground)
        case .unavailable:
            ("location.slash", "GPS unavailable", "The workout will be saved without a route.", StrandPalette.statusWarningForeground)
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
