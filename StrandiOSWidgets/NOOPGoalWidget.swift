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
            if entry.snapshot.goals.isEmpty && entry.snapshot.dailyGoals.isEmpty {
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

    // MARK: Daily rings (plan §17f: daily goals lead every goal surface)

    /// Daily goals lead unless the widget was set to one particular weekly or monthly goal.
    private var showsRings: Bool { entry.goalId == nil && !entry.snapshot.dailyGoals.isEmpty }

    private func ringTint(_ daily: GoalWidgetSnapshot.Daily) -> Color {
        guard fullColor else { return .primary }
        return daily.colorKey.isEmpty ? StrandPalette.accent : AppleInspiredColors.color(for: daily.colorKey)
    }

    /// One ring large, two or three nested inside each other: the outer one is the first daily goal.
    private func nestedRings(_ items: [GoalWidgetSnapshot.Daily], diameter: CGFloat) -> some View {
        let shown = Array(items.prefix(3))
        let line = diameter * (shown.count == 1 ? 0.13 : 0.12)
        let gap = line * 0.25
        return ZStack {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, daily in
                let size = diameter - CGFloat(index) * 2 * (line + gap)
                ZStack {
                    Circle().stroke(ringTint(daily).opacity(fullColor ? 0.2 : 0.25), lineWidth: line)
                    Circle().trim(from: 0, to: min(1, max(0, daily.fraction)))
                        .stroke(ringTint(daily), style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .widgetAccentable()
                }
                .frame(width: size - line, height: size - line)
            }
            if shown.count == 1, let only = shown.first {
                Image(systemName: only.done ? "star.fill" : only.symbol)
                    .font(.system(size: diameter * 0.24, weight: .semibold))
                    .foregroundStyle(only.done && fullColor ? StrandPalette.statusWarning : ringTint(only))
            }
        }
        .frame(width: diameter, height: diameter)
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

    @ViewBuilder private var tallyLine: some View {
        if let tally = entry.snapshot.dailyTally {
            Label(String(localized: "\(tally.done) of \(tally.total) daily goals done"), systemImage: "checklist")
                .font(.caption2.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
        }
    }

    private func legend(_ items: [GoalWidgetSnapshot.Daily], limit: Int = 3) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.prefix(limit))) { daily in
                HStack(spacing: 5) {
                    Circle().fill(ringTint(daily)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 3) {
                            Text(daily.value).font(.caption.weight(.semibold)).monospacedDigit()
                            if daily.done {
                                Image(systemName: "star.fill").font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(fullColor ? StrandPalette.statusWarning : .primary)
                            }
                        }
                        Text(daily.target).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
                    }
                    .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
    }

    /// A weekly or monthly goal in one line: name, state, what is left.
    private func compactRow(_ goal: GoalWidgetSnapshot.Goal) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: goal.symbol).font(.caption2)
                Text(goal.name).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 2)
                Label(goal.stateWord, systemImage: goal.stateSymbol)
                    .font(.caption2.weight(.semibold)).foregroundStyle(tint(goal.tone)).lineLimit(1)
            }
            Text([goal.progress, goal.remaining].joined(separator: " · ")).font(.caption2)
                .foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
        }
    }

    // MARK: Home screen

    @ViewBuilder private var small: some View {
        if showsRings {
            let items = entry.snapshot.dailyGoals
            VStack(spacing: 6) {
                nestedRings(items, diameter: 92)
                if let first = items.first {
                    VStack(spacing: 0) {
                        Text(first.value).font(.caption.weight(.bold)).monospacedDigit()
                        asOfLine
                    }
                    .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let goal {
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

    /// Rings and their legend on the left; on the right the one goal that needs a look, else the summary.
    @ViewBuilder private var medium: some View {
        if showsRings {
            HStack(alignment: .center, spacing: 12) {
                nestedRings(entry.snapshot.dailyGoals, diameter: 104)
                VStack(alignment: .leading, spacing: 6) {
                    legend(entry.snapshot.dailyGoals, limit: entry.snapshot.spotlight.isEmpty ? 3 : 2)
                    tallyLine
                    asOfLine
                    if let first = entry.snapshot.spotlight.first {
                        Divider()
                        compactRow(first)
                    } else if !entry.snapshot.summary.isEmpty {
                        Text(entry.snapshot.summary).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.weekLabel).font(.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
                ForEach(Array(periodLines.prefix(2))) { goal in row(goal) }
                Spacer(minLength: 0)
                Text(entry.snapshot.summary).font(.caption2).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
            }
        }
    }

    /// Rings with their legend, then up to two goals that need a look, then the summary.
    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsRings {
                HStack(alignment: .center, spacing: 14) {
                    nestedRings(entry.snapshot.dailyGoals, diameter: 120)
                    VStack(alignment: .leading, spacing: 6) {
                        legend(entry.snapshot.dailyGoals)
                        tallyLine
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
            } else {
                Text(entry.weekLabel).font(.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
            }
            ForEach(Array(periodLines.prefix(2))) { goal in row(goal) }
            Spacer(minLength: 0)
            HStack {
                Text(entry.snapshot.summary).font(.caption).foregroundStyle(StrandPalette.textSecondary).lineLimit(1)
                Spacer(minLength: 4)
                asOfLine
            }
        }
    }

    /// The weekly and monthly goals worth a line: the spotlight, else (no goal needs a look) the first ones.
    private var periodLines: [GoalWidgetSnapshot.Goal] {
        let spot = entry.snapshot.spotlight
        return spot.isEmpty && !showsRings ? entry.snapshot.goals : spot
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
        if showsRings, let first = entry.snapshot.dailyGoals.first {
            Gauge(value: min(1, max(0, first.fraction))) {
                Image(systemName: first.symbol)
            } currentValueLabel: {
                Image(systemName: first.done ? "star.fill" : first.symbol)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        } else if let goal {
            Gauge(value: min(1, max(0, goal.fraction))) {
                Image(systemName: goal.symbol)
            } currentValueLabel: {
                Text(goal.progress).font(.system(size: 11, weight: .semibold, design: .rounded)).minimumScaleFactor(0.6)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetAccentable()
        }
    }

    @ViewBuilder private var rectangular: some View {
        if showsRings {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(entry.snapshot.dailyGoals.prefix(2))) { daily in
                    HStack(spacing: 4) {
                        Image(systemName: daily.symbol).font(.caption2)
                        Text(daily.value).font(.caption2.weight(.semibold)).monospacedDigit()
                        Spacer(minLength: 2)
                        if daily.done { Image(systemName: "star.fill").font(.caption2) }
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.25))
                            Capsule().fill(Color.primary).frame(width: geo.size.width * CGFloat(daily.fraction))
                                .widgetAccentable()
                        }
                    }
                    .frame(height: 3)
                }
            }
        } else {
            periodRectangular
        }
    }

    private var periodRectangular: some View {
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
        if showsRings, let first = entry.snapshot.dailyGoals.first {
            Text([first.name + ":", first.value, first.target].joined(separator: " "))
        } else if let goal {
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
        .description("Your daily goals as rings, and the weekly or monthly goal that needs a look.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
