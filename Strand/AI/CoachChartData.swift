import Foundation

/// A chart the coach chose to display (via the `plot_metric` tool), rendered natively in the transcript
/// instead of as text. Built on-device from the user's own daily metrics — no data leaves the phone to
/// draw it. The data half, without SwiftUI, so it links into the Android core; `CoachChart.swift` draws it.
struct CoachChartArtifact {
    enum Kind: String { case charge, effort, hrv, rhr, sleep, other }

    let title: String
    let values: [CoachChartSnapshot.Point]
    let valueRange: ClosedRange<Double>
    let kind: Kind

    /// Y-axis / tooltip formatting per metric, so units read correctly. `.other` (any metric key
    /// `plot_metric` fell through to, not one of the five hand-named ones) has no known unit, so it
    /// formats to one decimal place, unlabelled.
    var valueFormat: (Double) -> String {
        switch kind {
        case .charge: return { "\(Int($0.rounded()))" }
        case .effort: return { String(format: "%.1f", $0) }
        case .hrv:    return { "\(Int($0.rounded())) ms" }
        case .rhr:    return { "\(Int($0.rounded())) bpm" }
        case .sleep:  return { String(format: "%.1f h", $0) }
        case .other:  return { String(format: "%.1f", $0) }
        }
    }
}

/// A Codable snapshot of a `CoachChartArtifact`, so a chart the coach drew survives an app restart.
/// Only the raw {date, value} pairs plus the range and kind are persisted, and the artifact is rebuilt on
/// load.
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
        points = art.values
        lo = art.valueRange.lowerBound
        hi = art.valueRange.upperBound
    }

    /// Rebuild a renderable artifact. Falls back to `.charge` for an unknown kind and guards against an
    /// inverted range so `ClosedRange` never traps.
    var artifact: CoachChartArtifact {
        CoachChartArtifact(
            title: title,
            values: points,
            valueRange: lo <= hi ? lo...hi : hi...lo,
            kind: CoachChartArtifact.Kind(rawValue: kind) ?? .charge
        )
    }
}
