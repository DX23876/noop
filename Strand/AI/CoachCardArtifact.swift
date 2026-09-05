import SwiftUI
import WhoopStore
import StrandDesign

// MARK: - A card the coach chose to show, built by the app
//
// The second artifact type in the transcript, beside `CoachChartArtifact`. A chart answers "which way
// is this going"; a card answers "what is this, right now, and is it normal for me".
//
// THE MODEL CHOOSES *WHICH* CARD. THE APP SUPPLIES EVERY NUMBER ON IT. That split is the whole point:
// a reply can state a figure the model assembled from a tool result, and a card cannot — every value
// here is resolved on-device from the same series the rest of the app reads. So a card can never
// disagree with the Today screen, and it cannot carry a number nobody measured.
//
// It is a SEPARATE type from the chart artifact rather than one generalised `CoachArtifact` enum: the
// chart's snapshot is already persisted per conversation, and folding the two into one dictionary would
// need a migration of every stored transcript for no user-visible gain. The two share the shape that
// matters — queue during the turn, flush into their own message, snapshot, render — which is the part
// a second mechanism would have duplicated.

/// One card in the transcript.
struct CoachCardArtifact: Equatable {
    enum Kind: String, Codable { case metric, workout }

    let kind: Kind
    /// What this card is about, e.g. "HRV" or "Strength Training".
    let title: String
    /// The headline, already formatted with its unit by the app.
    let value: String
    /// One line of context under the headline — usually how the value sits against the user's own
    /// recent average, which is the only comparison NOOP has evidence for.
    let caption: String?
    /// Up to four supporting figures. Kept short on purpose: a card that lists everything is a table,
    /// and the reply's own text is the place for a full account.
    let rows: [Row]
    /// Domain tint, so a Charge card reads green and an Effort card orange exactly as elsewhere.
    let tintName: String

    struct Row: Equatable, Codable {
        let label: String
        let value: String
    }

    var tint: Color {
        switch tintName {
        case "charge": return StrandPalette.chargeColor
        case "effort": return StrandPalette.effortColor
        case "rest":   return StrandPalette.restColor
        default:       return StrandPalette.accent
        }
    }
}

/// A Codable snapshot, so a card survives a relaunch. Mirrors `CoachChartSnapshot` exactly, including
/// why it exists separately: the artifact carries a SwiftUI `Color`, which has no business being
/// persisted, so the tint travels as its name.
struct CoachCardSnapshot: Codable, Equatable {
    let kind: String
    let title: String
    let value: String
    let caption: String?
    let rows: [CoachCardArtifact.Row]
    let tintName: String

    init(_ art: CoachCardArtifact) {
        kind = art.kind.rawValue
        title = art.title
        value = art.value
        caption = art.caption
        rows = art.rows
        tintName = art.tintName
    }

    var artifact: CoachCardArtifact {
        CoachCardArtifact(kind: CoachCardArtifact.Kind(rawValue: kind) ?? .metric,
                          title: title, value: value, caption: caption,
                          rows: rows, tintName: tintName)
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
