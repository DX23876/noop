import SwiftUI
import StrandDesign

// MARK: - ECG paper: one geometry for the live sweep and the saved printout
//
// An ECG only looks like an ECG at the standard proportions: 25 mm per second and 10 mm per millivolt.
// Scaling the trace to fill its box instead stretches every beat into a needle. Both views draw through
// `EcgPaper`, so the live sweep and a saved reading share the same millimetre grid and the same scale.
//
// The strap's samples are 100 Hz filtered input-referred microvolts (OpenStrap's reading of the R17
// record); NOOP has not verified the amplitude calibration, so the millivolt scale is nominal.

/// The millimetre grid and the scale every ECG view draws with.
struct EcgPaper {
    static let millimetersPerSecond: CGFloat = 25
    static let millimetersPerMillivolt: CGFloat = 10
    static let sampleRate = 100
    /// Points per millimetre the layouts aim for; a printout row snaps to whole seconds around it.
    static let targetPointsPerMillimeter: CGFloat = 3.5

    let pointsPerMillimeter: CGFloat

    var pointsPerSample: CGFloat {
        pointsPerMillimeter * Self.millimetersPerSecond / CGFloat(Self.sampleRate)
    }

    /// Vertical offset of a sample in microvolts (positive is up).
    func offset(microvolts: Double) -> CGFloat {
        CGFloat(microvolts / 1000) * Self.millimetersPerMillivolt * pointsPerMillimeter
    }

    /// The paper: a light 1 mm grid under a stronger 5 mm grid.
    func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var minor = Path()
        var major = Path()
        func line(_ index: Int, from: CGPoint, to: CGPoint) {
            if index % 5 == 0 {
                major.move(to: from); major.addLine(to: to)
            } else {
                minor.move(to: from); minor.addLine(to: to)
            }
        }
        var index = 0
        var x: CGFloat = 0
        while x <= size.width + 0.5 {
            line(index, from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: size.height))
            index += 1
            x += pointsPerMillimeter
        }
        index = 0
        var y: CGFloat = 0
        while y <= size.height + 0.5 {
            line(index, from: CGPoint(x: 0, y: y), to: CGPoint(x: size.width, y: y))
            index += 1
            y += pointsPerMillimeter
        }
        context.stroke(minor, with: .color(StrandPalette.metricRose.opacity(0.15)), lineWidth: 0.5)
        context.stroke(major, with: .color(StrandPalette.metricRose.opacity(0.3)), lineWidth: 0.75)
    }

    /// The trace with its baseline at `baselineY`, starting at `originX`. Nil samples break the line.
    func drawTrace(_ samples: ArraySlice<Double?>, in context: inout GraphicsContext, originX: CGFloat,
                   baselineY: CGFloat) {
        var trace = Path()
        var penDown = false
        for (i, sample) in samples.enumerated() {
            guard let sample else { penDown = false; continue }
            let point = CGPoint(x: originX + CGFloat(i) * pointsPerSample,
                                y: baselineY - offset(microvolts: sample))
            if penDown { trace.addLine(to: point) } else { trace.move(to: point); penDown = true }
        }
        context.stroke(trace, with: .color(StrandPalette.textPrimary),
                       style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
    }
}

/// Display-only signal conditioning. The stored samples are never changed.
enum EcgSignal {
    /// Removes baseline wander by subtracting a centred 0.6 s moving mean, so the trace sits on its line
    /// the way a monitor shows it. A gap (nil) restarts the window.
    static func centered(_ samples: [Int16?], window: Int = 61) -> [Double?] {
        var out = [Double?](repeating: nil, count: samples.count)
        var start = 0
        while start < samples.count {
            guard samples[start] != nil else { start += 1; continue }
            var end = start
            while end < samples.count, samples[end] != nil { end += 1 }
            var prefix = [0.0]
            prefix.reserveCapacity(end - start + 1)
            for i in start..<end { prefix.append(prefix[prefix.count - 1] + Double(samples[i] ?? 0)) }
            let half = window / 2
            let count = end - start
            for i in 0..<count {
                let lo = max(0, i - half)
                let hi = min(count, i + half + 1)
                out[start + i] = Double(samples[start + i] ?? 0) - (prefix[hi] - prefix[lo]) / Double(hi - lo)
            }
            start = end
        }
        return smoothed(out)
    }

