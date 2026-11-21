#if os(iOS)
import SwiftUI
import StrandCore

/// The small square picture of a food or meal: the still life of its group, or a quiet plate when it has none.
struct FoodThumbnail: View {
    let motif: FoodGroupMotif?
    var size: CGFloat = 44

    var body: some View {
        // The still life fills a fixed square and is cut to it; a filling image inside a flexible frame would widen
        // the frame to the image instead.
        ForgeColor.fill
            .frame(width: size, height: size)
            .overlay {
                if let motif {
                    Image(FoodMealPicture.assetName(motif)).resizable().scaledToFill()
                } else {
                    Image(systemName: "fork.knife").font(.body).foregroundStyle(ForgeColor.tertiary)
                }
            }
            .clipShape(.rect(cornerRadius: ForgeRadius.inner))
            .accessibilityHidden(true)
    }
}
#endif
