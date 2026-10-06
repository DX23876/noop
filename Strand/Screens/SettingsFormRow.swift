import SwiftUI
import StrandDesign

/// A settings label and control that falls back to a vertical layout when the horizontal row no
/// longer fits, including long translations and larger accessibility text sizes.
struct FormRow<Control: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder let control: Control

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: NoopMetrics.space4) {
                labelView
                    .frame(maxWidth: .infinity, alignment: .leading)
                control.layoutPriority(1)
            }

            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                labelView
                control
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 44)
    }

    private var labelView: some View {
        Text(label)
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textPrimary)
    }
}
