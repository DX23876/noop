#if os(iOS)
import SwiftUI

/// A label whose icon takes its own colour while the title keeps the text's.
struct TintedIconLabel: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}
#endif
