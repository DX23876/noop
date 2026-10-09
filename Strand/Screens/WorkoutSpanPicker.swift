import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Workout span picker (HR curve on the workout sheet)
//
// Shows the strap's heart rate around the session being logged, shades the chosen span, marks the windows
// the published detector finds on that day, and lets the wearer set the span on the curve itself: drag a
// handle to move the start or the end, drag inside the span to shift it whole, drag anywhere else to draw a
// new one. The Start / End pickers below stay the precise input; both edit the same `start` / `end`.
//
// Retroactive by design: the strap banks HR around the clock, so a walk nobody started a session for can
// still be found and logged later, as far back as the raw HR is kept. Purely a view over existing reads;
// saving goes through the sheet's own validated path.

struct WorkoutSpanPicker: View {
    let repo: Repository
    @Binding var start: Date
    @Binding var end: Date
    /// The row being edited, so its own window is not excluded from the suggestions.
    let editing: WorkoutRow?

    enum Scope: Hashable { case focus, day }

    private static let chartSpace = "workoutSpanChart"
    /// Two fill strengths only: faint for the detector's bands, stronger for the chosen span.
    private static let bandOpacity = 0.12
    private static let fillOpacity = 0.2

    @State private var scope: Scope = .focus
    @State private var viewport: ClosedRange<Date>
    @State private var buckets: [HRBucket] = []
    @State private var loadedViewport: ClosedRange<Date>?
    @State private var suggestions: [DetectedWorkout] = []
    @State private var drag: DragMode?

    enum DragMode {
        case start, end
        case move(grabOffset: TimeInterval, length: TimeInterval)
        case create(anchor: Date)
    }

