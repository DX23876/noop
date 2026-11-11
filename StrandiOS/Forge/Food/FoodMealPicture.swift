#if os(iOS)
import SwiftUI
import StrandCore

/// The picture at the top of a meal card: the meal's own photo, or a still life of its main food group. Decorative,
/// so VoiceOver skips it; the card's text already names the meal.
struct FoodMealPicture: View {
    enum Source: Equatable {
        case photo(String)
        case motif(FoodGroupMotif)
    }

    let source: Source
    var height: CGFloat = 132
    @State private var photo: UIImage?

    var body: some View {
        picture
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(.rect(cornerRadius: ForgeRadius.inner))
            .accessibilityHidden(true)
            .task(id: source) { await loadPhoto() }
    }

    @ViewBuilder private var picture: some View {
        switch source {
        case .photo:
            if let photo {
                Image(uiImage: photo).resizable().scaledToFill()
            } else {
                ForgeColor.fill
            }
        case .motif(let motif):
            Image(Self.assetName(motif)).resizable().scaledToFill()
        }
    }

    static func assetName(_ motif: FoodGroupMotif) -> String { "foodMotif_\(motif.rawValue)" }

    private func loadPhoto() async {
        guard case .photo(let id) = source, let url = FoodPhotoStore.appDefault?.existingURL(id) else { photo = nil; return }
        photo = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: url.path) }.value
    }
}
#endif
