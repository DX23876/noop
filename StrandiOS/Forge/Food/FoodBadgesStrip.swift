#if os(iOS)
import SwiftUI
import StrandCore

/// The earned badges on the Food page, newest first, and a way into the whole collection.
struct FoodBadgesStrip: View {
    let summary: FoodBadges.Summary
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                if summary.earned.isEmpty {
                    Image(systemName: "rosette").font(.title2).foregroundStyle(ForgeColor.tertiary)
                    Text("Badges come from logging, eating well and keeping habits.")
                        .font(ForgeFont.caption).foregroundStyle(ForgeColor.secondary)
                        .multilineTextAlignment(.leading)
                } else {
                    HStack(spacing: -8) {
                        ForEach(summary.earned.suffix(4).reversed(), id: \.badge) { earned in
                            FoodBadgeMedal(badge: earned.badge, earned: true, size: 40)
                        }
                    }
                    Text("\(summary.earned.count) of \(FoodText.allBadges.count) badges")
                        .font(ForgeFont.body.weight(.semibold)).foregroundStyle(ForgeColor.text)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(ForgeColor.tertiary)
            }
            .forgeCard(radius: ForgeRadius.card, padding: 16)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
#endif
