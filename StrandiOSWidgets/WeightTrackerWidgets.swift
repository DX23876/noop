import WidgetKit
import SwiftUI
import AppIntents
import StrandDesign

// The weight widgets (owner decisions 2026-11-26): the trend, the month, the key figures and a countdown to one of
// the wearer's dates. Each draws `WeightWidgetSnapshot`, worded by the app from the weight page's own snapshot, and
// each comes in its own colour, changeable when the widget is edited.

// MARK: - Colour

enum WeightWidgetTint: String, AppEnum {
    case pink, orange, yellow, green, teal, blue, indigo, purple

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Colour"
    static let caseDisplayRepresentations: [WeightWidgetTint: DisplayRepresentation] = [
        .pink: "Pink", .orange: "Orange", .yellow: "Yellow", .green: "Green", .teal: "Teal", .blue: "Blue",
        .indigo: "Indigo", .purple: "Purple",
    ]

    var color: Color {
        switch self {
        case .pink: .pink
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        }
    }
}

/// A soft wash of the widget's colour, light enough for dark text in light mode and dark enough for light text in
/// dark mode.
private struct WeightWidgetBackground: View {
    let tint: Color
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        LinearGradient(colors: [tint.opacity(scheme == .dark ? 0.34 : 0.26), tint.opacity(scheme == .dark ? 0.14 : 0.08)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .background(StrandPalette.surfaceBase)
    }
}

/// The small label every weight widget starts with, as a pill.
private struct WeightWidgetPill: View {
    let text: String
    let tint: Color
    let fullColor: Bool
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(fullColor ? tint.opacity(0.22) : Color.primary.opacity(0.12)))
            .foregroundStyle(fullColor ? tint : Color.primary)
    }
}

private struct WeightNoData: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "scalemass").font(.title3)
            Text("Weigh-ins from NOOP or Apple Health show here.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Timeline

struct WeightEntry: TimelineEntry {
    let date: Date
    let snapshot: WeightWidgetSnapshot?
    let tint: Color
    var eventId: String? = nil
}

private func weightTimeline(_ entry: WeightEntry) -> Timeline<WeightEntry> {
    // The app reloads on every weigh-in; one more entry at midnight moves a countdown on with the app closed.
    let midnight = Calendar.current.startOfDay(for: entry.date.addingTimeInterval(86_400))
    let next = WeightEntry(date: midnight, snapshot: entry.snapshot, tint: entry.tint, eventId: entry.eventId)
    return Timeline(entries: [entry, next], policy: .after(midnight))
}

struct WeightTintIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Weight widget"
    static let description = IntentDescription("Choose the widget's colour.")
    @Parameter(title: "Colour", default: .pink) var tint: WeightWidgetTint
    init() {}
    init(tint: WeightWidgetTint) { self.tint = tint }
}

struct WeightTintProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WeightEntry {
        WeightEntry(date: Date(), snapshot: .placeholder, tint: .pink)
    }
    func snapshot(for configuration: WeightTintIntent, in context: Context) async -> WeightEntry {
        WeightEntry(date: Date(), snapshot: WeightWidgetSnapshot.load() ?? (context.isPreview ? .placeholder : nil),
                    tint: configuration.tint.color)
    }
    func timeline(for configuration: WeightTintIntent, in context: Context) async -> Timeline<WeightEntry> {
        weightTimeline(WeightEntry(date: Date(), snapshot: WeightWidgetSnapshot.load(), tint: configuration.tint.color))
    }
}

// MARK: - Trend

struct NOOPWeightTrendWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "NOOPWeightTrendWidget", intent: WeightTintIntent.self, provider: WeightTintProvider()) { entry in
            WeightTrendWidgetView(entry: entry).appGroupNotice()
                .containerBackground(for: .widget) { WeightWidgetBackground(tint: entry.tint) }
        }
        .configurationDisplayName("Weight trend")
        .description("The trend behind the daily ups and downs, and how fast it moves.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

struct WeightTrendWidgetView: View {
    let entry: WeightEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        Group {
            if let s = entry.snapshot {
                if family == .accessoryRectangular {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Weight trend").font(.caption2.weight(.semibold))
                        Text("\(s.trend) \(s.unit)").font(.headline)
                        if let rate = s.rateLine { Text(rate).font(.caption2) }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        WeightWidgetPill(text: String(localized: "Trend"), tint: entry.tint, fullColor: mode == .fullColor)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(s.trend).font(.system(size: 34, weight: .bold, design: .rounded)).minimumScaleFactor(0.6)
                            Text(s.unit).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        .lineLimit(1)
                        if let rate = s.rateLine {
                            Text(rate).font(.caption.weight(.semibold)).foregroundStyle(mode == .fullColor ? entry.tint : .primary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                        }
                        WidgetLineChart(values: s.line.map { Optional($0) }, tint: entry.tint, fullColor: mode == .fullColor)
                    }
                }
            } else {
                WeightNoData()
            }
        }
        .widgetURL(URL(string: "noop://weight"))
    }
}

// MARK: - Month

struct NOOPWeightMonthWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "NOOPWeightMonthWidget", intent: WeightTintIntent.self, provider: WeightTintProvider()) { entry in
            WeightMonthWidgetView(entry: entry).appGroupNotice()
                .containerBackground(for: .widget) { WeightWidgetBackground(tint: entry.tint) }
        }
        .configurationDisplayName("Weight this month")
        .description("This month's lowest weigh-in and average against last month.")
        .supportedFamilies([.systemSmall])
    }
}

