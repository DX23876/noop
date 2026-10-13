import SwiftUI
import StrandDesign

/// One figure under the elevation profile: the value over its label, a dash when unknown.
struct WorkoutElevationStat: View {
    let title: String
    let value: String?
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(value ?? "–")
                .font(StrandFont.number(17))
                .foregroundStyle(value == nil ? StrandPalette.textTertiary : (tint ?? StrandPalette.textPrimary))
                .lineLimit(1)
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
