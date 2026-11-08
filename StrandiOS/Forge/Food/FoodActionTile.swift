#if os(iOS)
import SwiftUI

/// One large action tile: symbol over title.
struct FoodActionTile: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3).bold().foregroundStyle(ForgeColor.food)
                Text(title).font(.footnote).foregroundStyle(ForgeColor.text)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(ForgeColor.fill, in: .rect(cornerRadius: ForgeRadius.inner))
        }
        .buttonStyle(.plain)
    }
}
#endif
