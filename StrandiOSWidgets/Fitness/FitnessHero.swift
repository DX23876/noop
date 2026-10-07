import SwiftUI

/// The widget's figure: large where it fits, a size down where it does not, never squeezed.
struct FitnessHero: View {
    let value: String
    var unit: String?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            figure(.title2)
            figure(.title3)
            figure(.headline)
        }
    }

    private func figure(_ style: Font.TextStyle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(.system(style).weight(.bold)).fontDesign(.rounded).monospacedDigit()
            if let unit {
                Text(unit).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }
}
