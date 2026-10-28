import SwiftUI
import StrandDesign

/// A frosted chart card shown as an assistant "bubble" in the coach transcript, matching the reply
/// bubbles' look. Reuses the design system's `TrendChart` (Swift Charts) so it renders identically to
/// the rest of the app. Taps open a larger, more legible detail view.
struct CoachChartBubble: View {
    let artifact: CoachChartArtifact
    @State private var showDetail = false
    /// Ties the inline chart to its full-screen version so the detail grows out of the bubble the user
    /// tapped (iOS 18+), instead of a sheet sliding up from an unrelated edge.
    @Namespace private var zoom

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
                        valueFormat: artifact.valueFormat,
                        // The artifact already carries the series name shown above the chart; without
                        // it the bubble reads out as the generic "Trend", which in a transcript of
                        // several charts makes them indistinguishable.
                        accessibilityLabel: artifact.title
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frostedCardSurface(tint: StrandPalette.chargeColor, cornerRadius: 16)
                .frame(maxWidth: 560, alignment: .leading)
            }
            .buttonStyle(.plain)
            .zoomSource(id: "coach.chart.\(artifact.title)", namespace: zoom)
            Spacer(minLength: 48)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Coach chart: \(artifact.title). Tap to enlarge.")
        .sheet(isPresented: $showDetail) {
            CoachChartDetail(artifact: artifact)
                .zoomDestination(id: "coach.chart.\(artifact.title)", namespace: zoom)
        }
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
                    valueFormat: artifact.valueFormat,
                    accessibilityLabel: artifact.title
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

extension CoachChartArtifact {
    /// The points as the shared trend chart draws them.
    var points: [TrendPoint] { values.map { TrendPoint(date: $0.date, value: $0.value) } }

    init(title: String, points: [TrendPoint], valueRange: ClosedRange<Double>, kind: Kind) {
        self.init(title: title, values: points.map { CoachChartSnapshot.Point(date: $0.date, value: $0.value) },
                  valueRange: valueRange, kind: kind)
    }
}
