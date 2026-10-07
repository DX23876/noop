import WidgetKit
import SwiftUI
import StrandDesign

/// Last night: how long against the wearer's own need, the stages in one bar, the week of nights.
struct NOOPSleepWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NOOPSleepWidget", provider: FitnessProvider()) { entry in
            SleepWidgetView(entry: entry).containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("Sleep")
        .description("Last night against your sleep need, with its stages and the past week.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}

struct SleepWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: FitnessEntry

    private var fullColor: Bool { renderingMode == .fullColor }
    private let tint = StrandPalette.restColor

    var body: some View {
        Group {
            if let sleep = entry.snapshot?.sleep {
                switch family {
                case .accessoryInline:
                    Text(String(localized: "Sleep \(FitnessFormat.duration(minutes: sleep.totalMin))"))
                case .accessoryRectangular: rectangular(sleep)
                case .systemMedium: medium(sleep)
                default: small(sleep)
                }
            } else {
                FitnessNoData(title: "Sleep", symbol: "moon.zzz", tint: tint,
                              message: "Last night shows here once NOOP has scored it.")
            }
        }
        .widgetURL(URL(string: "noop://sleep"))
    }

    private func needLine(_ sleep: FitnessWidgetSnapshot.Sleep) -> String? {
        sleep.needMin.map { String(localized: "of \(FitnessFormat.duration(minutes: $0)) need") }
    }

    private func stages(_ sleep: FitnessWidgetSnapshot.Sleep, height: CGFloat) -> some View {
        WidgetStageBar(deep: sleep.deepMin ?? 0, rem: sleep.remMin ?? 0, light: sleep.lightMin ?? 0,
                       tint: tint, fullColor: fullColor)
            .frame(height: height)
    }

    private func small(_ sleep: FitnessWidgetSnapshot.Sleep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            FitnessWidgetHeader(title: "Sleep", symbol: "moon.zzz", tint: tint)
            Spacer(minLength: 0)
            FitnessHero(value: FitnessFormat.duration(minutes: sleep.totalMin))
            if let need = needLine(sleep) {
                Text(need).font(.caption2).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
            }
            stages(sleep, height: 8)
            FitnessFootnote(entry: entry)
        }
    }

    private func medium(_ sleep: FitnessWidgetSnapshot.Sleep) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                FitnessWidgetHeader(title: "Sleep", symbol: "moon.zzz", tint: tint)
                Spacer(minLength: 0)
                FitnessHero(value: FitnessFormat.duration(minutes: sleep.totalMin))
                if let need = needLine(sleep) {
                    Text(need).font(.caption2).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
                }
                stages(sleep, height: 8)
                legend(sleep)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text("Last 7 nights").font(.caption2).foregroundStyle(StrandPalette.textSecondary)
                WidgetBarChart(values: FitnessWidgetSnapshot.tail(entry.snapshot?.sleepHours ?? [], 7),
                               goal: sleep.needMin.map { $0 / 60 },
                               color: { _, hours in
                                   // A night short of the need reads lighter, as a step day under goal does.
                                   (sleep.needMin.map { hours * 60 >= $0 } ?? true) ? tint : tint.opacity(0.5)
                               }, fullColor: fullColor)
                FitnessFootnote(entry: entry)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func legend(_ sleep: FitnessWidgetSnapshot.Sleep) -> some View {
        HStack(spacing: 8) {
            if let deep = sleep.deepMin {
                Text(String(localized: "Deep \(FitnessFormat.clock(minutes: deep))"))
            }
            if let rem = sleep.remMin {
                Text(String(localized: "REM \(FitnessFormat.clock(minutes: rem))"))
            }
        }
        .font(.caption2).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
    }

    private func rectangular(_ sleep: FitnessWidgetSnapshot.Sleep) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(FitnessFormat.duration(minutes: sleep.totalMin), systemImage: "moon.zzz")
                .font(.headline).lineLimit(1)
            stages(sleep, height: 6)
            if let need = needLine(sleep) {
                Text(need).font(.caption2).lineLimit(1)
            }
        }
    }
}
