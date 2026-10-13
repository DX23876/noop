import SwiftUI
import StrandDesign

/// The profile's height axis: the top and bottom of the drawn range.
struct ElevationProfileYAxis: View {
    let low: Double
    let high: Double
    let system: UnitSystem

    var body: some View {
        VStack(alignment: .trailing) {
            Text(UnitFormatter.elevationFromMeters(high, system: system))
            Spacer(minLength: 0)
            Text(UnitFormatter.elevationFromMeters(low, system: system))
        }
        .font(StrandFont.captionNumber)
        .foregroundStyle(StrandPalette.textTertiary)
        .fixedSize(horizontal: true, vertical: false)
    }
}
