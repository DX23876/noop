import SwiftUI
import StrandDesign

/// The elevation profile over distance, drawn for this data: the line takes the cardio colour on the level
/// and descents and warms to the Effort colour where the climb steepens (`ElevationGradeStyle`), over a soft
/// fill that fades into the card. Height and distance are labelled on their axes; a finger on the profile
/// reads out distance, height and grade at that point.
struct ElevationProfileGraph: View {
    let system: UnitSystem
    var isAbsolute = true
    var height: CGFloat = 160
    var allowsScrub = true
    private let geometry: ElevationProfileGeometry

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn: CGFloat = 0
    @State private var scrubIndex: Int?
    @State private var plotSize: CGSize = .zero

    init(samples: [(distanceM: Double, heightM: Double, grade: Double)], system: UnitSystem,
         isAbsolute: Bool = true, height: CGFloat = 160, allowsScrub: Bool = true) {
        self.system = system
        self.isAbsolute = isAbsolute
        self.height = height
        self.allowsScrub = allowsScrub
        geometry = ElevationProfileGeometry(samples: samples)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack(alignment: .top, spacing: NoopMetrics.space2) {
                ElevationProfileYAxis(low: geometry.low, high: geometry.high, system: system)
                ZStack(alignment: .topLeading) {
                    ElevationProfileShape(points: geometry.points, closed: true)
                        .fill(LinearGradient(colors: [StrandPalette.cardioColor.opacity(0.35),
                                                      StrandPalette.cardioColor.opacity(0)],
                                             startPoint: .top, endPoint: .bottom))
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: plotSize.width * drawn)
                        }
                    ElevationProfileShape(points: geometry.points, closed: false)
                        .trim(from: 0, to: drawn)
                        .stroke(LinearGradient(stops: geometry.gradeStops, startPoint: .leading, endPoint: .trailing),
                                style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .shadow(color: StrandPalette.cardioColor.opacity(0.35), radius: 4)
                    if let scrubIndex, geometry.points.indices.contains(scrubIndex) {
                        let point = geometry.points[scrubIndex]
                        Rectangle().fill(StrandPalette.hairlineStrong)
                            .frame(width: 1)
                            .offset(x: point.x * plotSize.width)
                        Circle().fill(ElevationGradeStyle.color(forGrade: geometry.samples[scrubIndex].grade))
                            .frame(width: 10, height: 10)
                            .offset(x: point.x * plotSize.width - 5, y: point.y * plotSize.height - 5)
                    }
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { plotSize = $0 }
                .overlay(alignment: .top) {
                    if let scrubIndex, geometry.samples.indices.contains(scrubIndex) {
                        ElevationScrubReadout(sample: geometry.samples[scrubIndex], system: system)
                    }
                }
                .contentShape(Rectangle())
                .gesture(scrubGesture, including: allowsScrub ? .all : .subviews)
            }
            .frame(height: height)
            ElevationProfileXAxis(totalDistanceM: geometry.totalDistanceM, system: system)
                .padding(.leading, NoopMetrics.space10)
        }
        .onAppear(perform: drawIn)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    /// The line draws in once; with Reduce Motion it is simply there.
    private func drawIn() {
        guard drawn == 0 else { return }
        if reduceMotion {
            drawn = 1
        } else {
            withAnimation(.easeOut(duration: 0.9)) { drawn = 1 }
        }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                scrubIndex = geometry.nearestIndex(toShare: value.location.x / max(1, plotSize.width))
            }
            .onEnded { _ in scrubIndex = nil }
    }

    private var accessibilitySummary: String {
        let heights = geometry.samples.map(\.heightM)
        let low = UnitFormatter.elevationFromMeters(heights.min() ?? 0, system: system)
        let high = UnitFormatter.elevationFromMeters(heights.max() ?? 0, system: system)
        let distance = UnitFormatter.distanceFromMeters(geometry.totalDistanceM, system: system)
        return isAbsolute
            ? String(localized: "Elevation profile over \(distance), from \(low) to \(high).")
            : String(localized: "Elevation profile over \(distance), relative to the start.")
    }
}
