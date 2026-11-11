#if os(iOS)
import SwiftUI

/// A section's title standing in the scene above its card, as the score pages set theirs; with an action it opens
/// the section's own page.
struct FoodSectionHeader: View {
    let title: String
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) { label(chevron: true) }.buttonStyle(.plain)
        } else {
            label(chevron: false)
        }
    }

    private func label(chevron: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(ForgeFont.section).foregroundStyle(ForgeColor.text)
            if chevron {
                Image(systemName: "chevron.right").font(.headline).foregroundStyle(ForgeColor.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 4)
        .accessibilityAddTraits(.isHeader)
    }
}
#endif
