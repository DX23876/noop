import WidgetKit
import SwiftUI
import AppIntents
import StrandDesign

// MARK: - Configuration (pick a goal, or "most important")

struct GoalWidgetEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Goal"
    static var defaultQuery = GoalWidgetEntityQuery()

    var id: String
    var title: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    /// Not a goal: tells the widget to show whichever goal matters most right now.
    static let mostImportantId = "auto"
    static var mostImportant: GoalWidgetEntity {
        GoalWidgetEntity(id: mostImportantId, title: String(localized: "Most important"))
    }
}

struct GoalWidgetEntityQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [GoalWidgetEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [GoalWidgetEntity] { all() }

    func defaultResult() async -> GoalWidgetEntity? { .mostImportant }

    private func all() -> [GoalWidgetEntity] {
        [.mostImportant] + (GoalWidgetSnapshot.load()?.goals ?? []).map { .init(id: $0.id, title: $0.title) }
    }
}

struct SelectGoalIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Choose a goal"
    static var description = IntentDescription("Pick the goal this widget shows, or let NOOP show the most important one.")

    @Parameter(title: "Goal")
    var goal: GoalWidgetEntity?

    init() {}
}

// MARK: - Timeline

struct GoalEntry: TimelineEntry {
    let date: Date
    let snapshot: GoalWidgetSnapshot
    /// nil = most important.
    let goalId: String?
}

struct GoalProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> GoalEntry {
        GoalEntry(date: Date(), snapshot: .placeholder, goalId: nil)
    }

    func snapshot(for configuration: SelectGoalIntent, in context: Context) async -> GoalEntry {
        let snap = GoalWidgetSnapshot.load() ?? (context.isPreview ? .placeholder : empty)
        return GoalEntry(date: Date(), snapshot: snap, goalId: chosen(configuration))
    }

    func timeline(for configuration: SelectGoalIntent, in context: Context) async -> Timeline<GoalEntry> {
        let entry = GoalEntry(date: Date(), snapshot: GoalWidgetSnapshot.load() ?? empty, goalId: chosen(configuration))
        // The app reloads on every change; this only rolls the "days left" over at a quiet pace.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        return Timeline(entries: [entry], policy: .after(next))
    }

    private func chosen(_ configuration: SelectGoalIntent) -> String? {
        guard let id = configuration.goal?.id, id != GoalWidgetEntity.mostImportantId else { return nil }
        return id
    }

    private var empty: GoalWidgetSnapshot {
        GoalWidgetSnapshot(goals: [], weekLabel: "", summary: "", updated: .distantPast)
    }
}

// MARK: - Views

struct GoalWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: GoalEntry

    private var goal: GoalWidgetSnapshot.Goal? { entry.snapshot.goal(for: entry.goalId) }

    var body: some View {
        Group {
            if entry.snapshot.goals.isEmpty {
                emptyState
            } else {
                switch family {
                case .accessoryCircular:    circular
                case .accessoryRectangular: rectangular
                case .accessoryInline:      inline
                case .systemMedium:         medium
                case .systemLarge:          large
                default:                    small
                }
            }
        }
        .widgetURL(URL(string: goal.map { "noop://goals/\($0.id)" } ?? "noop://goals"))
    }

    private var fullColor: Bool { renderingMode == .fullColor }

    private func tint(_ tone: String) -> Color {
        guard fullColor else { return .primary }
        switch tone {
        case "positive": return StrandPalette.statusPositive
        case "warning":  return StrandPalette.statusWarning
        case "critical": return StrandPalette.statusCritical
        case "accent":   return StrandPalette.accent
        default:         return StrandPalette.textSecondary
        }
    }

    // MARK: Home screen

    @ViewBuilder private var small: some View {
        if let goal {
            VStack(alignment: .leading, spacing: 6) {
                Label(goal.name, systemImage: goal.symbol)
                    .font(.caption.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
                Text(goal.headline)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.6).lineLimit(1)
                track(goal, height: 7)
                HStack {
                    Label(goal.stateWord, systemImage: goal.stateSymbol)
                        .font(.caption2.weight(.semibold)).foregroundStyle(tint(goal.tone))
                        .labelStyle(.titleAndIcon)
                    Spacer(minLength: 2)
                    Text(goal.progress).font(.caption2).monospacedDigit().foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.snapshot.weekLabel).font(.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
            ForEach(Array(entry.snapshot.goals.prefix(3))) { goal in row(goal) }
            Spacer(minLength: 0)
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(entry.snapshot.weekLabel).font(.caption.weight(.semibold))
                Spacer()
                Text(entry.snapshot.summary).font(.caption)
            }
            .foregroundStyle(StrandPalette.textSecondary)
            ForEach(Array(entry.snapshot.goals.prefix(6))) { goal in row(goal) }
            Spacer(minLength: 0)
        }
    }

    private func row(_ goal: GoalWidgetSnapshot.Goal) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: goal.symbol).font(.caption2)
                Text(goal.name).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Label(goal.stateWord, systemImage: goal.stateSymbol)
                    .font(.caption2).foregroundStyle(tint(goal.tone))
            }
            track(goal, height: 5)
            HStack {
                Text(goal.remaining).font(.caption2).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(goal.progress).font(.caption2).monospacedDigit().foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    /// The pace track in widget form: fill = done, mark = where the plan stands. In tinted and clear
    /// modes the fill is a solid shape and the mark is wider, so it reads without colour (design §11).
    private func track(_ goal: GoalWidgetSnapshot.Goal, height: CGFloat) -> some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(fullColor ? StrandPalette.hairline : Color.primary.opacity(0.25))
                Capsule().fill(tint(goal.tone)).frame(width: width * CGFloat(min(1, max(0, goal.fraction))))
                    .widgetAccentable()
                if let pace = goal.paceFraction, goal.fraction < 1 {
                    Capsule().fill(Color.primary)
                        .frame(width: fullColor ? 2 : 3, height: height + 6)
                        .offset(x: max(0, min(width - 3, width * CGFloat(pace) - 1)))
                }
            }
        }
        .frame(height: height + 6)
    }

    // MARK: Lock screen

    @ViewBuilder private var circular: some View {
        if let goal {
            Gauge(value: min(1, max(0, goal.fraction))) {
                Image(systemName: goal.symbol)
            } currentValueLabel: {
                Text(goal.progress).font(.system(size: 11, weight: .semibold, design: .rounded)).minimumScaleFactor(0.6)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(entry.snapshot.goals.prefix(2))) { goal in
                HStack {
                    Text(goal.name).font(.caption2.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(goal.progress).font(.caption2).monospacedDigit()
                }
                track(goal, height: 3)
            }
        }
    }

    @ViewBuilder private var inline: some View {
        if let goal {
            Text("\(goal.name): \(goal.headline) · \(goal.stateWord)")
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Goals", systemImage: "target").font(.caption.weight(.semibold))
            Text("Set a weekly goal in NOOP to see it here.")
                .font(.caption2).foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

struct NOOPGoalWidget: Widget {
    let kind = GoalWidgetSnapshot.widgetKind

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: SelectGoalIntent.self, provider: GoalProvider()) { entry in
            GoalWidgetView(entry: entry)
                .containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("NOOP Goals")
        .description("A weekly or monthly goal at a glance: what is left and whether you are on course.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
