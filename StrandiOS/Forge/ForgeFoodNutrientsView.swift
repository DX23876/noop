#if os(iOS)
import SwiftUI
import StrandDesign
import StrandCore
import StrandAnalytics

/// Names and units of the nutrients as the Food screens say them.
enum FoodNutrientText {
    static func name(_ n: FoodNutrient) -> String {
        switch n {
        case .proteinG: return String(localized: "Protein")
        case .fiberG: return String(localized: "Fibre")
        case .sugarG: return String(localized: "Sugar")
        case .satFatG: return String(localized: "Saturated fat")
        case .monoFatG: return String(localized: "Monounsaturated fat")
        case .polyFatG: return String(localized: "Polyunsaturated fat")
        case .omega3G: return String(localized: "Omega-3, total")
        case .epaG: return String(localized: "Omega-3 from fish (EPA and DHA)")
        case .cholesterolMg: return String(localized: "Cholesterol")
        case .saltG: return String(localized: "Salt")
        case .sodiumMg: return String(localized: "Sodium")
        case .potassiumMg: return String(localized: "Potassium")
        case .calciumMg: return String(localized: "Calcium")
        case .magnesiumMg: return String(localized: "Magnesium")
        case .phosphorusMg: return String(localized: "Phosphorus")
        case .ironMg: return String(localized: "Iron")
        case .zincMg: return String(localized: "Zinc")
        case .iodineUg: return String(localized: "Iodine")
        case .copperMg: return String(localized: "Copper")
        case .manganeseMg: return String(localized: "Manganese")
        case .vitaminAUg: return String(localized: "Vitamin A")
        case .vitaminDUg: return String(localized: "Vitamin D")
        case .vitaminEMg: return String(localized: "Vitamin E")
        case .vitaminKUg: return String(localized: "Vitamin K")
        case .thiaminMg: return String(localized: "Vitamin B1")
        case .riboflavinMg: return String(localized: "Vitamin B2")
        case .niacinMg: return String(localized: "Niacin")
        case .vitaminB6Mg: return String(localized: "Vitamin B6")
        case .folateUg: return String(localized: "Folate")
        case .vitaminB12Ug: return String(localized: "Vitamin B12")
        case .vitaminCMg: return String(localized: "Vitamin C")
        case .pantothenicMg: return String(localized: "Pantothenic acid")
        case .biotinUg: return String(localized: "Biotin")
        default: return n.rawValue
        }
    }

    static func amount(_ value: Double, _ n: FoodNutrient) -> String {
        let unit: String
        switch n.unit { case .kcal: unit = "kcal"; case .g: unit = "g"; case .mg: unit = "mg"; case .ug: unit = "µg" }
        let digits = value < 1 ? 2 : value < 10 ? 1 : 0
        return value.formatted(.number.precision(.fractionLength(0...digits)).locale(AppLanguage.activeLocale)) + " " + unit
    }

    static func groupName(_ group: String) -> String {
        switch group {
        case "minerals": return String(localized: "Minerals")
        case "vitamins": return String(localized: "Vitamins")
        default: return String(localized: "Fats, fibre and protein")
        }
    }
}

/// The Food page's nutrient card: how many nutrients are in range over the last seven days, the ones to look at.
struct ForgeFoodNutrientCard: View {
    let report: FoodNutrientReport.Report?
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Nutrients").font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(ForgeColor.tertiary)
                }
                if let report, report.judgedCount > 0 {
                    Text("\(report.fineCount) of \(report.judgedCount) in range, last \(report.loggedDays) logged days")
                        .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                    let attention = report.rows.filter { $0.status == .attention }.prefix(3)
                    ForEach(Array(attention), id: \.nutrient) { row in
                        HStack {
                            Circle().fill(ForgeColor.effort).frame(width: 7, height: 7)
                            Text(FoodNutrientText.name(row.nutrient)).font(ForgeFont.body).foregroundStyle(ForgeColor.text)
                            Spacer()
                            if let reference = row.reference {
                                Text("\(Int((row.average / max(0.0001, reference.amount) * 100).rounded())) %")
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(ForgeColor.effortInk)
                            }
                        }
                    }
                } else {
                    Text("Log a few days to see vitamins and minerals against what your body needs.")
                        .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                }
            }
            .forgeCard()
        }
        .buttonStyle(.plain)
    }
}

