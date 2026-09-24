import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - Training history (P5)
//
// Months and years of each lane in its own unit: a bar per period, the lane's 42-day level for a period
// that long as a dashed line, the band the Training Load screen showed at the time as a strip above, and
// what the training did beside it (e1RM of the chosen lifts, VO₂max). Days the data could not price are
// hatched rather than drawn as rest. Lanes stand next to each other and are never summed.

struct TrainingHistoryView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = TrainingHistoryModel()
    @State private var focus: TrainingHistoryFocus
    @AppStorage("trainingHistory.span") private var spanRaw = TrainingHistorySpan.oneYear.rawValue
    @AppStorage(TrainingHistoryModel.liftsKey) private var liftsRaw = ""
    /// The day jumped to, nil for today.
    @State private var jumpDay: String?

    init(focus: TrainingHistoryFocus = .all) {
        _focus = State(initialValue: focus)
    }

    private var span: TrainingHistorySpan { TrainingHistorySpan(rawValue: spanRaw) ?? .oneYear }
    private var chosenLifts: [String] { liftsRaw.split(separator: "\n").map(String.init) }

    private struct BuildKey: Hashable {
        let loaded: Bool
        let span: TrainingHistorySpan
        let jump: String?
        let lifts: String
    }

    var body: some View {
        ScreenScaffold(title: "Training history",
                       subtitle: "Each lane over months and years, in its own unit.") {
            controls
            if model.source == nil {
                ProgressView().frame(maxWidth: .infinity)
            } else if let built = model.built {
                content(built)
            }
        }
        .task { await model.load(repo: repo) }
        .task(id: BuildKey(loaded: model.source != nil, span: span, jump: jumpDay, lifts: liftsRaw)) {
            guard let source = model.source else { return }
            let end = TrainingHistoryModel.end(for: span, jumpedTo: jumpDay, today: source.today)
            await model.build(span: span, end: end, lifts: chosenLifts)
        }
    }

    // MARK: Controls

    private var controls: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Picker("Lanes", selection: $focus) {
                    Text("All").tag(TrainingHistoryFocus.all)
                    Text("Strength").tag(TrainingHistoryFocus.strength)
                    Text("Cardio").tag(TrainingHistoryFocus.cardio)
                    Text("Session load").tag(TrainingHistoryFocus.session)
                }
                .pickerStyle(.segmented)
                Picker("Span", selection: $spanRaw) {
                    Text("3 M").tag(TrainingHistorySpan.threeMonths.rawValue)
                    Text("1 Y").tag(TrainingHistorySpan.oneYear.rawValue)
                    Text("5 Y").tag(TrainingHistorySpan.fiveYears.rawValue)
                    Text("All").tag(TrainingHistorySpan.all.rawValue)
                }
                .pickerStyle(.segmented)
                jumpRow
            }
        }
    }

    @ViewBuilder private var jumpRow: some View {
        if let source = model.source, let earliest = source.earliest,
           let first = TrainingHistoryDates.date(earliest), let last = TrainingHistoryDates.date(source.today),
           first < last {
            HStack(spacing: NoopMetrics.space3) {
                DatePicker("Jump to date",
                           selection: Binding(
                               get: { jumpDay.flatMap(TrainingHistoryDates.date) ?? last },
                               set: { jumpDay = TrainingHistoryDates.day($0) }),
                           in: first...last, displayedComponents: .date)
                    .font(StrandFont.subhead)
                if jumpDay != nil {
                    Button("Today") { jumpDay = nil }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: Lanes

    @ViewBuilder private func content(_ built: TrainingHistoryModel.Built) -> some View {
        let highlight = jumpDay.flatMap { TrainingHistory.period(containing: $0, in: built.periods) }
        let shows = focus.shows
        if shows.strength {
            TrainingHistoryLaneCard(
                lane: .strength, title: String(localized: "Strength"),
                unit: String(localized: "weighted sets"), range: built.range, periods: built.strength,
                highlight: highlight, format: { $0.formatted(.number.precision(.fractionLength(0))) }) {
                    TrainingHistoryLiftChart(lifts: built.lifts, range: built.range)
                    liftMenu
                }
        }
        if shows.cardio {
            TrainingHistoryLaneCard(
                lane: .cardio, title: String(localized: "Cardio"), unit: "TRIMP", range: built.range,
                periods: built.cardio, highlight: highlight,
                format: { $0.formatted(.number.precision(.fractionLength(0))) }) {
                    TrainingHistoryVO2Chart(estimates: built.vo2, apple: built.vo2Apple, range: built.range)
                }
        }
        if shows.session {
            TrainingHistoryLaneCard(
                lane: nil, title: String(localized: "Session load"), unit: String(localized: "RPE × minutes"),
                range: built.range, periods: built.session, highlight: highlight,
                format: { $0.formatted(.number.precision(.fractionLength(0))) }) {
                    EmptyView()
                }
        }
        explainer
    }

    /// Up to three lifts; choosing none returns to the three most trained in the span.
    private var liftMenu: some View {
        Menu {
            ForEach(model.liftChoices.prefix(30)) { choice in
                Button {
                    toggle(choice.id)
                } label: {
                    if chosenLifts.contains(choice.id) {
                        Label(choice.title, systemImage: "checkmark")
                    } else {
                        Text(choice.title)
                    }
                }
                .disabled(!chosenLifts.contains(choice.id) && chosenLifts.count >= TrainingHistory.defaultLiftCount)
            }
            if !chosenLifts.isEmpty {
                Divider()
                Button("Most trained") { liftsRaw = "" }
            }
        } label: {
            Label(chosenLifts.isEmpty ? String(localized: "Lifts: most trained") : String(localized: "Lifts: your choice"),
                  systemImage: "slider.horizontal.3")
                .font(StrandFont.caption)
        }
        .fixedSize()
    }

    private func toggle(_ id: String) {
        var lifts = chosenLifts
        if let index = lifts.firstIndex(of: id) {
            lifts.remove(at: index)
        } else if lifts.count < TrainingHistory.defaultLiftCount {
            lifts.append(id)
        }
        liftsRaw = lifts.joined(separator: "\n")
    }

    private var explainer: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("How to read this").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                Text("Bars are each period's total in the lane's own unit. The dashed line is your 42-day level for a period that long, so a bar above it was a heavier stretch than you were used to at the time.")
                Text("The strip above the bars is the band Training Load showed at the end of each period. Hatched periods held training the data could not measure — a gap, not rest.")
                Text("The three lanes are never added together: a hard set, a heart-rate load and your own rating measure different things.")
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Dates

/// Day keys to local-midnight dates and back, so the charts' axes read in the wearer's own calendar.
enum TrainingHistoryDates {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ day: String) -> Date? { formatter.date(from: day) }
    static func day(_ date: Date) -> String { formatter.string(from: date) }

    /// The period's start and the midnight after its last day.
    static func bounds(_ period: TrainingHistoryPeriod) -> (Date, Date)? {
        guard let start = date(period.start), let end = date(WeeklyDigestEngine.addDays(period.end, 1)) else {
            return nil
        }
        return (start, end)
    }

    static func mid(_ period: TrainingHistoryPeriod) -> Date? {
        bounds(period).map { $0.0.addingTimeInterval($0.1.timeIntervalSince($0.0) / 2) }
    }

    static func domain(_ range: TrainingHistoryRange) -> ClosedRange<Date> {
        let start = date(range.first) ?? Date()
        let end = date(WeeklyDigestEngine.addDays(range.last, 1)) ?? start.addingTimeInterval(86_400)
        return start...max(end, start.addingTimeInterval(86_400))
    }

    /// "3 Mar 2025", "Week of 3 Mar 2025", "March 2025".
    static func label(_ period: TrainingHistoryPeriod, _ resolution: TrainingHistoryResolution) -> String {
        guard let start = date(period.start) else { return period.start }
        switch resolution {
        case .day: return start.formatted(.dateTime.day().month(.abbreviated).year())
        case .week:
            let day = start.formatted(.dateTime.day().month(.abbreviated).year())
            return String(localized: "Week of \(day)")
        case .month: return start.formatted(.dateTime.month(.wide).year())
        }
    }
}

// MARK: - One lane

struct TrainingHistoryLaneCard<Adaptation: View>: View {
    /// Nil for Session Load, which has no band and no lane colour of its own.
    let lane: TrainingLane?
    let title: String
    let unit: String
    let range: TrainingHistoryRange
    let periods: [TrainingHistoryLanePeriod]
    let highlight: TrainingHistoryPeriod?
    let format: (Double) -> String
    @ViewBuilder let adaptation: () -> Adaptation

    private var color: Color { lane?.color ?? StrandPalette.textSecondary }
    private var recorded: [TrainingHistoryLanePeriod] {
        periods.filter { $0.knownDays + $0.unknownDays + $0.estimatedDays > 0 }
    }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                header
                adaptation()
                if recorded.isEmpty {
                    Text("Nothing recorded in this span yet.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                } else {
                    if lane != nil { TrainingHistoryBandStrip(periods: periods, range: range) }
                    TrainingHistoryBars(periods: periods, range: range, color: color, highlight: highlight)
                    detail
                    footnote
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: lane?.symbol ?? "hand.raised.fill")
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Spacer()
            Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// The period jumped to, in words.
    @ViewBuilder private var detail: some View {
        if let highlight, let entry = periods.first(where: { $0.period == highlight }) {
            let parts = [TrainingHistoryDates.label(entry.period, range.resolution),
                         entry.total.map { "\(format($0)) \(unit)" } ?? String(localized: "not measured"),
                         entry.estimatedTotal.map { String(localized: "\(format($0)) estimated") },
                         entry.band?.label,
                         entry.unknownDays > 0 ? String(localized: "\(entry.unknownDays) days not measured") : nil]
            Text(parts.compactMap { $0 }.joined(separator: " · "))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
        }
    }

    @ViewBuilder private var footnote: some View {
        let gaps = recorded.filter { $0.unknownDays > 0 }.count
        let estimated = recorded.filter { $0.estimatedDays > 0 }.count
        let measured = recorded.compactMap(\.measured).reduce(0, +)
        let possible = recorded.compactMap(\.possible).reduce(0, +)
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            if possible > 0 {
                Text("Rated: \(measured) of \(possible) sessions in this span")
            }
            if gaps > 0 {
                Text("\(gaps) of \(recorded.count) periods include days that could not be measured (hatched).")
            }
            if estimated > 0 {
                Text("Pale tops are estimated from a workout's average heart rate, where no heart-rate trace was kept. They are not counted in the level or the band.")
            }
        }
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textTertiary)
    }
}

// MARK: - Bars, level and gaps

struct TrainingHistoryBars: View {
    let periods: [TrainingHistoryLanePeriod]
    let range: TrainingHistoryRange
    let color: Color
    let highlight: TrainingHistoryPeriod?

    private struct Bar: Identifiable {
        let id: String
        let start: Date
        let end: Date
        let mid: Date
        let total: Double?
        /// Estimated from average heart rate, drawn on top of the measured part and marked.
        let estimated: Double?
        let level: Double?
        let gapShare: Double
    }

    private var bars: [Bar] {
        periods.compactMap { entry in
            guard let (start, end) = TrainingHistoryDates.bounds(entry.period),
                  let mid = TrainingHistoryDates.mid(entry.period) else { return nil }
            let recorded = entry.knownDays + entry.unknownDays + entry.estimatedDays
            let inset = end.timeIntervalSince(start) * 0.12
            return Bar(id: entry.period.start, start: start.addingTimeInterval(inset),
                       end: end.addingTimeInterval(-inset), mid: mid, total: entry.total,
                       estimated: entry.estimatedTotal, level: entry.level,
                       gapShare: recorded > 0 ? Double(entry.unknownDays) / Double(recorded) : 0)
        }
    }

    var body: some View {
        let bars = self.bars
        Chart {
            ForEach(bars) { bar in
                if let total = bar.total {
                    RectangleMark(xStart: .value("Start", bar.start), xEnd: .value("End", bar.end),
                                  yStart: .value("Zero", 0), yEnd: .value("Load", total))
                        .foregroundStyle(color.gradient)
                        .opacity(bar.gapShare > 0 ? 0.55 : 1)
                }
                if let estimated = bar.estimated, estimated > 0 {
                    RectangleMark(xStart: .value("Start", bar.start), xEnd: .value("End", bar.end),
                                  yStart: .value("Zero", bar.total ?? 0),
                                  yEnd: .value("Estimated", (bar.total ?? 0) + estimated))
                        .foregroundStyle(color.opacity(0.28))
                }
            }
            ForEach(bars.filter { $0.level != nil }) { bar in
                LineMark(x: .value("Period", bar.mid), y: .value("Level", bar.level ?? 0))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .interpolationMethod(.monotone)
            }
            if let highlight, let mid = TrainingHistoryDates.mid(highlight) {
                RuleMark(x: .value("Selected", mid))
                    .foregroundStyle(StrandPalette.textPrimary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: TrainingHistoryDates.domain(range))
        .chartBackground { proxy in
            GeometryReader { geo in
                let plot = Self.plotRect(proxy, geo)
                ForEach(bars.filter { $0.gapShare > 0 }) { bar in
                    if let a = proxy.position(forX: bar.start), let b = proxy.position(forX: bar.end) {
                        DiagonalHatch(spacing: 5)
                            .stroke(StrandPalette.textTertiary.opacity(0.25 + 0.35 * bar.gapShare), lineWidth: 1)
                            .frame(width: max(2, b - a), height: plot.height)
                            .clipped()
                            .position(x: plot.minX + (a + b) / 2, y: plot.midY)
                    }
                }
            }
        }
        .frame(height: NoopMetrics.chartHeight * 0.8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Load per period"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    private var accessibilitySummary: String {
        let totals = periods.compactMap(\.total)
        guard let peak = totals.max() else { return String(localized: "not measured") }
        let peakText = peak.formatted(.number.precision(.fractionLength(0)))
        return String(localized: "\(totals.count) periods, highest \(peakText)")
    }

    static func plotRect(_ proxy: ChartProxy, _ geo: GeometryProxy) -> CGRect {
        if #available(iOS 17.0, macOS 14.0, *) {
            return proxy.plotFrame.map { geo[$0] } ?? .zero
        }
        return geo[proxy.plotAreaFrame]
    }
}

// MARK: - Band strip

struct TrainingHistoryBandStrip: View {
    let periods: [TrainingHistoryLanePeriod]
    let range: TrainingHistoryRange

    var body: some View {
        Chart {
            ForEach(periods.filter { $0.band != nil }, id: \.period) { entry in
                if let (start, end) = TrainingHistoryDates.bounds(entry.period), let band = entry.band {
                    RectangleMark(xStart: .value("Start", start), xEnd: .value("End", end),
                                  yStart: .value("Bottom", 0), yEnd: .value("Top", 1))
                        .foregroundStyle(band.color)
                }
            }
        }
        .chartXScale(domain: TrainingHistoryDates.domain(range))
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Band at the end of each period"))
        .accessibilityValue(Text(periods.compactMap { $0.band?.label }.suffix(6).joined(separator: ", ")))
    }
}

// MARK: - What the training did

struct TrainingHistoryLiftChart: View {
    let lifts: [TrainingHistoryModel.Lift]
    let range: TrainingHistoryRange

    private struct Point: Identifiable {
        let id: String
        let lift: String
        let date: Date
        let value: Double
    }

    private var points: [Point] {
        lifts.flatMap { lift in
            lift.values.compactMap { entry -> Point? in
                guard let value = entry.value, let mid = TrainingHistoryDates.mid(entry.period) else { return nil }
                return Point(id: lift.id + entry.period.start, lift: lift.title, date: mid, value: value)
            }
        }
    }

    var body: some View {
        let points = self.points
        if points.isEmpty {
            Text("No lift with an e1RM in this span.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text("e1RM of your lifts (kg)")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Chart(points) { point in
                    LineMark(x: .value("Period", point.date), y: .value("e1RM", point.value),
                             series: .value("Lift", point.lift))
                        .foregroundStyle(by: .value("Lift", point.lift))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Period", point.date), y: .value("e1RM", point.value))
                        .foregroundStyle(by: .value("Lift", point.lift))
                        .symbolSize(14)
                }
                .chartForegroundStyleScale(range: [StrandPalette.strengthColor, StrandPalette.strengthBright,
                                                   StrandPalette.strengthDeep])
                .chartXScale(domain: TrainingHistoryDates.domain(range))
                .chartYScale(domain: .automatic(includesZero: false))
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 130)
            }
        }
    }
}

struct TrainingHistoryVO2Chart: View {
    let estimates: [TrainingHistoryValue]
    let apple: [TrainingHistoryValue]
    let range: TrainingHistoryRange

    private struct Point: Identifiable {
        let id: String
        let date: Date
        let value: Double
    }

    private func points(_ values: [TrainingHistoryValue]) -> [Point] {
        values.compactMap { entry in
            guard let value = entry.value, let mid = TrainingHistoryDates.mid(entry.period) else { return nil }
            return Point(id: entry.period.start, date: mid, value: value)
        }
    }

    var body: some View {
        let noop = points(estimates)
        let watch = points(apple)
        if noop.isEmpty && watch.isEmpty {
            Text("No VO₂max in this span.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        } else {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text("VO₂max (ml/kg/min) — line: NOOP estimate · dots: Apple Watch")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Chart {
                    ForEach(noop) { point in
                        LineMark(x: .value("Period", point.date), y: .value("VO₂max", point.value),
                                 series: .value("Source", "NOOP"))
                            .foregroundStyle(StrandPalette.cardioColor)
                            .interpolationMethod(.monotone)
                    }
                    ForEach(watch) { point in
                        PointMark(x: .value("Period", point.date), y: .value("VO₂max", point.value))
                            .foregroundStyle(StrandPalette.textSecondary)
                            .symbolSize(16)
                    }
                }
                .chartXScale(domain: TrainingHistoryDates.domain(range))
                .chartYScale(domain: .automatic(includesZero: false))
                .frame(height: 110)
            }
        }
    }
}

// MARK: - Entry points

/// Opens the history on a lane: pushed on iOS, a sheet on macOS, whose detail column has no navigation
/// stack to push onto.
struct TrainingHistoryLink<Label: View>: View {
    let focus: TrainingHistoryFocus
    @ViewBuilder let label: () -> Label
    @EnvironmentObject private var repo: Repository
    @State private var presented = false

    var body: some View {
        #if os(iOS)
        NavigationLink {
            TrainingHistoryView(focus: focus)
        } label: {
            label()
        }
        .buttonStyle(.plain)
        #else
        Button { presented = true } label: { label() }
            .buttonStyle(.plain)
            .sheet(isPresented: $presented) {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button("Done") { presented = false }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding([.top, .horizontal], NoopMetrics.space3)
                    TrainingHistoryView(focus: focus)
                }
                .frame(minWidth: NoopMetrics.detailSheetMinWidth * 1.5, minHeight: NoopMetrics.detailSheetMinHeight * 1.15)
                .environmentObject(repo)
            }
        #endif
    }
}

/// The row every entry point shows.
struct TrainingHistoryRow: View {
    let subtitle: String

    var body: some View {
        NoopCard {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: "calendar.badge.clock")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text("Training history").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}
