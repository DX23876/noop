#if os(iOS)
import SwiftUI

/// A label whose icon carries a status colour, so status reads from the symbol as well as the colour.
struct FoodStatusLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(tint).font(.footnote)
            configuration.title.font(ForgeFont.body).foregroundStyle(ForgeColor.text)
        }
    }
}
#endif
