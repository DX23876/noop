import WidgetKit
import SwiftUI
import StrandDesign

/// The home-screen goal widget: what you're working towards, on the screen you unlock fifty times a day.
///
/// It shares `NOOPProvider`'s timeline, so this is another presentation of the SAME `WidgetSnapshot` the
/// app publishes — the same goal and the same fraction the Today goals card shows, never a second data
/// path and never a database read from inside the extension.
///
/// Two things it will not do:
/// * **Fill a ring it can't justify.** `goalFraction` is non-nil only when a real measurement backs it
///   (`GoalTrackingEngine`); without one the widget draws the goal's mark and talks about time instead.
/// * **Show plausible numbers when it has none.** No snapshot, or a snapshot with no goal, renders the
///   honest empty state. `WidgetSnapshot.placeholder` stays confined to the gallery preview.
///
/// The ring here is hand-drawn rather than `GlowRing` for the same reason `NOOPWidget`'s is: WidgetKit
/// timelines don't reliably fire `onAppear`, so a draw-in animation can freeze at zero fill.
///
/// Copy note: the extension's sources do not include the app's String Catalog (a target only ships the
/// catalogs it lists), so the words here render in English whatever the phone's language — the same
/// limitation the existing widgets already live with. The one string that carries real content, the
/// progress line, is composed app-side and travels in the snapshot.
struct NOOPGoalWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPEntry

    private var snap: WidgetSnapshot { entry.snapshot }

    /// The goal's own colour when the app resolved one, else the Charge family accent — the same tint the
    /// goal section wears in Today's customization sheet.
    private var tint: Color {
        snap.goalTintId.map { CoachIconColors.color(for: $0) } ?? StrandPalette.chargeColor
    }

    var body: some View {
        if snap.hasGoal {
            switch family {
            case .accessoryCircular:   accessoryRing
            case .accessoryInline:     Text(inlineText)
            case .accessoryRectangular: accessoryRectangle
            case .systemMedium:        medium
            default:                   small
            }
        } else {
            empty
        }
    }

    // MARK: - Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            mark(diameter: 56, lineWidth: 6)
            Spacer(minLength: 0)
            Text(snap.goalTitle ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(2)
            if let runway = runwayText {
                Text(runway)
                    .font(.caption2)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var medium: some View {
        HStack(spacing: 14) {
            mark(diameter: 72, lineWidth: 7)
            VStack(alignment: .leading, spacing: 4) {
                header
                Text(snap.goalTitle ?? "")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2)
                // The measured line when there is one, the runway when there isn't — never both, and
                // never a stand-in for a measurement that doesn't exist.
                if let line = snap.goalLine {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(2)
                }
                if let runway = runwayText {
                    Text(runway)
                        .font(.caption2)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var header: some View {
        Text("GOAL")
            .font(.system(size: 10, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(StrandPalette.textTertiary)
    }

    /// The progress ring, or the goal's mark when nothing real backs a fraction.
    @ViewBuilder
    private func mark(diameter: CGFloat, lineWidth: CGFloat) -> some View {
        if let fraction = snap.goalFraction {
            ZStack {
                Circle()
                    .stroke(StrandPalette.textPrimary.opacity(0.10),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                Circle()
                    // A genuine zero still draws a round-cap bead, so "just started" reads as data.
                    .trim(from: 0, to: max(0.0001, min(1, max(0, fraction))))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(StrandFont.rounded(diameter * 0.28, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .padding(.horizontal, lineWidth + 2)
            }
            .frame(width: diameter, height: diameter)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Progress"))
            .accessibilityValue(Text("\(Int((fraction * 100).rounded())) percent"))
        } else {
            Image(systemName: snap.goalSymbol ?? "target")
                .font(.system(size: diameter * 0.42))
                .foregroundStyle(tint)
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(tint.opacity(0.12)))
                .overlay(Circle().strokeBorder(tint.opacity(0.28), lineWidth: 1))
                .accessibilityHidden(true)
        }
    }

    // MARK: - Lock Screen accessories

    private var accessoryRing: some View {
        Gauge(value: min(1, max(0, snap.goalFraction ?? 0)), in: 0...1) {
            Image(systemName: snap.goalSymbol ?? "target")
        } currentValueLabel: {
            // Without a measured fraction the gauge would read "0%", which is a claim. Show the mark
            // instead and let the number be absent.
            if let fraction = snap.goalFraction {
                Text("\(Int((fraction * 100).rounded()))")
            } else {
                Image(systemName: snap.goalSymbol ?? "target")
            }
        }
        .gaugeStyle(.accessoryCircular)
        .tint(tint)
    }

    private var accessoryRectangle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("GOAL")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(StrandPalette.textSecondary)
            Text(snap.goalTitle ?? "")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if let detail = runwayText ?? snap.goalLine {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var inlineText: String {
        guard let title = snap.goalTitle else { return "NOOP" }
        guard let runway = runwayText else { return title }
        return "\(title) · \(runway)"
    }

    // MARK: - Empty

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "target")
                .font(.system(size: 22))
                .foregroundStyle(StrandPalette.textTertiary)
            Text("No active goal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
            Text("Set one in NOOP and it shows up here.")
                .font(.caption2)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    // MARK: - Text

    /// "9 weeks to go" — or nothing at all. A passed target date says so rather than counting negative
    /// weeks at the user.
    private var runwayText: String? {
        guard let weeks = snap.goalRunwayWeeks else { return nil }
        if weeks < 0 { return String(localized: "Target date passed") }
        return String(localized: "\(Int(weeks.rounded())) weeks to go")
    }
}

struct NOOPGoalWidget: Widget {
    let kind = "NOOPGoalWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPProvider()) { entry in
            if #available(iOS 17.0, *) {
                NOOPGoalWidgetView(entry: entry)
                    .containerBackground(StrandPalette.surfaceBase, for: .widget)
                    // Tapping lands on Goal & Journey, through the same `noop://` scheme the Shortcuts
                    // health import already uses (see `StrandiOSApp`'s `onOpenURL`).
                    .widgetURL(URL(string: "noop://goal"))
            } else {
                NOOPGoalWidgetView(entry: entry)
                    .padding()
                    .background(StrandPalette.surfaceBase)
                    .widgetURL(URL(string: "noop://goal"))
            }
        }
        .configurationDisplayName("Goal")
        .description("What you're working towards, with real progress when there's a measurement behind it.")
        .supportedFamilies([
            .systemSmall, .systemMedium,
            .accessoryCircular, .accessoryInline, .accessoryRectangular
        ])
    }
}
