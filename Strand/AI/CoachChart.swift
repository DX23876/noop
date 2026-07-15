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
/// the rest of the app. Taps open a larger, more legible detail view.
struct CoachChartBubble: View {
    let artifact: CoachChartArtifact
    @State private var showDetail = false

    var body: some View {
        HStack {
            Button { showDetail = true } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(artifact.title)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    TrendChart(
                        points: artifact.points,
                        valueRange: artifact.valueRange,
                        height: 220,
                        valueFormat: artifact.valueFormat
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frostedCardSurface(tint: StrandPalette.chargeColor, cornerRadius: 16)
                .frame(maxWidth: 560, alignment: .leading)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 48)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Coach chart: \(artifact.title). Tap to enlarge.")
        .sheet(isPresented: $showDetail) { CoachChartDetail(artifact: artifact) }
    }
}

/// A full-screen, tall version of a coach chart, so trends drawn inline can be read closely.
struct CoachChartDetail: View {
    let artifact: CoachChartArtifact
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TrendChart(
                    points: artifact.points,
                    valueRange: artifact.valueRange,
                    height: 320,
                    valueFormat: artifact.valueFormat
                )
                Text("\(artifact.points.count) days")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                Spacer()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(artifact.title)
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
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