/// Every nutrient of the last seven logged days against the EFSA reference, grouped, with what it came from.
struct ForgeFoodNutrientsView: View {
    let report: FoodNutrientReport.Report
    @State private var open: FoodNutrient?
    @State private var scrolledPast = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForgeDetailHeader(overline: String(localized: "Last 7 days"), title: String(localized: "Nutrients"),
                                  scrolledPast: $scrolledPast)
                Text("Averages per logged day. Reference values describe what you eat over time, so one day says little. Where too little of what you logged states a nutrient, Forge says so instead of guessing.")
                    .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary).padding(.horizontal, 4)
                ForEach(FoodNutrientReport.groups, id: \.name) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(FoodNutrientText.groupName(group.name)).font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                            .padding(.bottom, 6)
                        ForEach(group.nutrients, id: \.self) { nutrient in
                            if let row = report.rows.first(where: { $0.nutrient == nutrient }) {
                                Rectangle().fill(ForgeColor.separator).frame(height: 0.5)
                                rowView(row)
                            }
                        }
                    }
                    .forgeCard()
                }
                Text("Reference values: EFSA Dietary Reference Values for adults; salt and saturated fat: WHO. Not medical advice.")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.tertiary).padding(.horizontal, 4)
            }
            .padding(.horizontal, 16).padding(.bottom, 32)
        }
        .background(ForgeBackground(tab: .today))
        .forgeDetailBar(title: String(localized: "Nutrients"), showsTitle: scrolledPast)
    }

    private func rowView(_ row: FoodNutrientReport.Row) -> some View {
        let share = row.reference.map { row.average / max(0.0001, $0.amount) } ?? 0
        let tint: Color = switch row.status {
        case .fine: ForgeColor.charge
        case .attention: ForgeColor.effort
        default: ForgeColor.tertiary
        }
        return VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation { open = open == row.nutrient ? nil : row.nutrient } } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(FoodNutrientText.name(row.nutrient)).font(.system(.callout, weight: .semibold))
                            .foregroundStyle(ForgeColor.text)
                        Spacer()
                        Text(FoodNutrientText.amount(row.average, row.nutrient))
                            .font(.system(.subheadline, design: .rounded, weight: .semibold)).foregroundStyle(ForgeColor.text)
                    }
                    if let reference = row.reference {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(ForgeColor.fill)
                                Capsule().fill(tint).frame(width: geo.size.width * min(1, share))
                            }
                        }
                        .frame(height: 6)
                        Text(caption(row, reference)).font(.system(.footnote)).foregroundStyle(ForgeColor.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            if open == row.nutrient, !row.topFoods.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Mostly from").font(.system(.caption, weight: .semibold)).foregroundStyle(ForgeColor.secondary)
                    ForEach(row.topFoods, id: \.name) { source in
                        HStack {
                            Text(source.name).font(.footnote).foregroundStyle(ForgeColor.text).lineLimit(1)
                            Spacer()
                            Text(FoodNutrientText.amount(source.amount, row.nutrient)).font(.footnote).foregroundStyle(ForgeColor.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func caption(_ row: FoodNutrientReport.Row, _ reference: FoodReference.Value) -> String {
        let ref = FoodNutrientText.amount(reference.amount, row.nutrient)
        switch row.status {
        case .incomplete:
            return String(localized: "Not enough data: only \(Int((row.coverage * 100).rounded())) % of what you logged states it.")
        default:
            let base = reference.kind == .atLeast
                ? String(localized: "Reference \(ref) a day (\(reference.source))")
                : String(localized: "Limit \(ref) a day (\(reference.source))")
            guard row.estimatedShare >= 0.05 else { return base }
            return base + " · " + String(localized: "\(Int((row.estimatedShare * 100).rounded())) % estimated")
        }
    }
}
#endif
