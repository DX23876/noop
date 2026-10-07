import SwiftUI
import StrandDesign

/// The line every fitness widget opens with: its symbol in the metric's colour, its name.
struct FitnessWidgetHeader: View {
    let title: LocalizedStringKey
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
        } icon: {
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(tint)
        }
        .lineLimit(1)
    }
}
