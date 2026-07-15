import SwiftUI
import StrandDesign

/// A chart the coach chose to display (via the `plot_metric` tool), rendered natively in the transcript
/// instead of as text. Built on-device from the user's own daily metrics — no data leaves the phone to
/// draw it. Kept in its own file so it stays merge-clean against upstream.
struct CoachChartArtifact {
    enum Kind: String { case charge, effort, hrv, rhr, sleep }

    let title: String
    let points: [TrendPoint]
    let valueRange: ClosedRange<Double>
    let kind: Kind

    /// Y-axis / tooltip formatting per metric, so units read correctly.
    var valueFormat: (Double) -> String {
        switch kind {
        case .charge: return { "\(Int($0.rounded()))" }
        case .effort: return { String(format: "%.1f", $0) }
        case .hrv:    return { "\(Int($0.rounded())) ms" }
        case .rhr:    return { "\(Int($0.rounded())) bpm" }
        case .sleep:  return { String(format: "%.1f h", $0) }
        }
    }
}

/// A frosted chart card shown as an assistant "bubble" in the coach transcript, matching the reply
/// bubbles' look. Reuses the design system's `TrendChart` (Swift Charts) so it renders identically to
/// the rest of the app.
struct CoachChartBubble: View {
    let artifact: CoachChartArtifact

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(artifact.title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                TrendChart(
                    points: artifact.points,
                    valueRange: artifact.valueRange,
                    height: 170,
                    valueFormat: artifact.valueFormat
                )
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frostedCardSurface(tint: StrandPalette.chargeColor, cornerRadius: 16)
            .frame(maxWidth: 560, alignment: .leading)
            Spacer(minLength: 48)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Coach chart: \(artifact.title)")
    }
}

/// A Codable snapshot of a `CoachChartArtifact`, so a chart the coach drew survives an app restart.
/// `TrendPoint` (in StrandDesign) isn't Codable and shouldn't be made so just for this, so we persist
/// only the raw {date, value} pairs plus the range and kind here, and rebuild the artifact on load.
struct CoachChartSnapshot: Codable, Equatable {
    struct Point: Codable, Equatable { let date: Date; let value: Double }

    let title: String
    let kind: String
    let points: [Point]
    let lo: Double
    let hi: Double

    init(_ art: CoachChartArtifact) {
        title = art.title
        kind = art.kind.rawValue
        points = art.points.map { Point(date: $0.date, value: $0.value) }
        lo = art.valueRange.lowerBound
        hi = art.valueRange.upperBound
    }

    /// Rebuild a renderable artifact. Falls back to `.charge` for an unknown kind and guards against an
    /// inverted range so `ClosedRange` never traps.
    var artifact: CoachChartArtifact {
        CoachChartArtifact(
            title: title,
            points: points.map { TrendPoint(date: $0.date, value: $0.value) },
            valueRange: lo <= hi ? lo...hi : hi...lo,
            kind: CoachChartArtifact.Kind(rawValue: kind) ?? .charge
        )
    }
}
