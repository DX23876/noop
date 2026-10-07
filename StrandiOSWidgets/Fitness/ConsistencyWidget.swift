import WidgetKit
import SwiftUI
import StrandDesign

/// Training days as a calendar grid (8 weeks small, 12 weeks medium) with how many of the last 28 days
/// had a workout. Consistency you can see, without a streak that would count a planned rest day as a
/// failure.
struct NOOPConsistencyWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NOOPConsistencyWidget", provider: FitnessProvider()) { entry in
            ConsistencyWidgetView(entry: entry).containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("Consistency")
        .description("Your training days of the last weeks at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct ConsistencyWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: FitnessEntry

    private var fullColor: Bool { renderingMode == .fullColor }
    private let tint = AppleInspiredColors.color(for: "coach.goal.consistency")
    private var days: [Bool?] { entry.snapshot?.activeDays ?? [] }
    /// Training days among the last four weeks.
    private var recent: Int { days.suffix(28).filter { $0 == true }.count }

    var body: some View {
        Group {
            if days.contains(where: { $0 != nil }) {
                switch family {
                case .accessoryInline: Text(String(localized: "\(recent) of 28 days trained"))
                case .accessoryRectangular: rectangular
                case .systemMedium: medium
                default: small
                }
            } else {
                FitnessNoData(title: "Consistency", symbol: "calendar", tint: tint,
                              message: "Your training days fill in here week by week.")
            }
        }
        .widgetURL(URL(string: "noop://workouts"))
    }

    /// The grid starts on a whole week so every column is one week.
    private func grid(weeks: Int) -> [Bool?] {
        let count = min(days.count, weeks * 7)
        return Array(days.suffix(count - count % 7))
    }

    private var figure: some View {
        FitnessHero(value: "\(recent)", unit: String(localized: "of 28 days"))
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            FitnessWidgetHeader(title: "Consistency", symbol: "calendar", tint: tint)
            figure
            WidgetHeatGrid(days: grid(weeks: 8), tint: tint, fullColor: fullColor)
            FitnessFootnote(entry: entry)
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                FitnessWidgetHeader(title: "Consistency", symbol: "calendar", tint: tint)
                Spacer(minLength: 0)
                figure
                Text("Training days, last 4 weeks").font(.caption2).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
                FitnessFootnote(entry: entry)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            WidgetHeatGrid(days: grid(weeks: 12), tint: tint, fullColor: fullColor)
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "\(recent) of 28 days trained")).font(.caption.weight(.semibold)).lineLimit(1)
            WidgetHeatGrid(days: grid(weeks: 8), tint: tint, fullColor: false)
        }
    }
}
