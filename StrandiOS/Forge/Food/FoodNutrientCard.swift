#if os(iOS)
import SwiftUI
import StrandCore

/// The Food page's nutrient card: how many nutrients are in range over the last seven days, and the few to look at.
struct FoodNutrientCard: View {
    let report: FoodNutrientReport.Report?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Nutrients").font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote).bold().foregroundStyle(ForgeColor.tertiary)
                        .accessibilityHidden(true)
                }
                if let report, report.judgedCount > 0 {
                    Text("\(report.fineCount) of \(report.judgedCount) in range, last \(report.loggedDays) logged days")
                        .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                    ForEach(report.rows.filter { $0.status == .attention }.prefix(3), id: \.nutrient) { row in
                        HStack {
                            Label(FoodText.nutrient(row.nutrient), systemImage: "exclamationmark.circle.fill")
                                .labelStyle(FoodStatusLabelStyle(tint: ForgeColor.effort))
                            Spacer()
                            if let reference = row.reference {
                                Text(FoodText.percent(row.average / max(0.0001, reference.amount)))
                                    .font(.subheadline).bold().foregroundStyle(ForgeColor.effortInk)
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
#endif
