import SwiftUI
import Charts
import StrandAnalytics
import StrandDesign

// EnergyBurnRateCard.swift — the chart that says WHEN, next to the figure that says how much.
//
// It replaced a cumulative curve, which was the same information as the headline drawn a second
// time: a rising line whose final height is the number printed above it. A rate curve is the only
// shape on which the two things this card exists for mean anything — a workout is a spike with a
// start and an end, and "is this a normal day for me?" is a second curve laid over the first.
//
// The reference curve is hourly while today is five-minute, and that difference is deliberate
// rather than a compromise: a median across days has no five-minute structure left in it, and
// drawing it at that resolution would render precision the averaging removed.

/// What the day is being held up against.
enum EnergyRateComparison: String, CaseIterable, Identifiable {
    case previousDay
    case sevenDay
    case thirtyDay

    var id: String { rawValue }

    /// Nil for `previousDay`: one day is not a window, and asking for a median over it would be a
    /// median of one.
    var windowDays: Int? {
        switch self {
        case .previousDay: return nil
        case .sevenDay:    return 7
        case .thirtyDay:   return 30
        }
    }

    /// "Yesterday" only when today is on screen. With a day in August selected, the comparison is
    /// the day before THAT — calling it "yesterday" would name a day that is not on the chart.
    func label(isToday: Bool) -> LocalizedStringKey {
        switch self {
        case .previousDay: return isToday ? "Yesterday" : "Day before"
        case .sevenDay:    return "7d avg"
        case .thirtyDay:   return "30d avg"
        }
    }
}

