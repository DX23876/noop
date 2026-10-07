import SwiftUI
import StrandDesign

/// The quiet last line: a short caption, and "As of" with the weekday once the numbers are from an
/// earlier day, so yesterday's figure is never read as today's.
struct FitnessFootnote: View {
    let entry: FitnessEntry
    var caption: String?

    var body: some View {
        HStack(spacing: 4) {
            if let caption {
                Text(caption).foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 4)
            if entry.isStale, let updated = entry.snapshot?.updated {
                Text(String(localized: "As of \(updated.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .font(.caption2)
        .lineLimit(1)
    }
}