struct WeightMonthWidgetView: View {
    let entry: WeightEntry
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        Group {
            if let s = entry.snapshot {
                VStack(alignment: .leading, spacing: 8) {
                    WeightWidgetPill(text: s.monthLabel, tint: entry.tint, fullColor: mode == .fullColor)
                    if s.month.isEmpty {
                        Text("Four weigh-ins this month make a report.").font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    } else {
                        ForEach(Array(s.month.prefix(4).enumerated()), id: \.offset) { _, f in
                            HStack(alignment: .firstTextBaseline) {
                                Text(f.label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(f.value).font(.subheadline.weight(.bold)).monospacedDigit().lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            } else {
                WeightNoData()
            }
        }
        .widgetURL(URL(string: "noop://weight"))
    }
}

// MARK: - Key figures

struct NOOPWeightFiguresWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "NOOPWeightFiguresWidget", intent: WeightTintIntent.self, provider: WeightTintProvider()) { entry in
            WeightFiguresWidgetView(entry: entry).appGroupNotice()
                .containerBackground(for: .widget) { WeightWidgetBackground(tint: entry.tint) }
        }
        .configurationDisplayName("Weight figures")
        .description("Latest weigh-in, trend, weekly change and your progress at a glance.")
        .supportedFamilies([.systemMedium])
    }
}

struct WeightFiguresWidgetView: View {
    let entry: WeightEntry
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        Group {
            if let s = entry.snapshot {
                VStack(alignment: .leading, spacing: 10) {
                    WeightWidgetPill(text: String(localized: "Weight in \(s.unit)"), tint: entry.tint, fullColor: mode == .fullColor)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                        ForEach(0..<2, id: \.self) { row in
                            GridRow {
                                ForEach(0..<3, id: \.self) { col in
                                    let i = row * 3 + col
                                    if i < s.figures.count { figure(s.figures[i]) } else { Color.clear.frame(height: 1) }
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
            } else {
                WeightNoData()
            }
        }
        .widgetURL(URL(string: "noop://weight"))
    }

    private func figure(_ f: WeightWidgetSnapshot.Figure) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(f.label).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            Text(f.value).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit().lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Countdown to a date

struct WeightEventEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Date"
    static let defaultQuery = WeightEventQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
    static let nextId = "next"
    static var next: WeightEventEntity { WeightEventEntity(id: nextId, name: String(localized: "The next date")) }
}

struct WeightEventQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WeightEventEntity] { all().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [WeightEventEntity] { all() }
    func defaultResult() async -> WeightEventEntity? { .next }
    private func all() -> [WeightEventEntity] {
        [.next] + (WeightWidgetSnapshot.load()?.events ?? []).map { .init(id: $0.id, name: $0.name) }
    }
}

struct WeightEventIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Weight on a date"
    static let description = IntentDescription("Choose the date and the widget's colour.")
    @Parameter(title: "Date") var event: WeightEventEntity?
    @Parameter(title: "Colour", default: .teal) var tint: WeightWidgetTint
    init() {}
}

struct WeightEventProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WeightEntry { WeightEntry(date: Date(), snapshot: .placeholder, tint: .teal) }
    func snapshot(for configuration: WeightEventIntent, in context: Context) async -> WeightEntry {
        WeightEntry(date: Date(), snapshot: WeightWidgetSnapshot.load() ?? (context.isPreview ? .placeholder : nil),
                    tint: configuration.tint.color, eventId: configuration.event?.id)
    }
    func timeline(for configuration: WeightEventIntent, in context: Context) async -> Timeline<WeightEntry> {
        weightTimeline(WeightEntry(date: Date(), snapshot: WeightWidgetSnapshot.load(), tint: configuration.tint.color,
                                   eventId: configuration.event?.id))
    }
}

struct NOOPWeightEventWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "NOOPWeightEventWidget", intent: WeightEventIntent.self, provider: WeightEventProvider()) { entry in
            WeightEventWidgetView(entry: entry).appGroupNotice()
                .containerBackground(for: .widget) { WeightWidgetBackground(tint: entry.tint) }
        }
        .configurationDisplayName("Weight on a date")
        .description("What you are likely to weigh on a date you set, counting down.")
        .supportedFamilies([.systemSmall])
    }
}

struct WeightEventWidgetView: View {
    let entry: WeightEntry
    @Environment(\.widgetRenderingMode) private var mode

    private var event: WeightWidgetSnapshot.Event? {
        let upcoming = (entry.snapshot?.events ?? []).filter { $0.date >= Calendar.current.startOfDay(for: entry.date) }
        if let id = entry.eventId, id != WeightEventEntity.nextId, let match = upcoming.first(where: { $0.id == id }) { return match }
        return upcoming.min { $0.date < $1.date }
    }

    var body: some View {
        Group {
            if let s = entry.snapshot, let e = event {
                let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: entry.date),
                                                           to: Calendar.current.startOfDay(for: e.date)).day ?? 0
                VStack(alignment: .leading, spacing: 4) {
                    WeightWidgetPill(text: e.name, tint: entry.tint, fullColor: mode == .fullColor)
                    Spacer(minLength: 0)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(e.expected ?? "—").font(.system(size: 32, weight: .bold, design: .rounded)).minimumScaleFactor(0.6)
                        Text(s.unit).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    Text(days == 0 ? String(localized: "today") : String(localized: "in \(days) days"))
                        .font(.caption.weight(.semibold)).foregroundStyle(mode == .fullColor ? entry.tint : .primary)
                    if let rate = e.rateLine {
                        Text(rate).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if entry.snapshot != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "calendar.badge.plus").font(.title3)
                    Text("Add a date on the weight page to see what you will likely weigh then.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                WeightNoData()
            }
        }
        .widgetURL(URL(string: "noop://weight"))
    }
}

struct NOOPWeightWidgets: WidgetBundle {
    var body: some Widget {
        NOOPWeightTrendWidget()
        NOOPWeightMonthWidget()
        NOOPWeightFiguresWidget()
        NOOPWeightEventWidget()
    }
}