struct EnergyBurnRateCard: View {
    let dayStart: Date
    let isToday: Bool
    let points: [EnergyBurnRate.Point]
    let bands: [EnergyTrainingBand]
    @Binding var comparison: EnergyRateComparison
    let comparisonPoints: [EnergyBurnRate.Point]
    /// "Median of 5 of the last 7 days", or nil when the comparison is a single day. Absent when the
    /// comparison could not be built at all — `comparisonUnavailable` then says why.
    let comparisonCaption: String?
    let comparisonUnavailable: LocalizedStringKey?

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                // Title and selector share one row, as the reference layout has them: the selector
                // changes what the title describes, and a full-width control on its own line reads
                // as a filter over the whole screen rather than over this chart.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        title
                        Spacer(minLength: 8)
                        picker.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) { title; picker }
                }

                Text(verbatim: "kcal/min")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)

                chart
                legend
                if let comparisonUnavailable {
                    Text(comparisonUnavailable)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let comparisonCaption {
                    Text(comparisonCaption)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: some View {
        Text(isToday ? "Burn rate today" : "Burn rate")
            .font(StrandFont.title2)
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private var picker: some View {
        Picker("Compare with", selection: $comparison) {
            ForEach(EnergyRateComparison.allCases) { option in
                Text(option.label(isToday: isToday)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            // Sessions first so the day's own line is drawn over them, not under.
            ForEach(bands) { band in
                RectangleMark(xStart: .value("Session start", band.start),
                              xEnd: .value("Session end", band.end))
                    .foregroundStyle(StrandPalette.energyTraining.opacity(0.16))
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        bandLabel(band)
                    }
            }

            ForEach(Array(comparisonSegments.enumerated()), id: \.offset) { index, segment in
                ForEach(segment, id: \.startSeconds) { point in
                    LineMark(x: .value("Time", date(point)),
                             y: .value("kcal/min", point.kcalPerMinute),
                             series: .value("Series", "reference-\(index)"))
                        .foregroundStyle(StrandPalette.energyReference)
                        .lineStyle(.init(lineWidth: 2, dash: [2, 4]))
                }
            }

            ForEach(Array(todaySegments.enumerated()), id: \.offset) { index, segment in
                ForEach(segment, id: \.startSeconds) { point in
                    AreaMark(x: .value("Time", date(point)),
                             y: .value("kcal/min", point.kcalPerMinute),
                             series: .value("Series", "today-\(index)"))
                        .foregroundStyle(LinearGradient(
                            colors: [StrandPalette.energyActive.opacity(0.28),
                                     StrandPalette.energyActive.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", date(point)),
                             y: .value("kcal/min", point.kcalPerMinute),
                             series: .value("Series", "today-\(index)"))
                        .foregroundStyle(StrandPalette.energyHighlight)
                        .lineStyle(.init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
        }
        .chartXScale(domain: dayStart...dayEnd)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 4)) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        // Leading, against the platform default: the scale belongs beside the "kcal/min" caption
        // that names it, and a reader following the curve left to right meets the numbers first.
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline)
                AxisValueLabel()
            }
        }
        .frame(height: 190)
        // Session captions are annotated at the TOP of a full-height band, which Charts places
        // ABOVE the plot area — into whatever is there. Without reserved space they landed on the
        // comparison selector. The padding is the space they are drawn in, not decoration.
        .padding(.top, 26)
        .accessibilityLabel(Text("Burn rate through the day, in kilocalories per minute"))
    }

    @ViewBuilder private func bandLabel(_ band: EnergyTrainingBand) -> some View {
        if labelledBands.contains(band) {
            VStack(spacing: 0) {
                Text(band.sport)
                Text(verbatim: "\(time(band.start))–\(time(band.end))")
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(StrandPalette.surfaceInset)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(StrandPalette.energyTraining.opacity(0.55), lineWidth: 1)
                    }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(color: StrandPalette.energyHighlight, dashed: false,
                       text: isToday ? "Today" : "This day")
            if !comparisonPoints.isEmpty {
                legendItem(color: StrandPalette.energyReference, dashed: true,
                           text: comparison.label(isToday: isToday))
            }
            // No entry for the sessions: each band already carries its own caption, and a legend
            // key for something labelled in place is a third thing to read saying nothing new.
            Spacer(minLength: 0)
        }
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textSecondary)
    }

    private func legendItem(color: Color, dashed: Bool, text: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            if dashed {
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule().fill(color).frame(width: 3, height: 3)
                    }
                }
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(text)
        }
    }

    // MARK: - Shaping

    private var dayEnd: Date { dayStart.addingTimeInterval(86_400) }

    private func date(_ point: EnergyBurnRate.Point) -> Date {
        dayStart.addingTimeInterval(point.startSeconds)
    }

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Contiguous runs of measured time. A stretch the strap did not cover becomes a BREAK in the
    /// line rather than a straight segment across it — a line drawn over unmeasured hours is a claim
    /// about those hours, and the flat one it would draw reads as "you were still", which is the one
    /// thing nobody knows.
    private var todaySegments: [[EnergyBurnRate.Point]] { Self.segments(points) }
    private var comparisonSegments: [[EnergyBurnRate.Point]] { Self.segments(comparisonPoints) }

    static func segments(_ points: [EnergyBurnRate.Point]) -> [[EnergyBurnRate.Point]] {
        var runs: [[EnergyBurnRate.Point]] = []
        var current: [EnergyBurnRate.Point] = []
        for point in points {
            if let last = current.last {
                // Half a slice of slack: consecutive buckets are never exactly adjacent once a short
                // final bucket or a rounded duration is involved, and splitting on that would shatter
                // an ordinary day into hundreds of one-point runs.
                let expected = last.startSeconds + last.durationSeconds
                if point.startSeconds > expected + last.durationSeconds / 2 {
                    runs.append(current)
                    current = []
                }
            }
            current.append(point)
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    /// At most three labels, longest sessions first. Every band is still drawn; only the captions
    /// are rationed, because six overlapping labels across a phone's width is worse than none.
    private var labelledBands: Set<EnergyTrainingBand> {
        Set(bands.sorted { ($0.endTs - $0.startTs) > ($1.endTs - $1.startTs) }.prefix(3))
    }
}
