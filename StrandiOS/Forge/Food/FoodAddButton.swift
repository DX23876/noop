#if os(iOS)
import SwiftUI

/// The page's one main action, floating above the content.
struct FoodAddButton: View {
    let action: () -> Void

    var body: some View {
        Button("Add food", systemImage: "plus", action: action)
            .font(.headline)
            .foregroundStyle(ForgeColor.onAccent)
            .padding(.horizontal, 24)
            .frame(minHeight: 52)
            .background(ForgeColor.accent, in: .capsule)
            .buttonStyle(.plain)
            .padding(.bottom, 16)
    }
}
#endif
