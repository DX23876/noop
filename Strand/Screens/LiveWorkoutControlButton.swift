import SwiftUI
import StrandDesign

/// A large, tinted capsule button for the live workout's bottom bar.
struct LiveWorkoutControlButton: View {
    let title: LocalizedStringKey
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(StrandFont.headline)
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(tint.opacity(0.16), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(LiquidPressStyle())
    }
}
