import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - Shared building blocks for Training Load, Cardio and Strength
//
// One visual grammar for three screens that answer different questions. The blocks take finished
// values; each screen decides what goes in them and in which order.

/// The two training lanes and the identity each carries on every screen.
enum TrainingLane: Sendable {
    case strength, cardio

    var color: Color { self == .strength ? StrandPalette.strengthColor : StrandPalette.cardioColor }
    var deep: Color { self == .strength ? StrandPalette.strengthDeep : StrandPalette.cardioDeep }
    var bright: Color { self == .strength ? StrandPalette.strengthBright : StrandPalette.cardioBright }
    var symbol: String { self == .strength ? "figure.strengthtraining.traditional" : "heart.fill" }
    var title: String {
        self == .strength ? String(localized: "Strength") : String(localized: "Cardio")
    }
    /// Deep to base, never to bright: white text has to stay readable across the whole fill.
    var fill: LinearGradient {
        LinearGradient(colors: [deep, color], startPoint: .leading, endPoint: .trailing)
    }
}

// MARK: - Status pill

/// Where a lane's last seven days sit against the wearer's usual. The words carry the state; the
/// colour only says which lane it belongs to.
enum LoadPillState: Equatable, Sendable {
    case below, usual, higher, muchHigher, provisional, noComparison

    static func of(_ lane: TrainingLoadModel.Lane?, provisional: Bool = false) -> LoadPillState {
        switch lane?.status?.band {
        case .below: return .below
        case .maintaining: return .usual
        case .productive: return .higher
        case .above: return .muchHigher
        case nil: return provisional ? .provisional : .noComparison
        }
    }

    var hasComparison: Bool { self != .provisional && self != .noComparison }

    var label: String {
        switch self {
        case .below: return String(localized: "Below usual")
        case .usual: return String(localized: "About usual")
        case .higher: return String(localized: "Above usual")
        case .muchHigher: return String(localized: "Well above usual")
        case .provisional: return String(localized: "Provisional")
        case .noComparison: return String(localized: "No comparison yet")
        }
    }

    var symbol: String {
        switch self {
        case .below: return "arrow.down.right"
        case .usual: return "equal"
        case .higher: return "arrow.up.right"
        case .muchHigher: return "chevron.up.2"
        case .provisional: return "sparkles"
        case .noComparison: return "hourglass"
        }
    }
}

struct LoadStatusPill: View {
    let lane: TrainingLane
    let state: LoadPillState

    var body: some View {
        Label(state.label, systemImage: state.symbol)
            .font(StrandFont.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(state.hasComparison ? StrandPalette.onDarkPrimary : StrandPalette.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                if state.hasComparison {
                    Capsule().fill(lane.fill)
                } else {
                    Capsule().fill(StrandPalette.surfaceInset)
                }
            }
    }
}

// MARK: - Formatting

enum LoadFormat {
    /// "+18 %", "−7 %", and "0 %" for a change that rounds to nothing, which has no direction.
    static func signedPercent(_ value: Double) -> String {
        let magnitude = Int(abs(value).rounded())
        guard magnitude > 0 else { return "0 %" }
        return "\(value > 0 ? "+" : "−")\(magnitude) %"
    }
}

/// A signed percentage that counts between values instead of jumping.
struct SignedPercentCountUp: View, Animatable {
    var value: Double
    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(verbatim: LoadFormat.signedPercent(value)).monospacedDigit()
    }
}

// MARK: - Hero

