import SwiftUI
import StrandDesign

/// Shown on the live elevation page of a device without a barometer: NOOP shows no elevation rather than
/// summing GPS altitude.
struct LiveElevationUnavailableView: View {
    var body: some View {
        if #available(iOS 17, macOS 14, *) {
            ContentUnavailableView("No barometer", systemImage: "barometer",
                                   description: Text(Self.explanation))
        } else {
            Text(Self.explanation)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .screenPadding()
        }
    }

    private static let explanation: LocalizedStringKey =
        "This device has no barometer, so NOOP shows no elevation rather than guessing it from GPS."
}
