#if !os(watchOS)
import SwiftUI
#if canImport(Accessibility)
import Accessibility
#endif

// MARK: - Audio Graph (VoiceOver point-by-point access to a chart)
//
// The shared charts were never silent: TrendChart, Sparkline and Hypnogram each speak one summary
// ("N points, mean X, range Y to Z"). What a summary cannot give is the SHAPE — where the dip is, how
// long the climb lasted, whether last night's deep sleep came early or late. Apple's Audio Graph is
// the built-in answer: VoiceOver's rotor gains a "Audio Graph" item that plays the series as pitch
// over time and lets the user step point by point.
//
// It is built here, once, on the three shared components, so every call site gains it at the same
// time rather than 20 screens each remembering to.
//
// Cost: an AXChartDescriptor is NOT a semantics subtree. It is created lazily, only when an assistive
// technology asks for it, and it holds plain numbers — so it does not reintroduce the per-element
// accessibility walk that `Hypnogram` deliberately collapsed for scroll performance (#707). That
// distinction is the whole reason this is safe to add there; see the note at `Hypnogram`'s call.

/// One point as the audio graph sees it: a position on each axis, plus the words VoiceOver speaks
/// when the user lands on it.
public struct AudioGraphPoint: Equatable, Sendable {
    /// Position along the x axis, in the same units as `AudioGraphPlan.xRange`.
    public let x: Double
    /// Position along the y axis, in the same units as `AudioGraphPlan.yRange`.
    public let y: Double
    /// Spoken x label (a date, a time, "sample 4"). VoiceOver reads this with the value.
    public let label: String

    public init(x: Double, y: Double, label: String) {
        self.x = x
        self.y = y
        self.label = label
    }
}

/// Everything an `AXChartDescriptor` needs, as plain values.
///
/// Split out from the descriptor itself so the part that can be wrong — axis bounds, ordering, the
/// degenerate cases — is pure and unit-testable with no view, no VoiceOver and no running app.
/// `ChartAudioGraphTests` covers it; the bridge below is a mechanical transcription.
public struct AudioGraphPlan: Equatable, Sendable {
    public let title: String
    public let xLabel: String
    public let yLabel: String
    public let xRange: ClosedRange<Double>
    public let yRange: ClosedRange<Double>
    public let points: [AudioGraphPoint]

    /// Build a plan for a single series, deriving axis bounds from the data.
    ///
    /// Two invariants matter enough to be tested, because breaking either produces a chart that is
    /// worse than having no audio graph at all:
    ///
    /// - **Points are sorted by x.** VoiceOver steps them in array order; an unsorted series would
    ///   scrub back and forth in time while claiming to be a trend.
    /// - **Neither axis is ever zero-width.** A flat series (every value identical — a resting heart
    ///   rate that held all week, a Sparkline of one sample) has `min == max`, and mapping a value
    ///   into a zero-width range is a divide-by-zero that renders every tone identical or NaN. A flat
    ///   line is padded to a range around the value, so it reads as genuinely flat.
    public static func series(title: String,
                              xLabel: String,
                              yLabel: String,
                              points: [AudioGraphPoint]) -> AudioGraphPlan {
        let sorted = points.sorted { $0.x < $1.x }
        return AudioGraphPlan(
            title: title,
            xLabel: xLabel,
            yLabel: yLabel,
            xRange: Self.span(sorted.map(\.x)),
            yRange: Self.span(sorted.map(\.y)),
            points: sorted
        )
    }

    public init(title: String, xLabel: String, yLabel: String,
                xRange: ClosedRange<Double>, yRange: ClosedRange<Double>,
                points: [AudioGraphPoint]) {
        self.title = title
        self.xLabel = xLabel
        self.yLabel = yLabel
        self.xRange = xRange
        self.yRange = yRange
        self.points = points
    }

    /// A never-degenerate range over `values`. Empty → 0...1; flat → the value ±half a unit (or ±1%
    /// of its magnitude, whichever is larger, so a flat series at 1,000,000 still gets a sane span).
    static func span(_ values: [Double]) -> ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        guard hi <= lo else { return lo...hi }
        let pad = Swift.max(0.5, abs(lo) * 0.01)
        return (lo - pad)...(lo + pad)
    }
}

#if canImport(Accessibility)
/// Bridges an `AudioGraphPlan` to the Accessibility framework.
///
/// A class because `AXChartDescriptorRepresentable` requires one. Holds only the plan, so building it
/// per body eval is cheap — and it is only *asked* for a descriptor when an assistive technology
/// actually opens the audio graph.
final class PlanChartDescriptor: AXChartDescriptorRepresentable {
    private let plan: AudioGraphPlan

    init(_ plan: AudioGraphPlan) { self.plan = plan }

    func makeChartDescriptor() -> AXChartDescriptor {
        let xAxis = AXNumericDataAxisDescriptor(
            title: plan.xLabel,
            range: plan.xRange,
            gridlinePositions: [],
            valueDescriptionProvider: { [points = plan.points] value in
                // Speak the point's own label (a date, a time) rather than the raw x number, which
                // for a time series is a meaningless epoch offset.
                Self.nearestLabel(to: value, in: points)
            }
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: plan.yLabel,
            range: plan.yRange,
            gridlinePositions: [],
            valueDescriptionProvider: { String(format: "%.1f", $0) }
        )
        let series = AXDataSeriesDescriptor(
            name: plan.title,
            isContinuous: true,
            dataPoints: plan.points.map { AXDataPoint(x: $0.x, y: $0.y, additionalValues: [], label: $0.label) }
        )
        return AXChartDescriptor(title: plan.title,
                                 summary: nil,
                                 xAxis: xAxis,
                                 yAxis: yAxis,
                                 additionalAxes: [],
                                 series: [series])
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        // The descriptor is rebuilt from the current plan on every request, so there is no stale
        // state to reconcile here.
    }

    /// The label of the point closest to `value` on the x axis — what the axis reads out as the user
    /// scrubs. Empty string for an empty series, which VoiceOver simply skips.
    private static func nearestLabel(to value: Double, in points: [AudioGraphPoint]) -> String {
        points.min(by: { abs($0.x - value) < abs($1.x - value) })?.label ?? ""
    }
}

extension View {
    /// Attach an audio graph built from `plan`. No-op shape for callers: it is one modifier on the
    /// same element that already carries the chart's label and summary.
    func audioGraph(_ plan: AudioGraphPlan) -> some View {
        accessibilityChartDescriptor(PlanChartDescriptor(plan))
    }
}
#else
extension View {
    /// Platforms without the Accessibility framework keep the summary-only behaviour.
    func audioGraph(_ plan: AudioGraphPlan) -> some View { self }
}
#endif
#endif
