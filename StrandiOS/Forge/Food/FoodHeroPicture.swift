#if os(iOS)
import SwiftUI

/// The Food page's picture: a dark still life of fresh food behind the title, fading into the scene before the
/// plate, as the night photo does on the Sleep page. Decorative only, and only in the dark appearance: the photo is
/// a night scene and would sit as a dark block on the light canvas.
struct FoodHeroPicture: View {
    var height: CGFloat = 400
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .dark { picture }
    }

    private var picture: some View {
        Image("foodHero")
            .resizable()
            .scaledToFill()
            // The food sits on the right of the photo; a narrow screen keeps that side.
            .frame(maxWidth: .infinity, maxHeight: height, alignment: .trailing)
            .frame(height: height)
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.4),
                                       .init(color: .black.opacity(0.35), location: 0.7), .init(color: .clear, location: 0.92)],
                               startPoint: .top, endPoint: .bottom)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
#endif
