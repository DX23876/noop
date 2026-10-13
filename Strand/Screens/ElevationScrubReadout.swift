import SwiftUI
import StrandDesign

/// What the finger on the profile points at: distance, height and grade.
struct ElevationScrubReadout: View {
    let sample: (distanceM: Double, heightM: Double, grade: Double)
    let system: UnitSystem

    var body: some View {
        Text(verbatim: [UnitFormatter.distanceFromMeters(sample.distanceM, system: system),
                        UnitFormatter.elevationFromMeters(sample.heightM, system: system),
                        UnitFormatter.gradePercent(sample.grade)].joined(separator: " · "))
            .font(StrandFont.captionNumber)
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, NoopMetrics.space2)
            .padding(.vertical, NoopMetrics.space1)
            .background(StrandPalette.surfaceOverlay, in: Capsule())
    }
}
