#if os(iOS)
import SwiftUI
import Charts
import StrandCore

/// Where the plan's weight is heading: a band, not a promise. The middle line runs through it, the goal is a quiet
/// rule, the weeks after reaching it read as holding.
struct DietForecastChart: View {
    let forecast: DietForecast.Forecast
    let goalKg: Double?
    var weeks: Int = 26

    private var shown: [DietForecast.Week] { Array(forecast.weeks.prefix(weeks + 1)) }

    var body: some View {
        Chart {
            ForEach(shown, id: \.week) { w in
                AreaMark(x: .value("Week", w.week), yStart: .value("Low", w.lowKg), yEnd: .value("High", w.highKg))
                    .foregroundStyle(ForgeColor.food.opacity(ForgeOpacity.band))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Week", w.week), y: .value("Weight", w.midKg))
                    .foregroundStyle(ForgeColor.food)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            if let goalKg {
                RuleMark(y: .value("Goal", goalKg))
                    .foregroundStyle(ForgeColor.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .annotation(position: .top, alignment: .leading) {
                        Text("Goal \(DietText.kg(goalKg))").font(.caption2).foregroundStyle(ForgeColor.secondary)
                    }
            }
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .stride(by: weeks > 30 ? 8 : 4)) { value in
                AxisGridLine().foregroundStyle(ForgeColor.fill)
                AxisValueLabel { if let w = value.as(Int.self) { Text("Wk \(w)") } }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(ForgeColor.fill)
                AxisValueLabel { if let kg = value.as(Double.self) { Text(DietText.kg(kg)) } }
            }
        }
        .frame(height: 200)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(summary))
    }

    private var yDomain: ClosedRange<Double> {
        let values = shown.flatMap { [$0.lowKg, $0.highKg] } + (goalKg.map { [$0] } ?? [])
        let low = (values.min() ?? 0), high = (values.max() ?? 1)
        let pad = max(1, (high - low) * 0.1)
        return (low - pad)...(high + pad)
    }

    private var summary: String {
        guard let last = shown.last else { return "" }
        return String(localized: "In \(last.week) weeks about \(DietText.kg(last.midKg)), between \(DietText.kg(last.lowKg)) and \(DietText.kg(last.highKg)).")
    }
}

/// When the goal is reached, in words: a range of weeks, never a date to be held to.
enum DietForecastText {
    static func goal(_ forecast: DietForecast.Forecast, hasGoal: Bool) -> String? {
        guard hasGoal else { return nil }
        guard let range = forecast.goalWeeks else { return String(localized: "Your goal lies beyond a year at this pace.") }
        if range.lowerBound == range.upperBound { return String(localized: "Goal in about \(range.lowerBound) weeks.") }
        return String(localized: "Goal in about \(range.lowerBound) to \(range.upperBound) weeks.")
    }
}

/// A picture card for a choice: still life on top, the words under it, a check when chosen.
struct DietChoiceCard: View {
    let image: String
    let title: String
    let detail: String
    var badge: String? = nil
    var effort: Int? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(image).resizable().scaledToFill()
                    .frame(maxWidth: .infinity).frame(height: 96).clipped()
                    .clipShape(.rect(cornerRadius: ForgeRadius.inner))
                    .accessibilityHidden(true)
                HStack(alignment: .firstTextBaseline) {
                    Text(title).font(.headline).foregroundStyle(ForgeColor.text)
                    Spacer(minLength: 4)
                    if let effort { DietEffortDots(effort: effort) }
                }
                if let badge {
                    Text(badge).font(.caption.weight(.semibold)).foregroundStyle(ForgeColor.accent)
                }
                Text(detail).font(.footnote).foregroundStyle(ForgeColor.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ForgeColor.fill.opacity(0.6), in: .rect(cornerRadius: ForgeRadius.card))
            .overlay {
                RoundedRectangle(cornerRadius: ForgeRadius.card)
                    .strokeBorder(selected ? ForgeColor.accent : .clear, lineWidth: 2)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Effort as five small dots, the number in words for VoiceOver.
struct DietEffortDots: View {
    let effort: Int

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                Circle().fill(i <= effort ? DietText.effortTint(Double(effort)) : ForgeColor.fill).frame(width: 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Effort \(effort) of 5"))
    }
}

/// One of the planner's explainer cards: a calm picture, a title, a few sentences, the sources behind the button.
struct DietExplainCard: View {
    let image: String
    let title: String
    let text: String
    @State private var showsSources = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(image).resizable().scaledToFill()
                .frame(maxWidth: .infinity).frame(height: 150).clipped()
                .clipShape(.rect(cornerRadius: ForgeRadius.inner))
                .accessibilityHidden(true)
            HStack {
                Text(title).font(.headline).foregroundStyle(ForgeColor.text)
                Spacer()
                Button("Sources", systemImage: "info.circle") { showsSources.toggle() }
                    .labelStyle(.iconOnly).foregroundStyle(ForgeColor.secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            Text(text).font(.subheadline).foregroundStyle(ForgeColor.secondary).fixedSize(horizontal: false, vertical: true)
            if showsSources {
                Text(DietText.sources).font(.caption).foregroundStyle(ForgeColor.secondary)
            }
        }
        .forgeCard(padding: 12)
    }
}
#endif
