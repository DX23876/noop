import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
import StrandCore

// Analysis migration required: no. A display of stored daily scores; nothing is derived or written.

/// The week on Trends day by day, under the three week rings: one row each for Charge, Effort and Rest, seven
/// bars from the week's first day. The rings give the week's means; these bars show how the week got there,
/// which day carried it and which pulled it down. The bars grow in when the week appears. A day without a
/// score is a small mark on the baseline, never a zero bar.
struct TrendsWeekByDay: View {
    let days: [DailyMetric]
    /// The week's first day, "yyyy-MM-dd".
    let weekStart: String
    let importedSleep: [String: ImportedSleepFigures]
    /// The stored traits each night's Rest was scored with (`Repository.restTraits`, AI-34).
    let restTraits: RestTraitLookup
    let effortScale: EffortScale

    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The seven day keys of the week, in order.
    private var weekKeys: [String] {
        guard let start = Self.parser.date(from: weekStart) else { return [] }
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: start) }
            .map { Self.parser.string(from: $0) }
    }

    var body: some View {
        let keys = weekKeys
        let byDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        let effortMax = effortScale == .whoop ? 21.0 : 100.0
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("By day")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                row(DomainTheme.charge.productName, color: StrandPalette.chargeColor, max: 100,
                    values: keys.map { byDay[$0]?.recovery })
                row(DomainTheme.effort.productName, color: StrandPalette.effortColor, max: effortMax,
                    values: keys.map { key in byDay[key]?.strain.map { UnitFormatter.effortValue($0, scale: effortScale) } })
                row(DomainTheme.rest.productName, color: StrandPalette.restColor, max: 100,
                    values: keys.map { key in byDay[key].flatMap { SleepModel.performanceValue($0, importedSleep: importedSleep, restTraits: restTraits) } })
                weekdayAxis(keys)
            }
        }
        .onAppear { grow() }
        .onChange(of: weekStart) { _ in
            grown = false
            grow()
        }
    }

    private func grow() {
        if reduceMotion { grown = true; return }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.85).delay(0.1)) { grown = true }
    }

    private func row(_ name: String, color: Color, max: Double, values: [Double?]) -> some View {
        HStack(alignment: .bottom, spacing: NoopMetrics.space2) {
            Text(name)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 58, alignment: .leading)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                    bar(value, color: color, max: max, index: index)
                }
            }
            .frame(height: 34)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(name))
        .accessibilityValue(Text(values.map { $0.map { "\(Int($0.rounded()))" } ?? "–" }.joined(separator: ", ")))
    }

    private func bar(_ value: Double?, color: Color, max: Double, index: Int) -> some View {
        GeometryReader { geo in
            VStack {
                Spacer(minLength: 0)
                if let value {
                    let fraction = Swift.min(Swift.max(value / max, 0.04), 1)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color.opacity(0.85))
                        .frame(height: geo.size.height * fraction * (grown ? 1 : 0.02))
                        // Left to right, a few hundredths apart, so the week fills in as it was lived.
                        .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.85)
                            .delay(0.04 * Double(index)), value: grown)
                } else {
                    Capsule().fill(StrandPalette.hairline).frame(height: 3)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func weekdayAxis(_ keys: [String]) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            Color.clear.frame(width: 58, height: 1)
            HStack(spacing: 6) {
                ForEach(keys, id: \.self) { key in
                    Text(Self.parser.date(from: key).map {
                        $0.formatted(.dateTime.weekday(.narrow).locale(AppLanguage.activeLocale))
                    } ?? "")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