/// A lane-tinted card surface, saturated enough to carry the lane's identity at a glance.
struct LaneHeroSurface: View {
    let lane: TrainingLane
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
        // Lighter on a light background: the secondary text on top has to keep its contrast.
        let dark = scheme == .dark
        ZStack {
            shape.fill(StrandPalette.surfaceRaised)
            shape.fill(LinearGradient(colors: [lane.deep.opacity(dark ? 0.62 : 0.2),
                                               lane.color.opacity(dark ? 0.22 : 0.08)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.fill(RadialGradient(colors: [lane.bright.opacity(dark ? 0.28 : 0.22), .clear],
                                      center: .topTrailing, startRadius: 0, endRadius: 220))
        }
        .overlay(shape.strokeBorder(lane.color.opacity(0.45), lineWidth: 1))
        .shadow(color: lane.color.opacity(0.22), radius: 16, x: 0, y: 8)
    }
}

/// A lane's headline: the change against usual, its state, the measured figure behind it, and what the
/// reading rests on. `compact` fits half the width of a phone.
struct LoadHeroCard: View {
    let lane: TrainingLane
    var title: String? = nil
    let percent: Double?
    let state: LoadPillState
    var figure: String? = nil
    /// Daily ratios, oldest first; gaps are left out.
    var trend: [Double] = []
    var coverage: String? = nil
    var caveat: String? = nil
    var note: String? = nil
    var compact = false

    /// Nil until the value first changes, so the card opens on the real figure rather than counting up from zero.
    @State private var shownPercent: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? NoopMetrics.space2 : NoopMetrics.space3) {
            header
            HStack(alignment: .bottom, spacing: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    percentText
                    if percent != nil {
                        Text("vs. your usual")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                if !compact, trend.count >= 2 { sparkline }
            }
            if compact, trend.count >= 2 { sparkline }
            if let figure {
                Text(figure)
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let coverage {
                Text(coverage)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let caveat {
                Label {
                    Text(caveat).foregroundStyle(StrandPalette.textPrimary)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StrandPalette.statusWarning)
                }
                .font(StrandFont.caption)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let note {
                Label(note, systemImage: "info.circle")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(compact ? NoopMetrics.space3 : NoopMetrics.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LaneHeroSurface(lane: lane))
        .accessibilityElement(children: .combine)
        .onChangeCompat(of: percent) { newValue in
            let target = newValue ?? 0
            if shownPercent == nil { shownPercent = target }
            if reduceMotion { shownPercent = target } else { withAnimation(StrandMotion.drawIn) { shownPercent = target } }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: NoopMetrics.space2) {
                StatusBadge(symbol: lane.symbol, color: lane.color, size: compact ? 24 : 28)
                Text(title ?? lane.title)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: NoopMetrics.space1)
                if !compact { LoadStatusPill(lane: lane, state: state) }
            }
            if compact { LoadStatusPill(lane: lane, state: state) }
        }
    }

    @ViewBuilder private var percentText: some View {
        if percent != nil {
            SignedPercentCountUp(value: shownPercent ?? percent ?? 0)
                .font(StrandFont.number(compact ? 30 : 42, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityLabel(Text(verbatim: LoadFormat.signedPercent(percent ?? 0)))
        } else {
            Text(verbatim: "—")
                .font(StrandFont.number(compact ? 30 : 42, weight: .bold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var sparkline: some View {
        Sparkline(values: trend, gradient: Gradient(colors: [lane.deep, lane.bright]),
                  lineWidth: 2.5, showsArea: true, showsHead: true, showsHover: false)
            .frame(height: compact ? 34 : 48)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

// MARK: - KPI strip

struct KPIItem: Identifiable {
    let id: String
    let icon: String
    let value: String
    let label: String
    var caption: String? = nil
    var info: (() -> Void)? = nil
}

/// A row of a week's key figures. Up to four sit in one row; more wrap into rows of three.
struct KPIStrip: View {
    let lane: TrainingLane
    let items: [KPIItem]

    var body: some View {
        let columns = items.count <= 4 ? max(items.count, 1) : 3
        NoopCard(padding: NoopMetrics.space3) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: NoopMetrics.space2), count: columns),
                      alignment: .leading, spacing: NoopMetrics.space3) {
                ForEach(items) { item in cell(item) }
            }
        }
    }

    private func cell(_ item: KPIItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                ZStack {
                    Circle().fill(lane.color.opacity(0.2))
                    Image(systemName: item.icon)
                        .font(StrandFont.rounded(11, weight: .semibold))
                        .foregroundStyle(lane.color)
                }
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
                Spacer(minLength: 0)
                if let info = item.info {
                    Button(action: info) {
                        Image(systemName: "info.circle")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("What this means"))
                }
            }
            Text(item.value)
                .font(StrandFont.number(20, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(item.label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(item.caption ?? " ")
                .font(StrandFont.caption)
                .foregroundStyle(lane.bright)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(item.label): \(item.value)\(item.caption.map { ", " + $0 } ?? "")"))
    }
}

// MARK: - Load over time

enum LoadHistorySpan: String, CaseIterable, Identifiable, Sendable {
    case week, fourWeeks, twelveWeeks
    var id: String { rawValue }
    var label: String {
        switch self {
        case .week: return String(localized: "7D")
        case .fourWeeks: return String(localized: "4W")
        case .twelveWeeks: return String(localized: "12W")
        }
    }
}

/// The bars a load chart draws, worked out without SwiftUI so the windows can be tested.
enum LoadHistoryBuckets {
    struct Bar: Identifiable, Equatable, Sendable {
        /// First day the bar covers.
        let start: String
        /// Known load in the bar; nil for a day that has not happened yet.
        let value: Double?
        /// Part of the bar is training the data could not price, so the value is a lower bound.
        let containsUnknown: Bool
        /// The day or week the screen is reading.
        let isSelected: Bool
        var id: String { start }
    }

    /// `.week`: the seven days of the week containing `readingDay`. The other spans: whole Monday weeks,
    /// ending with that week, summed through `readingDay` for the week still running.
    static func bars(byDay: [String: Double], unknownDays: Set<String>, span: LoadHistorySpan,
                     readingDay: String) -> [Bar] {
        guard let monday = WeeklyDigestEngine.mondayOfWeek(containing: readingDay) else { return [] }
        switch span {
        case .week:
            return (0..<7).map { offset in
                let day = WeeklyDigestEngine.addDays(monday, offset)
                return Bar(start: day, value: day > readingDay ? nil : (byDay[day] ?? 0),
                           containsUnknown: unknownDays.contains(day), isSelected: day == readingDay)
            }
        case .fourWeeks, .twelveWeeks:
            let weeks = span == .fourWeeks ? 4 : 12
            return (0..<weeks).map { index in
                let start = WeeklyDigestEngine.addDays(monday, -7 * (weeks - 1 - index))
                var total = 0.0
                var unknown = false
                for offset in 0..<7 {
                    let day = WeeklyDigestEngine.addDays(start, offset)
                    guard day <= readingDay else { break }
                    total += byDay[day] ?? 0
                    unknown = unknown || unknownDays.contains(day)
                }
                return Bar(start: start, value: total, containsUnknown: unknown, isSelected: index == weeks - 1)
            }
        }
    }
}

/// A lane's load over time with a span switch. The usual-week band is drawn only on the weekly spans
/// and only once a personal range exists; a day has no usual.
struct LoadHistoryChart: View {
    let lane: TrainingLane
    let title: String
    let unit: String
    let byDay: [String: Double]
    var unknownDays: Set<String> = []
    let readingDay: String
    var usualWeek: ClosedRange<Double>? = nil

    @State private var span: LoadHistorySpan = .fourWeeks

    var body: some View {
        let bars = LoadHistoryBuckets.bars(byDay: byDay, unknownDays: unknownDays, span: span,
                                           readingDay: readingDay)
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(alignment: .center) {
                    Text(title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: NoopMetrics.space2)
                    SegmentedPillControl(LoadHistorySpan.allCases, selection: $span) { $0.label }
                }
                chart(bars)
                    .frame(height: 170)
                legend(bars)
            }
        }
    }

    @ViewBuilder private func chart(_ bars: [LoadHistoryBuckets.Bar]) -> some View {
        let band = span == .week ? nil : usualWeek
        Chart {
            if let band {
                RectangleMark(yStart: .value("Usual low", band.lowerBound),
                              yEnd: .value("Usual high", band.upperBound))
                    .foregroundStyle(lane.color.opacity(0.14))
            }
            ForEach(bars) { bar in
                if let value = bar.value {
                    BarMark(x: .value("Period", bar.start), y: .value(unit, value), width: .ratio(0.62))
                        .foregroundStyle(bar.isSelected
                                         ? AnyShapeStyle(LinearGradient(colors: [lane.bright, lane.deep],
                                                                        startPoint: .top, endPoint: .bottom))
                                         : AnyShapeStyle(lane.color.opacity(bar.containsUnknown ? 0.3 : 0.55)))
                        .cornerRadius(5)
                }
            }
        }
        .chartXScale(domain: bars.map(\.start))
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel().font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let start = value.as(String.self) {
                        Text(verbatim: axisLabel(start))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilitySummary(bars)))
    }

    @ViewBuilder private func legend(_ bars: [LoadHistoryBuckets.Bar]) -> some View {
        HStack(spacing: NoopMetrics.space4) {
            legendDot(lane.color, title)
            if span != .week {
                if usualWeek != nil {
                    legendDot(lane.color.opacity(0.3), String(localized: "Your usual week"))
                } else {
                    Text("Your usual range appears after eight complete weeks.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if bars.contains(where: \.containsUnknown) {
                legendDot(lane.color.opacity(0.3), String(localized: "Partly unmeasured"))
            }
        }
    }

    private func legendDot(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
        }
    }

    private func axisLabel(_ start: String) -> String {
        guard let date = WeightSeries.date(forDay: start) else { return start }
        if span == .week { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.defaultDigits))
    }

    private func accessibilitySummary(_ bars: [LoadHistoryBuckets.Bar]) -> String {
        bars.compactMap { bar in
            bar.value.map { "\(axisLabel(bar.start)): \(Int($0.rounded())) \(unit)" }
        }.joined(separator: ", ")
    }
}

// MARK: - Summary tile

/// A compact fact that opens its full card. The mini content shows enough to decide whether to open it.
struct SummaryTile<Mini: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var headline: String? = nil
    var detail: String? = nil
    let action: () -> Void
    @ViewBuilder var mini: () -> Mini

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack(spacing: NoopMetrics.space2) {
                    StatusBadge(symbol: symbol, color: tint, size: 26)
                    Text(title)
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if let headline {
                    Text(headline)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                }
                if let detail {
                    Text(detail)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                mini()
            }
            .padding(NoopMetrics.space3)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(FrostedCardSurface(tint: tint, cornerRadius: NoopMetrics.groupedRadius))
            .contentShape(RoundedRectangle(cornerRadius: NoopMetrics.groupedRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .strandPressable(cornerRadius: NoopMetrics.groupedRadius)
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the details"))
    }
}

// MARK: - Explainers

struct ExplainerItem: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let subtitle: String
    let content: () -> AnyView

    init(id: String, symbol: String, title: String, subtitle: String, text: String) {
        self.id = id; self.symbol = symbol; self.title = title; self.subtitle = subtitle
        self.content = {
            AnyView(Text(text)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true))
        }
    }

    init<Content: View>(id: String, symbol: String, title: String, subtitle: String,
                        @ViewBuilder content: @escaping () -> Content) {
        self.id = id; self.symbol = symbol; self.title = title; self.subtitle = subtitle
        self.content = { AnyView(content()) }
    }
}

/// How the screen's figures are made, one tap away instead of spelled out between the figures.
struct ExplainerRows: View {
    var header: String = String(localized: "How it works")
    let items: [ExplainerItem]
    @State private var open: String?

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text(header)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().overlay(StrandPalette.hairline).padding(.leading, 56) }
                        Button { open = item.id } label: { row(item) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(item: Binding(get: { open.flatMap { id in items.first { $0.id == id } }.map(SheetTarget.init) },
                             set: { open = $0?.id })) { target in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        Text(target.item.title)
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                        target.item.content()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(NoopMetrics.screenPadding)
                }
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { open = nil } }
                }
            }
        }
    }