    init(repo: Repository, start: Binding<Date>, end: Binding<Date>, editing: WorkoutRow?) {
        self.repo = repo
        _start = start
        _end = end
        self.editing = editing
        _viewport = State(initialValue: Self.focusViewport(start: start.wrappedValue, end: end.wrappedValue,
                                                           now: Date()))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(alignment: .firstTextBaseline) {
                Text("Heart rate").strandOverline()
                Spacer()
                Picker("", selection: $scope) {
                    Text("Session").tag(Scope.focus)
                    Text("Whole day").tag(Scope.day)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Time range shown")
            }

            chart
                .frame(height: 160)

            Text(readout)
                .font(StrandFont.footnote)
                .monospacedDigit()
                .foregroundStyle(StrandPalette.textSecondary)
                .contentTransition(.numericText())
                .accessibilityLabel(readout)

            if !suggestions.isEmpty { suggestionRow }

            Text("Drag the edges to adjust, or drag across the curve to mark a new span.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: ViewportKey(viewport)) { await loadBuckets(for: viewport) }
        .task(id: Calendar.current.startOfDay(for: start)) {
            suggestions = await repo.workoutSpanSuggestions(day: start, excluding: editing)
        }
        .onChangeCompat(of: scope) { _ in refreshViewport(force: true) }
        // A change from the pickers or a suggestion re-frames the curve; a drag keeps it still until it ends.
        .onChangeCompat(of: SpanKey(start: start, end: end)) { _ in
            if drag == nil { refreshViewport(force: false) }
        }
    }

    // MARK: - Chart

    private var chart: some View {
        let points = buckets.filter { $0.sampleSeconds > 0 }
        let values = points.map(\.bpm)
        let lo = max(30, (values.min() ?? 60) - 8)
        let hi = max(lo + 20, (values.max() ?? 160) + 8)
        return Chart {
            ForEach(suggestions, id: \.startSec) { s in
                RectangleMark(
                    xStart: .value("Start", Date(timeIntervalSince1970: TimeInterval(s.startSec))),
                    xEnd: .value("End", Date(timeIntervalSince1970: TimeInterval(s.endSec))),
                    yStart: .value("Low", lo), yEnd: .value("High", hi))
                .foregroundStyle(StrandPalette.accent.opacity(Self.bandOpacity))
            }
            RectangleMark(
                xStart: .value("Start", clamp(start)), xEnd: .value("End", clamp(end)),
                yStart: .value("Low", lo), yEnd: .value("High", hi))
            .foregroundStyle(StrandPalette.effortColor.opacity(Self.fillOpacity))
            ForEach(points, id: \.ts) { b in
                AreaMark(x: .value("Time", Date(timeIntervalSince1970: TimeInterval(b.ts))),
                         yStart: .value("Low", lo), yEnd: .value("HR", b.bpm))
                .foregroundStyle(StrandPalette.effortGradient.opacity(Self.fillOpacity))
                .interpolationMethod(.monotone)
                LineMark(x: .value("Time", Date(timeIntervalSince1970: TimeInterval(b.ts))),
                         y: .value("HR", b.bpm))
                .foregroundStyle(StrandPalette.effortColor)
                .lineStyle(StrokeStyle(lineWidth: 1.6))
                .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: viewport)
        .chartYScale(domain: lo...hi)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel().font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                ZStack(alignment: .topLeading) {
                    handle(at: start, proxy: proxy, plot: plot)
                    handle(at: end, proxy: proxy, plot: plot)
                    if points.isEmpty, loadedViewport == viewport {
                        Text("No heart rate stored for this time.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .position(x: plot.midX, y: plot.midY)
                    }
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: plot.width, height: plot.height)
                        .offset(x: plot.minX, y: plot.minY)
                        .gesture(dragGesture(proxy: proxy, plot: plot))
                }
                // Drag locations in the same space as `plot`, not the offset hit area's own.
                .coordinateSpace(name: Self.chartSpace)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heart rate curve with the selected workout span")
        .accessibilityValue(readout)
    }

    /// A vertical bar with a grip at the span's edge. Hidden when the edge lies outside the visible range.
    @ViewBuilder
    private func handle(at date: Date, proxy: ChartProxy, plot: CGRect) -> some View {
        if viewport.contains(date), let x = proxy.position(forX: date) {
            let cx = x + plot.minX
            ZStack {
                Rectangle()
                    .fill(StrandPalette.effortColor)
                    .frame(width: 2, height: plot.height)
                Capsule()
                    .fill(StrandPalette.effortColor)
                    .frame(width: 8, height: 24)
                    .overlay(Capsule().stroke(StrandPalette.surfaceBase, lineWidth: 2))
            }
            .position(x: cx, y: plot.midY)
            .allowsHitTesting(false)
        }
    }

    private func dragGesture(proxy: ChartProxy, plot: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.chartSpace))
            .onChanged { value in
                guard let at = date(atX: value.location.x, proxy: proxy, plot: plot) else { return }
                if drag == nil {
                    drag = Self.dragMode(beganAt: value.startLocation.x, start: start, end: end,
                                         proxy: proxy, plot: plot,
                                         startDate: date(atX: value.startLocation.x, proxy: proxy, plot: plot) ?? at)
                }
                guard let mode = drag else { return }
                let span = Self.applyDrag(mode, at: at, start: start, end: end, bounds: viewport)
                start = span.start
                end = span.end
            }
            .onEnded { _ in
                drag = nil
                // Re-frame the curve around where the span ended up, so a span dragged against the edge can
                // be pulled further on the next drag.
                refreshViewport(force: scope == .focus)
            }
    }

    private func date(atX x: CGFloat, proxy: ChartProxy, plot: CGRect) -> Date? {
        let relX = min(max(x - plot.minX, 0), plot.width)
        return proxy.value(atX: relX)
    }

    /// What a drag starting at `x` does: grab a handle within reach, shift the span from inside it, or draw
    /// a new span from anywhere else.
    private static func dragMode(beganAt x: CGFloat, start: Date, end: Date, proxy: ChartProxy, plot: CGRect,
                                 startDate: Date) -> DragMode {
        let reach: CGFloat = 22
        let sx = proxy.position(forX: start).map { $0 + plot.minX }
        let ex = proxy.position(forX: end).map { $0 + plot.minX }
        let ds = sx.map { abs($0 - x) } ?? .infinity
        let de = ex.map { abs($0 - x) } ?? .infinity
        if min(ds, de) <= reach { return ds <= de ? .start : .end }
        if startDate > start, startDate < end {
            return .move(grabOffset: startDate.timeIntervalSince(start), length: end.timeIntervalSince(start))
        }
        return .create(anchor: startDate)
    }

    // MARK: - Span math (pure, minute-snapped)

    /// The span a drag produces. Every edge snaps to the whole minute, the span keeps at least one minute,
    /// and nothing reaches past now or outside the visible range.
    static func applyDrag(_ mode: DragMode, at raw: Date, start: Date, end: Date,
                          bounds: ClosedRange<Date>, now: Date = Date()) -> (start: Date, end: Date) {
        let minSpan = TimeInterval(WorkoutSource.minManualSpanSeconds)
        let upper = min(bounds.upperBound, now)
        let at = snap(min(max(raw, bounds.lowerBound), upper))
        switch mode {
        case .start:
            return (min(at, end.addingTimeInterval(-minSpan)), end)
        case .end:
            return (start, max(at, start.addingTimeInterval(minSpan)))
        case let .move(grabOffset, length):
            var s = snap(raw.addingTimeInterval(-grabOffset))
            s = max(s, bounds.lowerBound)
            s = min(s, upper.addingTimeInterval(-length))
            return (s, s.addingTimeInterval(length))
        case let .create(anchor):
            let a = snap(anchor)
            let lo = min(a, at), hi = max(a, at)
            if hi.timeIntervalSince(lo) >= minSpan { return (lo, hi) }
            let s = min(lo, upper.addingTimeInterval(-minSpan))
            return (s, s.addingTimeInterval(minSpan))
        }
    }

    private static func snap(_ d: Date) -> Date {
        Date(timeIntervalSince1970: (d.timeIntervalSince1970 / 60).rounded() * 60)
    }

    /// The span with padding on both sides: at least 45 minutes or half its length, never past now, and at
    /// least two hours wide so a short session still shows what came before and after it.
    static func focusViewport(start: Date, end: Date, now: Date) -> ClosedRange<Date> {
        let length = max(end.timeIntervalSince(start), 60)
        let pad = max(45 * 60, length * 0.5)
        let hi = min(end.addingTimeInterval(pad), now)
        var lo = min(start.addingTimeInterval(-pad), hi.addingTimeInterval(-60))
        if hi.timeIntervalSince(lo) < 2 * 3600 { lo = hi.addingTimeInterval(-2 * 3600) }
        return lo...hi
    }

    /// The calendar day of `start`, cut at now when that day is today.
    static func dayViewport(start: Date, now: Date) -> ClosedRange<Date> {
        let cal = Calendar.current
        let lo = cal.startOfDay(for: start)
        let next = cal.date(byAdding: .day, value: 1, to: lo) ?? lo.addingTimeInterval(86_400)
        let hi = max(min(next, now), lo.addingTimeInterval(3600))
        return lo...hi
    }

    private func refreshViewport(force: Bool) {
        let now = Date()
        switch scope {
        case .focus:
            let inside = viewport.contains(start) && viewport.contains(end)
            if force || !inside { viewport = Self.focusViewport(start: start, end: end, now: now) }
        case .day:
            let day = Self.dayViewport(start: start, now: now)
            if force || day.lowerBound != viewport.lowerBound { viewport = day }
        }
    }

    private func clamp(_ d: Date) -> Date { min(max(d, viewport.lowerBound), viewport.upperBound) }

    // MARK: - Data

    private func loadBuckets(for range: ClosedRange<Date>) async {
        let from = Int(range.lowerBound.timeIntervalSince1970)
        let to = Int(range.upperBound.timeIntervalSince1970)
        // About 150 points across the range: one-minute detail for a session, five minutes for a whole day.
        let bucket = min(300, max(60, (to - from) / 150))
        let loaded = await repo.hrBuckets(from: from, to: to, bucketSeconds: bucket)
        guard !Task.isCancelled else { return }
        buckets = loaded
        loadedViewport = range
    }

    // MARK: - Readout + suggestions

    /// "14:05 to 14:47 · 42 min · avg 132 bpm · max 151 bpm" over the HR inside the span.
    private var readout: String {
        let fmt = AppClock.hourMinuteFormatter()
        let s = fmt.string(from: start), e = fmt.string(from: end)
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        let inSpan = buckets.filter {
            $0.sampleSeconds > 0
                && $0.ts >= Int(start.timeIntervalSince1970) && $0.ts < Int(end.timeIntervalSince1970)
        }
        let seconds = inSpan.reduce(0) { $0 + $1.sampleSeconds }
        guard seconds > 0 else { return String(localized: "\(s) to \(e) · \(minutes) min") }
        let avg = Int((inSpan.reduce(0.0) { $0 + $1.bpm * Double($1.sampleSeconds) } / Double(seconds)).rounded())
        let peak = Int((inSpan.map(\.maxBpm).max() ?? 0).rounded())
        return String(localized: "\(s) to \(e) · \(minutes) min · avg \(avg) bpm · max \(peak) bpm")
    }

    private var suggestionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Spotted on this day").strandOverline()
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: NoopMetrics.space2) {
                    ForEach(suggestions, id: \.startSec) { s in
                        suggestionChip(s)
                    }
                }
            }
        }
    }

    private func suggestionChip(_ s: DetectedWorkout) -> some View {
        let fmt = AppClock.hourMinuteFormatter()
        let sDate = Date(timeIntervalSince1970: TimeInterval(s.startSec))
        let eDate = Date(timeIntervalSince1970: TimeInterval(s.endSec))
        let selected = Int(start.timeIntervalSince1970) == s.startSec && Int(end.timeIntervalSince1970) == s.endSec
        let label = String(localized: "\(fmt.string(from: sDate)) to \(fmt.string(from: eDate)) · avg \(s.avgBpm)")
        return Button {
            start = sDate
            end = eDate
            refreshViewport(force: true)
        } label: {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(selected ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                .padding(.horizontal, NoopMetrics.space3).padding(.vertical, NoopMetrics.space2)
                .background(selected ? StrandPalette.effortColor.opacity(Self.fillOpacity) : StrandPalette.surfaceInset,
                            in: Capsule())
                .overlay(Capsule().strokeBorder(StrandPalette.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Use the span \(label)")
    }
}

/// Task / change keys: `ClosedRange<Date>` and tuples are not Hashable / Equatable on their own.
private struct ViewportKey: Hashable {
    let lo: Date, hi: Date
    init(_ r: ClosedRange<Date>) { lo = r.lowerBound; hi = r.upperBound }
}

private struct SpanKey: Equatable {
    let start: Date, end: Date
}
