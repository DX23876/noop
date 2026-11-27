import WidgetKit
import SwiftUI
import StrandDesign

/// Today's eating on the home screen (owner, 2026-11-25): calories left of the goal, and protein, carbohydrate
/// and fat against theirs in the Food page's own colours. Reads only the App Group snapshot the app writes
/// (`WidgetFoodSnapshot`); a tap opens the Food page.
struct NOOPFoodEntry: TimelineEntry {
    let date: Date
    let food: WidgetFoodSnapshot?
}

struct NOOPFoodProvider: TimelineProvider {
    func placeholder(in context: Context) -> NOOPFoodEntry {
        NOOPFoodEntry(date: Date(), food: WidgetFoodSnapshot(day: WidgetSnapshot.localDayKey(Date()), eatenKcal: 1_240,
                                                             goalKcal: 2_300, proteinG: 82, carbsG: 130, fatG: 44,
                                                             proteinGoal: 140, carbsGoal: 250, fatGoal: 75))
    }

    func getSnapshot(in context: Context, completion: @escaping (NOOPFoodEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : NOOPFoodEntry(date: Date(), food: WidgetFoodSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NOOPFoodEntry>) -> Void) {
        let now = Date()
        // One entry now and one at midnight, when today's figures stop being today's.
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
        completion(Timeline(entries: [NOOPFoodEntry(date: now, food: WidgetFoodSnapshot.load(now: now)),
                                      NOOPFoodEntry(date: midnight, food: nil)], policy: .atEnd))
    }
}

/// The Food page's colours (iOS `ForgeColor.food/protein/carbs/fat`), set here because the widget does not link
/// the app's Forge theme. Light and dark, as there.
private enum FoodWidgetInk {
    static func pick(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
    static let food = pick(0xD42A1C, 0xFF4B33)
    static let protein = pick(0x7C3AED, 0xB173FF)
    static let carbs = pick(0x0A6FD1, 0x3DB8FF)
    static let fat = pick(0xB58900, 0xFFD60A)
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

struct NOOPFoodWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NOOPFoodEntry

    var body: some View {
        Group {
            switch family {
            case .accessoryInline: inline
            case .accessoryRectangular: rectangular
            case .systemMedium: medium
            default: small
            }
        }
        .widgetURL(URL(string: "noop://food"))
        .accessibilityElement(children: .combine)
    }

    private var food: WidgetFoodSnapshot? { entry.food }

    private var headline: String {
        guard let food else { return "–" }
        return "\(food.leftKcal ?? food.eatenKcal)"
    }

    private var caption: LocalizedStringKey {
        guard let food else { return "Nothing logged today" }
        return food.leftKcal != nil ? "kcal left today" : "kcal eaten today"
    }

    private var inline: some View {
        Text(verbatim: food.map { "\($0.eatenKcal) kcal" } ?? "–")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Nutrition", systemImage: "fork.knife").font(.caption2.weight(.semibold))
            Text(verbatim: headline).font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
            Text(caption).font(.system(size: 9)).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Nutrition", systemImage: "fork.knife")
                .font(.caption.weight(.semibold)).foregroundStyle(FoodWidgetInk.food)
            Spacer(minLength: 0)
            Text(verbatim: headline).font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
                .minimumScaleFactor(0.6)
            Text(caption).font(.caption).foregroundStyle(StrandPalette.textSecondary)
            if let food { bars(food) }
        }
        .padding(12)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Nutrition", systemImage: "fork.knife")
                    .font(.caption.weight(.semibold)).foregroundStyle(FoodWidgetInk.food)
                Spacer(minLength: 0)
                Text(verbatim: headline).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
                Text(caption).font(.caption).foregroundStyle(StrandPalette.textSecondary)
            }
            if let food {
                VStack(alignment: .leading, spacing: 8) {
                    macro("Protein", food.proteinG, food.proteinGoal, FoodWidgetInk.protein)
                    macro("Carbs", food.carbsG, food.carbsGoal, FoodWidgetInk.carbs)
                    macro("Fat", food.fatG, food.fatGoal, FoodWidgetInk.fat)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
    }

    private func bars(_ food: WidgetFoodSnapshot) -> some View {
        HStack(spacing: 4) {
            bar(food.proteinG, food.proteinGoal, FoodWidgetInk.protein)
            bar(food.carbsG, food.carbsGoal, FoodWidgetInk.carbs)
            bar(food.fatG, food.fatGoal, FoodWidgetInk.fat)
        }
        .frame(height: 6)
    }

    private func macro(_ name: LocalizedStringKey, _ value: Int, _ goal: Int?, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(name).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 4)
                Text(verbatim: Self.grams(value, of: goal)).font(.caption2.weight(.semibold)).monospacedDigit()
            }
            bar(value, goal, tint).frame(height: 6)
        }
    }

    /// "82 / 140 g", the figure and its goal, or the figure alone.
    static func grams(_ value: Int, of goal: Int?) -> String {
        let figure = goal.map { [String(value), String($0)].joined(separator: " / ") } ?? String(value)
        return figure + " g"
    }

    private func bar(_ value: Int, _ goal: Int?, _ tint: Color) -> some View {
        GeometryReader { geo in
            let share = goal.map { $0 > 0 ? min(1, Double(value) / Double($0)) : 0 } ?? 0
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.2))
                Capsule().fill(tint).frame(width: geo.size.width * share)
            }
        }
    }
}

struct NOOPFoodWidget: Widget {
    let kind = WidgetFoodSnapshot.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NOOPFoodProvider()) { entry in
            NOOPFoodWidgetView(entry: entry)
                .appGroupNotice().containerBackground(StrandPalette.surfaceBase, for: .widget)
        }
        .configurationDisplayName("NOOP Nutrition")
        .description("Calories left today, with protein, carbohydrate and fat.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryRectangular])
    }
}