    private struct SheetTarget: Identifiable {
        let item: ExplainerItem
        var id: String { item.id }
    }

    private func row(_ item: ExplainerItem) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            StatusBadge(symbol: item.symbol, color: StrandPalette.metricCyan, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(item.subtitle)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
            }
            Spacer(minLength: NoopMetrics.space2)
            Image(systemName: "chevron.right")
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, NoopMetrics.space3)
        .padding(.vertical, NoopMetrics.space3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Week control

/// The week stepper and history window shared by Cardio and Strength.
struct TrainingWeekControl<Range: Hashable & Identifiable>: View {
    let overline: String
    let rangeText: String
    let canGoBack: Bool
    let canGoForward: Bool
    let step: (Int) -> Void
    let ranges: [Range]
    @Binding var selectedRange: Range
    let rangeLabel: (Range) -> String

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(overline).strandOverline()
                Text(rangeText)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: NoopMetrics.space2)
            Menu {
                ForEach(ranges) { range in
                    Button {
                        selectedRange = range
                    } label: {
                        if range == selectedRange { Label(rangeLabel(range), systemImage: "checkmark") }
                        else { Text(rangeLabel(range)) }
                    }
                }
            } label: {
                Label(rangeLabel(selectedRange), systemImage: "calendar")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(StrandPalette.surfaceInset, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("History window"))
            stepButton("chevron.left", enabled: canGoBack, delta: -1, label: String(localized: "Previous week"))
            stepButton("chevron.right", enabled: canGoForward, delta: 1, label: String(localized: "Next week"))
        }
    }

    private func stepButton(_ symbol: String, enabled: Bool, delta: Int, label: String) -> some View {
        Button { step(delta) } label: {
            Image(systemName: symbol)
                .font(StrandFont.caption.weight(.bold))
                .frame(width: 30, height: 30)
                .background(StrandPalette.surfaceInset, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? StrandPalette.accent : StrandPalette.textTertiary)
        .disabled(!enabled)
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Layout

/// Side by side where there is room for both, stacked on a phone.
struct AdaptiveTwoColumn<Leading: View, Trailing: View>: View {
    var minimumWidth: CGFloat = 700
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: NoopMetrics.gap) {
                leading().frame(maxWidth: .infinity)
                trailing().frame(maxWidth: .infinity)
            }
            .frame(minWidth: minimumWidth)
            VStack(spacing: NoopMetrics.gap) {
                leading()
                trailing()
            }
        }
    }
}

