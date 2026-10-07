import SwiftUI
import StrandDesign

/// What a fitness widget says before there is anything to show: its name and one line on where the
/// numbers come from. Never a sample figure.
struct FitnessNoData: View {
    let title: LocalizedStringKey
    let symbol: String
    let tint: Color
    let message: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FitnessWidgetHeader(title: title, symbol: symbol, tint: tint)
            Spacer(minLength: 0)
            Text(message).font(.caption).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
