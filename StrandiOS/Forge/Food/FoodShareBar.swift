#if os(iOS)
import SwiftUI

/// A thin bar filled to `share` of its width, with an optional reference mark (a bullet bar). Laid out with
/// `FoodProportionalLayout` rather than `GeometryReader`, so it sizes like any other view.
struct FoodShareBar: View {
    let share: Double
    let tint: Color
    /// Where the reference sits on the same scale (0 to 1), drawn as a short upright mark.
    var reference: Double? = nil
    var height: Double = 6

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(tint.opacity(ForgeOpacity.band))
            FoodProportionalLayout(fraction: share) { Capsule().fill(tint) }
            if let reference {
                FoodProportionalLayout(fraction: reference, mark: true) {
                    Capsule().fill(ForgeColor.text).frame(width: 2, height: height + 6)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
#endif
