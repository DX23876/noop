import SwiftUI
import WhoopStore
import StrandDesign

extension CoachCardArtifact {
    /// Domain tint by name (`CoachCardData.swift` holds the data half).
    var tint: Color {
        switch tintName {
        case "charge": return StrandPalette.chargeColor
        case "effort": return StrandPalette.effortColor
        case "rest":   return StrandPalette.restColor
        default:       return StrandPalette.accent
        }
    }
}

/// The card as it appears in the transcript.
///
/// Sized to the reading column rather than to a bubble, like everything else the coach shows now, and
/// built from `NoopCard` so it is the same object the rest of the app draws — a second card style in
/// the chat would read as a different app talking.
struct CoachCardBubble: View {
    let artifact: CoachCardArtifact

    var body: some View {
        NoopCard(padding: 14, tint: artifact.tint) {
            VStack(alignment: .leading, spacing: 8) {
                Text(artifact.title.uppercased())
                    .font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(artifact.value)
                        .font(StrandFont.number(30))
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let caption = artifact.caption {
                        Text(caption)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !artifact.rows.isEmpty {
                    Divider().overlay(StrandPalette.hairline)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(artifact.rows, id: \.label) { row in
                            HStack {
                                Text(row.label)
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                Spacer(minLength: 8)
                                Text(row.value)
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = ["\(artifact.title): \(artifact.value)"]
        if let caption = artifact.caption { parts.append(caption) }
        parts.append(contentsOf: artifact.rows.map { "\($0.label) \($0.value)" })
        return parts.joined(separator: ", ")
    }
}
