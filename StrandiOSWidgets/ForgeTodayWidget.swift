import WidgetKit
import SwiftUI
import StrandDesign

/// The redesign's Home Screen and Lock Screen widget (2026-11, "New design (preview)"): the three scores as
/// soft glowing rings in the Forge colours, and on the larger sizes the coach's latest stored brief line.
/// Reads only what the other widgets read (`WidgetSnapshot` and the stored brief text), never the network,
/// so it is a third presentation of the same data rather than a new data path.
struct ForgeTodayEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let brief: String?
}

struct ForgeTodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> ForgeTodayEntry {
        ForgeTodayEntry(date: Date(), snapshot: .placeholder, brief: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (ForgeTodayEntry) -> Void) {
        let fallback: WidgetSnapshot = context.isPreview ? .placeholder : .unavailable
        completion(ForgeTodayEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? fallback, brief: Self.brief()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ForgeTodayEntry>) -> Void) {
        let entry = ForgeTodayEntry(date: Date(), snapshot: WidgetSnapshot.load() ?? .unavailable, brief: Self.brief())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    /// The first sentence of the stored brief (the same App Group key the Coach brief widget reads).
    private static func brief() -> String? {
        guard let text = UserDefaults(suiteName: WidgetSnapshot.suiteName)?.string(forKey: "coachBrief.widgetText")?
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let line = text.split(separator: "\n").first.map(String.init) ?? text
        if let end = line.firstIndex(where: { ".!?".contains($0) }) { return String(line[...end]) }
        return line
    }
}

/// The Forge palette for the widget (the app's `ForgeColor` lives in the app target).
private enum ForgeWidgetColor {
    static func pick(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
    static var canvas: Color { NoopVisualStyle.canvas }
    static let text = pick(0x000000, 0xFFFFFF)
    static let secondary = pick(0x6B6B70, 0xA8A8B0)
    static var accent: Color { StrandPalette.forgeAccent }
    static let effort = pick(0xD45F28, 0xFF8A3D)
    static let rest = pick(0x5B4DBF, 0xA996FF)
}

private struct ForgeWidgetRing: View {
    let value: Int?
    let tint: Color
    let label: String
    /// The figure printed inside the ring when it differs from `value`, e.g. Effort on the 0 to 21 axis;
    /// the fill always stays `value / 100`.
    var shown: String? = nil
    var size: CGFloat = 58

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(tint.opacity(0.10))
                Circle()
                    .trim(from: 0, to: Double(value ?? 0) / 100)
                    .stroke(tint, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: tint.opacity(0.55), radius: 5)
                Text(shown ?? value.map(String.init) ?? "–")
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .foregroundStyle(ForgeWidgetColor.text)
                    .minimumScaleFactor(0.6)
            }
            .frame(width: size, height: size)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(ForgeWidgetColor.secondary)
        }
    }
}

struct ForgeTodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: ForgeTodayEntry

    private var snap: WidgetSnapshot { entry.snapshot }
    private var chargeTint: Color {
        snap.recovery.map { StrandPalette.chargeRingColor(Double($0)) } ?? StrandPalette.chargeColor
    }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("Today").font(.system(size: 12, weight: .semibold)).widgetAccentable()
                Text("\(snap.recovery.map(String.init) ?? "–") · \(snap.effortDisplay ?? snap.effort.map(String.init) ?? "–") · \(snap.rest.map(String.init) ?? "–")")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Charge · Effort · Rest").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .systemLarge, .systemMedium:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    ForgeWidgetRing(value: snap.recovery, tint: chargeTint, label: "Charge").frame(maxWidth: .infinity)
                    ForgeWidgetRing(value: snap.effort, tint: ForgeWidgetColor.effort, label: "Effort",
                                    shown: snap.effort == nil ? nil : snap.effortDisplay).frame(maxWidth: .infinity)
                    ForgeWidgetRing(value: snap.rest, tint: ForgeWidgetColor.rest, label: "Rest").frame(maxWidth: .infinity)
                }
                if let brief = entry.brief {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(ForgeWidgetColor.accent)
                        Text(brief).font(.system(size: 13, weight: .medium)).foregroundStyle(ForgeWidgetColor.text)
                            .lineLimit(family == .systemLarge ? 4 : 2)
                    }
                }
            }
            .padding(4)
        default:
            ForgeWidgetRing(value: snap.recovery, tint: chargeTint, label: "Charge", size: 86)
        }
    }
}

struct ForgeTodayWidget: Widget {
    let kind = "ForgeTodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ForgeTodayProvider()) { entry in
            ForgeTodayWidgetView(entry: entry)
                .appGroupNotice()
                .containerBackground(ForgeWidgetColor.canvas, for: .widget)
        }
        .configurationDisplayName("Forge Today")
        .description("Charge, Effort and Rest in the new design, with the coach's latest line.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}
