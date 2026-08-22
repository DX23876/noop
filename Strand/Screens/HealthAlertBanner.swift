import SwiftUI
import StrandDesign
import StrandAnalytics
import Foundation

/// Strain/illness early-warning banner. Observes AppModel in isolation so the ~1 Hz HR stream
/// re-renders only this small view, not the whole screen. Renders nothing when there's no alert.
struct HealthAlertBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let alert = model.healthAlert {
            let copy = localizedHealthAlertCopy(alert)
            // A frosted, warning-tinted alert card (not a flat coloured bar) — prominent but on-brand.
            // The amber wash + a glyph in a soft amber chip read as an early-warning without a hard rule.
            NoopCard(padding: 14, tint: StrandPalette.statusWarning) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(StrandPalette.statusWarning)
                        .frame(width: 30, height: 30)
                        .background(StrandPalette.statusWarning.opacity(0.16), in: Circle())
                        .accessibilityHidden(true)
                    Text(copy)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(copy)
        }
    }
}

/// Home-facing rendering of the semantic illness result. Both Today variants share this banner,
/// so neither can accidentally expose the analytics engine's English notification copy.
func localizedHealthAlertCopy(_ alert: AppModel.HealthAlert) -> String {
    if alert.message == .raised {
        let formatter = ListFormatter()
        formatter.locale = AppLanguage.activeLocale
        let signals = formatter.string(from: alert.firedSignals) ?? alert.firedSignals.joined(separator: ", ")
        return String(localized: "Your body looks strained. Signals up: \(signals). No alcohol or travel was logged, so consider taking it easy. On-device estimate, not a diagnosis.")
    }
    if alert.message == .alreadyUnwellAgree {
        return String(localized: "You logged feeling unwell, and your signals agree. Take it easy today. On-device estimate, not a diagnosis.")
    }
    if alert.message == .alreadyUnwell {
        return String(localized: "You logged feeling unwell. Take it easy today. On-device estimate, not a diagnosis.")
    }
    // The publisher gates the banner to raised/already-unwell. Keep the impossible fallback localized
    // and semantic rather than leaking `Result.copy` if a future caller bypasses that gate.
    return String(localized: "Nothing notable. Your signals look like their normal range.")
}
