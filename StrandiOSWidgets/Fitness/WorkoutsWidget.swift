import WidgetKit
import SwiftUI
import StrandDesign

/// The running training week: how many workouts and minutes, which days, and the last workout.
struct NOOPWorkoutsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NOOPWorkoutsWidget", provider: FitnessProvider()) { entry in
            WorkoutsWidgetView(entry: entry).containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("Training week")
        .description("Workouts and minutes this week, and your last workout.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct WorkoutsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: FitnessEntry

    private var fullColor: Bool { renderingMode == .fullColor }
    private let tint = AppleInspiredColors.color(for: "coach.goal.consistency")

    var body: some View {
        Group {
            if let week = entry.snapshot?.workouts {
                switch family {
                case .accessoryInline:
                    Text(String(localized: "\(week.count) workouts · \(week.minutes) min"))
                case .accessoryRectangular: rectangular(week)
                case .systemMedium: medium(week)
                default: small(week)
                }
            } else {
                FitnessNoData(title: "Training week", symbol: "figure.mixed.cardio", tint: tint,
                              message: "Your workouts show here after the next sync.")
            }
        }
        .widgetURL(URL(string: "noop://workouts"))
    }

    private func countLine(_ week: FitnessWidgetSnapshot.Workouts) -> String {
        String(localized: "\(week.count) workouts")
    }

    /// One dot per day of the training week: filled when trained, today as a ring, days to come faint.
    private func dots(_ week: FitnessWidgetSnapshot.Workouts, letters: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(week.trainedDays.enumerated()), id: \.offset) { index, trained in
                VStack(spacing: 4) {
                    dot(trained: trained, isToday: index == week.todayIndex, isFuture: index > week.todayIndex)
                        .frame(width: 10, height: 10)
                    if letters, week.weekLetters.indices.contains(index) {
                        Text(week.weekLetters[index]).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private func dot(trained: Bool, isToday: Bool, isFuture: Bool) -> some View {
        if trained {
            Circle().fill(fullColor ? tint : .primary)
        } else if isToday {
            Circle().strokeBorder(Color.primary, lineWidth: 1.5)
        } else {
            Circle().strokeBorder(fullColor ? StrandPalette.textTertiary : .primary.opacity(0.5),
                                  style: StrokeStyle(lineWidth: 1, dash: isFuture ? [2, 2] : []))
        }
    }

    @ViewBuilder
    private func lastLine(_ week: FitnessWidgetSnapshot.Workouts) -> some View {
        if let name = week.lastName, let day = week.lastDay {
            Label {
                Text(String(localized: "\(name), \(FitnessFormat.day(day))"))
            } icon: {
                Image(systemName: week.lastSymbol ?? "figure.mixed.cardio").foregroundStyle(tint)
            }
            .font(.caption2).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
        }
    }

    private func small(_ week: FitnessWidgetSnapshot.Workouts) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FitnessWidgetHeader(title: "Training week", symbol: "figure.mixed.cardio", tint: tint)
            FitnessHero(value: "\(week.count)", unit: String(localized: "workouts"))
            Text(String(localized: "\(week.minutes) min this week")).font(.caption2)
                .foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
            Spacer(minLength: 0)
            dots(week, letters: false)
            FitnessFootnote(entry: entry)
        }
    }

    private func medium(_ week: FitnessWidgetSnapshot.Workouts) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                FitnessWidgetHeader(title: "Training week", symbol: "figure.mixed.cardio", tint: tint)
                Spacer(minLength: 4)
                Text(String(localized: "\(week.minutes) min this week")).font(.caption2)
                    .foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
            }
            FitnessHero(value: "\(week.count)", unit: String(localized: "workouts"))
            dots(week, letters: true)
            Spacer(minLength: 0)
            HStack {
                lastLine(week)
                FitnessFootnote(entry: entry)
            }
        }
    }

    private func rectangular(_ week: FitnessWidgetSnapshot.Workouts) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "\(week.count) workouts · \(week.minutes) min"))
                .font(.caption.weight(.semibold)).lineLimit(1)
            dots(week, letters: false)
            if let name = week.lastName { Text(name).font(.caption2).lineLimit(1) }
        }
    }
}
