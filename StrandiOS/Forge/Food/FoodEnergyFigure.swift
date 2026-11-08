#if os(iOS)
import SwiftUI

/// One small figure under the plate: a quiet title over the number in kcal.
struct FoodEnergyFigure: View {
    let title: String
    let value: String
    var showsInfo = false

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Text(title)
                if showsInfo { Image(systemName: "info.circle").imageScale(.small) }
            }
            .font(.footnote).foregroundStyle(ForgeColor.secondary)
            Text(value).font(ForgeFont.rounded(17, .semibold)).foregroundStyle(ForgeColor.text)
                .monospacedDigit().contentTransition(.numericText())
        }
        .accessibilityElement(children: .combine)
    }
}
#endif
