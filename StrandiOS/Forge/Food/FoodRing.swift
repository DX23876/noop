#if os(iOS)
import SwiftUI

/// A progress ring with one stroke width for track and fill, its content in the middle.
struct FoodRing<Content: View>: View {
    let share: Double
    let tint: Color
    var lineWidth: Double = 12
    @ViewBuilder let content: Content

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(ForgeOpacity.band), lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(1, max(0, share)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            content
        }
        .padding(lineWidth / 2)
    }
}
#endif