#if DEBUG
#Preview("Training design kit") {
    ScrollView {
        VStack(spacing: NoopMetrics.gap) {
            HStack(spacing: NoopMetrics.gap) {
                LoadHeroCard(lane: .strength, percent: 58, state: .muchHigher,
                             figure: "10 working sets · 7.4 weighted", trend: [0.8, 1.0, 1.2, 1.1, 1.5, 1.6],
                             coverage: "8 of 10 sets rated", compact: true)
                LoadHeroCard(lane: .cardio, percent: nil, state: .noComparison,
                             figure: "at least 372 TRIMP", coverage: "3 of 4 sessions complete",
                             caveat: "One session has no usable heart rate", compact: true)
            }
            LoadHeroCard(lane: .cardio, percent: -12, state: .usual, figure: "508 TRIMP",
                         trend: [1.2, 1.1, 0.9, 1.0, 0.95, 0.88], coverage: "All 4 sessions measured")
            KPIStrip(lane: .cardio, items: [
                KPIItem(id: "s", icon: "figure.run", value: "5", label: "Sessions"),
                KPIItem(id: "t", icon: "clock.fill", value: "5h 32m", label: "Moving time", caption: "usual 3–4h"),
                KPIItem(id: "d", icon: "point.topleft.down.to.point.bottomright.curvepath", value: "41 km", label: "Distance"),
                KPIItem(id: "k", icon: "flame.fill", value: "2,480", label: "kcal"),
            ])
            LoadHistoryChart(lane: .strength, title: "Strength load", unit: "sets",
                             byDay: ["2025-09-01": 4, "2025-09-03": 5, "2025-09-10": 7, "2025-09-15": 6],
                             readingDay: "2025-09-17", usualWeek: 8...14)
            HStack(spacing: NoopMetrics.gap) {
                SummaryTile(symbol: "arrow.up.right", tint: StrandPalette.statusPositive, title: "Adaptation",
                            headline: "Productive development", action: {}) { EmptyView() }
                SummaryTile(symbol: "moon.zzz.fill", tint: StrandPalette.metricCyan, title: "Recovery",
                            headline: "Holding", detail: "1 of 7 nights flagged", action: {}) { EmptyView() }
            }
            ExplainerRows(items: [
                ExplainerItem(id: "a", symbol: "function", title: "How it is calculated",
                              subtitle: "TRIMP and your usual range", text: "Explanation."),
            ])
        }
        .padding()
    }
    .background(StrandPalette.surfaceBase)
}
#endif
