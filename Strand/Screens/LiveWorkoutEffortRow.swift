import SwiftUI
import StrandDesign
import StrandAnalytics

/// The running Effort, through the shared Effort-scale helper so it matches every other surface (#268).
/// Before any heart rate arrives it reads "—": "0.0" would claim a measured, effortless session.
struct LiveWorkoutEffortRow: View {
    let strain: Double
    let hasHeartRate: Bool

    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.hundred.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    private var measured: Bool { hasHeartRate || strain > 0 }

    private var caption: String {
        guard measured else { return String(localized: "Builds from heart rate.") }
        let display = UnitFormatter.effortValue(strain, scale: effortScale)
        let maxValue = effortScale == .whoop ? 21.0 : 100.0
        let state = StrainGauge.stateLabel(forFraction: min(max(display / maxValue, 0), 1))
        return "\(state) · \(String(localized: "of \(UnitFormatter.effortScaleMax(effortScale))"))"
    }

    var body: some View {
        LiveWorkoutMetricRow(value: measured ? UnitFormatter.effortDisplay(strain, scale: effortScale) : "—",
                             unit: String(localized: "Effort"),
                             caption: caption,
                             symbol: "flame.fill",
                             tint: measured ? StrandPalette.strainColor(strain) : StrandPalette.textTertiary)
    }
}
