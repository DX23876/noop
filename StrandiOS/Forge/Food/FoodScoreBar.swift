#if os(iOS)
import SwiftUI

/// One part of the nutrition score on a shared middle line: points it adds grow to the right in green, points it
/// costs grow to the left in red, ten points filling one half.
struct FoodScoreBar: View {
    /// -10 to +10.
    let effect: Double

    var body: some View {
        GeometryReader { proxy in
            let half = proxy.size.width / 2
            let length = half * min(1, abs(effect) / 10)
            ZStack(alignment: .leading) {
                Capsule().fill(ForgeColor.fill).frame(height: 6)
                Capsule().fill(effect >= 0 ? ForgeColor.nutrientLeaf : ForgeColor.nutrientRed)
                    .frame(width: length, height: 6)
                    .offset(x: effect >= 0 ? half : half - length)
                Rectangle().fill(ForgeColor.secondary).frame(width: 2, height: 12).offset(x: half - 1)
            }
            .frame(height: 12)
        }
        .frame(height: 12)
        .accessibilityHidden(true)
    }
}
#endif
