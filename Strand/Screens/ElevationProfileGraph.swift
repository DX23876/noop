import SwiftUI
import StrandDesign

/// The elevation profile over distance, drawn for this data: the line takes the cardio colour on the level
/// and descents and warms to the Effort colour where the climb steepens, over a soft fill that fades into
/// the card. Height and distance are labelled on their axes; a finger on the profile reads out distance,
/// height and grade at that point.
struct ElevationProfileGraph: View {
    let samples: [(distanceM: Double, heightM: Double, grade: Double)]
    let system: UnitSystem
    var isAbsolute = true
    var height: CGFloat = 160
    var allowsScrub = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0
    @State private var scrubIndex: Int?

    /// A climb this steep or steeper draws in the full Effort colour; a gentler one in between.
    static let steepGrade = 0.08
    static let moderateGrade = 0.03

    private var range: (low: Double, high: Double) {
        let values = samples.map(\.heightM)
        let low = values.min() ?? 0, high = values.max() ?? 0
        // Ten metres of headroom at least, so a flat walk does not fill the card with its own noise.
        let pad = max(5, (high - low) * 0.15)
        return (low - pad, high + pad)
    }

    private var totalDistance: Double { max(1, samples.last?.distanceM ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack(alignment: .top, spacing: NoopMetrics.space2) {
                yAxis
                plot
            }
            .frame(height: height)
            xAxis
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    // MARK: Plot

    private var plot: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                ProfileArea(points: normalized, closed: true)
                    .fill(LinearGradient(colors: [StrandPalette.cardioColor.opacity(0.35),
                                                  StrandPalette.cardioColor.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: size.width * drawn)
                    }
                ProfileArea(points: normalized, closed: false)
                    .trim(from: 0, to: drawn)
                    .stroke(LinearGradient(stops: gradeStops, startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .shadow(color: StrandPalette.cardioColor.opacity(0.35), radius: 4)
                if let scrubIndex, samples.indices.contains(scrubIndex) {
                    scrubMarker(at: scrubIndex, in: size)
                }
            }
            .contentShape(Rectangle())
            .gesture(scrubGesture(width: size.width), including: allowsScrub ? .all : .subviews)
        }
        .onAppear {
            guard drawn == 0 else { return }
            if reduceMotion { drawn = 1 } else {
                withAnimation(.easeOut(duration: 0.9)) { drawn = 1 }
            }
        }
    }

    /// Samples mapped to 0…1 on both axes (y grows downward).
    private var normalized: [CGPoint] {
        let r = range, span = max(1, r.high - r.low)
        return samples.map {
            CGPoint(x: $0.distanceM / totalDistance, y: 1 - ($0.heightM - r.low) / span)
        }
    }

    private var gradeStops: [Gradient.Stop] {
        guard samples.count > 1 else { return [.init(color: StrandPalette.cardioColor, location: 0)] }
        return samples.map {
            Gradient.Stop(color: Self.color(forGrade: $0.grade), location: $0.distanceM / totalDistance)
        }
    }

    static func color(forGrade grade: Double) -> Color {
        if grade >= steepGrade { return StrandPalette.effortBright }
        if grade >= moderateGrade { return StrandPalette.effortColor }
        return StrandPalette.cardioColor
    }

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let fraction = min(max(0, value.location.x / max(1, width)), 1)
                let target = fraction * totalDistance
                scrubIndex = samples.indices.min { abs(samples[$0].distanceM - target) < abs(samples[$1].distanceM - target) }
            }
            .onEnded { _ in scrubIndex = nil }
    }

    private func scrubMarker(at index: Int, in size: CGSize) -> some View {
        let point = normalized[index]
        let x = point.x * size.width, y = point.y * size.height
        let sample = samples[index]
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(StrandPalette.hairlineStrong)
                .frame(width: 1, height: size.height)
                .offset(x: x)
            Circle().fill(Self.color(forGrade: sample.grade))
                .frame(width: 10, height: 10)
                .offset(x: x - 5, y: y - 5)
            Text(verbatim: [UnitFormatter.distanceFromMeters(sample.distanceM, system: system),
                            UnitFormatter.elevationFromMeters(sample.heightM, system: system),
                            UnitFormatter.gradePercent(sample.grade)].joined(separator: " · "))
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.horizontal, NoopMetrics.space2)
                .padding(.vertical, NoopMetrics.space1)
                .background(StrandPalette.surfaceOverlay, in: Capsule())
                .fixedSize()
                .offset(x: min(max(0, x - 60), max(0, size.width - 150)), y: -NoopMetrics.space1)
        }
    }

    // MARK: Axes

    private var yAxis: some View {
        let r = range
        return VStack(alignment: .trailing) {
            Text(UnitFormatter.elevationFromMeters(r.high, system: system))
            Spacer(minLength: 0)
            Text(UnitFormatter.elevationFromMeters(r.low, system: system))
        }
        .font(StrandFont.captionNumber)
        .foregroundStyle(StrandPalette.textTertiary)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var xAxis: some View {
        HStack {
            Text(UnitFormatter.distanceFromMeters(0, system: system))
            Spacer(minLength: 0)
            Text(UnitFormatter.distanceFromMeters(totalDistance / 2, system: system))
            Spacer(minLength: 0)
            Text(UnitFormatter.distanceFromMeters(totalDistance, system: system))
        }
        .font(StrandFont.captionNumber)
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.leading, NoopMetrics.space10)
    }

    private var accessibilitySummary: String {
        let r = samples.map(\.heightM)
        let low = UnitFormatter.elevationFromMeters(r.min() ?? 0, system: system)
        let high = UnitFormatter.elevationFromMeters(r.max() ?? 0, system: system)
        let distance = UnitFormatter.distanceFromMeters(totalDistance, system: system)
        return isAbsolute
            ? String(localized: "Elevation profile over \(distance), from \(low) to \(high).")
            : String(localized: "Elevation profile over \(distance), relative to the start.")
    }
}

/// The profile as a line, or closed to the bottom edge as an area, in a 0…1 unit space.
private struct ProfileArea: Shape {
    let points: [CGPoint]
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height) }
        if closed {
            path.move(to: CGPoint(x: map(first).x, y: rect.maxY))
            path.addLine(to: map(first))
        } else {
            path.move(to: map(first))
        }
        for point in points.dropFirst() { path.addLine(to: map(point)) }
        if closed, let last = points.last {
            path.addLine(to: CGPoint(x: map(last).x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}
