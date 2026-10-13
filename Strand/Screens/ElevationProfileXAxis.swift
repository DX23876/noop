import SwiftUI
import StrandDesign

/// The profile's distance axis: start, half way and the end of the route.
struct ElevationProfileXAxis: View {
    let totalDistanceM: Double
    let system: UnitSystem

    var body: some View {
        HStack {
            Text(UnitFormatter.distanceFromMeters(0, system: system))
            Spacer(minLength: 0)
            Text(UnitFormatter.distanceFromMeters(totalDistanceM / 2, system: system))
            Spacer(minLength: 0)
            Text(UnitFormatter.distanceFromMeters(totalDistanceM, system: system))
        }
        .font(StrandFont.captionNumber)
        .foregroundStyle(StrandPalette.textTertiary)
    }
}