    /// A light display low-pass: the [1, 4, 6, 4, 1] / 16 kernel (two passes of [1, 2, 1] / 4), which
    /// takes the muscle tremor out of the line while keeping the QRS shape, much as a monitor's display
    /// filter does. Gaps stay gaps; an edge sample keeps its own value.
    static func smoothed(_ samples: [Double?]) -> [Double?] {
        let kernel: [Double] = [1, 4, 6, 4, 1]
        var out = samples
        for i in samples.indices {
            guard samples[i] != nil else { continue }
            var sum = 0.0
            var weight = 0.0
            for (k, w) in kernel.enumerated() {
                let j = i + k - 2
                guard samples.indices.contains(j), let value = samples[j] else { continue }
                sum += value * w
                weight += w
            }
            out[i] = sum / weight
        }
        return out
    }
}

/// The live sweep: the newest seconds that fit the width, entering at the right edge like a monitor.
struct EcgLiveStrip: View {
    let samples: [Int16]
    /// Height in millimetres of paper; 30 mm is ±1.5 mV.
    var heightMillimeters: CGFloat = 30

    private var paper: EcgPaper { EcgPaper(pointsPerMillimeter: EcgPaper.targetPointsPerMillimeter) }

    var body: some View {
        Canvas { context, size in
            paper.drawGrid(in: &context, size: size)
            let visible = Int(size.width / paper.pointsPerSample)
            let shown = EcgSignal.centered(samples.map { Optional($0) }).suffix(visible)
            let originX = size.width - CGFloat(shown.count) * paper.pointsPerSample
            paper.drawTrace(shown, in: &context, originX: originX, baselineY: size.height / 2)
        }
        .frame(height: heightMillimeters * paper.pointsPerMillimeter)
        .background(StrandPalette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous))
        .accessibilityLabel(Text("Live ECG trace"))
    }
}

/// A saved reading laid out like a printout: rows of whole seconds on one continuous sheet of paper.
struct EcgPrintout: View {
    let samples: [Int16?]
    /// One row in millimetres; 20 mm is ±1 mV, and a taller beat may reach into the next row, as on paper.
    var rowMillimeters: CGFloat = 20
    @State private var width: CGFloat = 0

    struct Layout: Equatable {
        let paper: CGFloat
        let secondsPerRow: Int
        let rows: Int
    }

    /// Whole seconds per row near the target scale, then the scale that makes those seconds fill the width.
    static func layout(width: CGFloat, sampleCount: Int) -> Layout {
        let target = EcgPaper.targetPointsPerMillimeter * EcgPaper.millimetersPerSecond
        let seconds = max(2, Int((width / target).rounded()))
        let perRow = seconds * EcgPaper.sampleRate
        return Layout(paper: max(1, width) / (CGFloat(seconds) * EcgPaper.millimetersPerSecond),
                      secondsPerRow: seconds, rows: max(1, (sampleCount + perRow - 1) / perRow))
    }

    var body: some View {
        let layout = Self.layout(width: width, sampleCount: samples.count)
        let paper = EcgPaper(pointsPerMillimeter: layout.paper)
        let rowHeight = rowMillimeters * layout.paper
        Canvas { context, size in
            paper.drawGrid(in: &context, size: size)
            let signal = EcgSignal.centered(samples)
            let perRow = layout.secondsPerRow * EcgPaper.sampleRate
            for row in 0..<layout.rows {
                let lo = row * perRow
                let hi = min(signal.count, lo + perRow)
                guard lo < hi else { break }
                let top = CGFloat(row) * rowHeight
                paper.drawTrace(signal[lo..<hi], in: &context, originX: 0, baselineY: top + rowHeight / 2)
                let label = Text("\(row * layout.secondsPerRow) s")
                    .font(StrandFont.diagramLabel)
                    .foregroundStyle(StrandPalette.textTertiary)
                context.draw(label, at: CGPoint(x: 4, y: top + 4), anchor: .topLeading)
            }
        }
        .frame(height: width > 0 ? CGFloat(layout.rows) * rowHeight : 160)
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChangeCompat(of: proxy.size.width) { width = $0 }
            }
        )
        .background(StrandPalette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous))
        .accessibilityLabel(Text("ECG trace"))
    }
}
