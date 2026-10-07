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

    /// The week line counted at the moment the widget draws; the stored one only for an older payload.
    var weekLabel: String {
        guard let days = snapshot.daysLeft(at: date) else { return snapshot.weekLabel }
        if days <= 0 { return "" }
        return days == 1 ? String(localized: "This week · last day") : String(localized: "This week · \(days) days left")
    }
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
        let now = Date()
        let snap = GoalWidgetSnapshot.load() ?? empty
        let goalId = chosen(configuration)
        // The app reloads on every change. A second entry at midnight rolls the week line over to the new
        // day's count even when the app stays closed.
        var entries = [GoalEntry(date: now, snapshot: snap, goalId: goalId)]
        if let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) {
            entries.append(GoalEntry(date: midnight, snapshot: snap, goalId: goalId))
        }
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: now) ?? now.addingTimeInterval(1800)
        return Timeline(entries: entries, policy: .after(next))
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
            if entry.snapshot.goals.isEmpty && (entry.snapshot.dailyTotal ?? 0) == 0 {
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
        // A long-term goal's page is not a route the link can open; its tap lands on the goals overview.
        .widgetURL(URL(string: goal.flatMap { $0.isLongTerm ? nil : "noop://goals/\($0.id)" } ?? "noop://goals"))
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

    /// The colour a goal's shape is drawn in: its identity colour where the app sent one, else its state.
    private func goalTint(_ goal: GoalWidgetSnapshot.Goal) -> Color {
        guard fullColor else { return .primary }
        if let key = goal.colorKey, !key.isEmpty { return AppleInspiredColors.color(for: key) }
        return tint(goal.tone)
    }

    /// When the numbers were taken: the widget only changes when the app has new data (after a sync or
    /// when opened), so it says how fresh it is instead of passing a morning count off as live (Q5).
    private var asOfLine: some View {
        // Taken on an earlier day, the weekday goes in front, so yesterday's count is not read as today's.
        let updated = entry.snapshot.updated
        let stamp = Calendar.current.isDate(updated, inSameDayAs: entry.date)
            ? updated.formatted(date: .omitted, time: .shortened)
            : updated.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        return Text(String(localized: "As of \(stamp)"))
            .font(.caption2).foregroundStyle(StrandPalette.textTertiary).lineLimit(1)
    }

    /// "1 of 3 daily goals done": the day's goals counted in one line, as Today's chips sum them up.
    @ViewBuilder private var dailyLine: some View {
        if let total = entry.snapshot.dailyTotal, total > 0 {
            let done = entry.snapshot.dailyDone ?? 0
            Label(String(localized: "\(done) of \(total) daily goals done"),
                  systemImage: done == total ? "star.fill" : "checklist")
                .font(.caption2.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
        }
    }

    /// The goals worth a line, in the order Today's card shows them: the one goal the widget was set to,
    /// else the spotlight (what needs a look, then long-term goals), else the first goals.
    private var lines: [GoalWidgetSnapshot.Goal] {
        if entry.goalId != nil, let goal { return [goal] }
        let spot = entry.snapshot.spotlight
        return spot.isEmpty ? entry.snapshot.goals : spot
    }

    /// A goal's shape: the app's glyph, or the plain pace track from an older payload.
    @ViewBuilder private func shape(_ goal: GoalWidgetSnapshot.Goal) -> some View {
        if let glyph = goal.glyph {
            WidgetGoalGlyph(glyph: glyph, tint: goalTint(goal), fullColor: fullColor)
        } else {
            track(goal, height: 5)
        }
    }

    /// One goal: name and state, where it stands in its own terms, its shape.
    private func row(_ goal: GoalWidgetSnapshot.Goal) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: goal.symbol).font(.caption2).foregroundStyle(goalTint(goal))
                Text(goal.name).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Label(goal.stateWord, systemImage: goal.stateSymbol)
                    .font(.caption2.weight(.semibold)).foregroundStyle(tint(goal.tone)).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(goal.progress).font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1)
                Text(goal.remaining).font(.caption2).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            shape(goal)
        }
    }

    /// The pace track in widget form, for a payload without a glyph: fill = done, mark = where the plan
    /// stands. In tinted and clear modes the fill is a solid shape and the mark is wider (design §11).
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

    // MARK: Home screen

    /// The goal that matters most: its name, its figure large, its shape, its state.
    @ViewBuilder private var small: some View {
        if let goal = lines.first {
            VStack(alignment: .leading, spacing: 8) {
                Label(goal.name, systemImage: goal.symbol)
                    .font(.caption.weight(.semibold)).lineLimit(1)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
                Text(goal.headline)
                    .font(.title2.weight(.bold)).fontDesign(.rounded).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6)
                shape(goal)
                Label(goal.stateWord, systemImage: goal.stateSymbol)
                    .font(.caption2.weight(.semibold)).foregroundStyle(tint(goal.tone))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Label("Goals", systemImage: "target").font(.caption.weight(.semibold))
                Spacer(minLength: 0)
                dailyLine
                asOfLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Two goals in their shapes, then the day's goals in one line.
    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.prefix(2).enumerated()), id: \.element.id) { index, goal in
                if index > 0 { Divider() }
                row(goal)
            }
            Spacer(minLength: 0)
            HStack {
                dailyLine
                Spacer(minLength: 4)
                asOfLine
            }
        }
    }

    /// Three goals in their shapes, the day's goals, the week's summary.
    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Goals", systemImage: "target")
                .font(.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
            ForEach(Array(lines.prefix(3).enumerated()), id: \.element.id) { index, goal in
                if index > 0 { Divider() }
                row(goal)
            }
            Spacer(minLength: 0)
            dailyLine
            HStack {
                Text(entry.snapshot.summary).font(.caption).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
                Spacer(minLength: 4)
                asOfLine
            }
        }
    }

    // MARK: Lock screen

    @ViewBuilder private var circular: some View {
        if let goal = lines.first {
            Gauge(value: min(1, max(0, goal.fraction))) {
                Image(systemName: goal.symbol)
            } currentValueLabel: {
                Image(systemName: goal.symbol)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.prefix(2))) { goal in
                HStack {
                    Text(goal.name).font(.caption2.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(goal.progress).font(.caption2).monospacedDigit().lineLimit(1)
                }
                track(goal, height: 3)
            }
        }
    }

    @ViewBuilder private var inline: some View {
        if let goal = lines.first {
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
        .description("Your goals, each drawn in its own shape, and how many of today's goals are done.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
