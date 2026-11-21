#if os(iOS)
import SwiftUI
import StrandCore
import WhoopStore

/// Every badge: what earns it, and when it was earned.
struct FoodBadgesView: View {
    let summary: FoodBadges.Summary

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 16, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if summary.streakDays >= 1 {
                    Label(String(localized: "\(summary.streakDays) days logged in a row"), systemImage: "flame.fill")
                        .font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.effortInk)
                }
                LazyVGrid(columns: columns, spacing: 24) {
                    ForEach(FoodText.allBadges, id: \.self) { badge in
                        let earned = summary.earned.first { $0.badge == badge }
                        VStack(spacing: 8) {
                            FoodBadgeMedal(badge: badge, earned: earned != nil)
                            Text(FoodText.badgeTitle(badge)).font(ForgeFont.caption.weight(.semibold))
                                .foregroundStyle(earned != nil ? ForgeColor.text : ForgeColor.secondary)
                                .multilineTextAlignment(.center)
                            Text(earned.flatMap { WeightSeries.date(forDay: $0.day) }?.formatted(date: .abbreviated, time: .omitted)
                                 ?? FoodText.badgeDetail(badge))
                                .font(.caption2).foregroundStyle(ForgeColor.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                    }
                }
                Text("A missed day a week does not break the run. Badges reward logging, eating well and keeping habits, never a bigger deficit.")
                    .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
            }
            .padding(16)
        }
        .background(ForgeColor.canvas)
        .navigationTitle("Badges")
        .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
