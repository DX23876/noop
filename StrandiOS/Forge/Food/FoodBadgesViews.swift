#if os(iOS)
import SwiftUI
import StrandCore
import WhoopStore

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

/// One badge as a round medal: coloured when earned, a quiet outline while still to come.
struct FoodBadgeMedal: View {
    let badge: FoodBadges.Badge
    let earned: Bool
    var size: CGFloat = 56

    var body: some View {
        Image(systemName: FoodText.badgeSymbol(badge))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(earned ? ForgeColor.onAccent : ForgeColor.tertiary)
            .frame(width: size, height: size)
            .background(Circle().fill(earned ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(ForgeColor.fill)))
            .overlay(Circle().strokeBorder(ForgeColor.card, lineWidth: earned ? 2 : 0))
            .accessibilityHidden(true)
    }

    private var tint: Color {
        switch badge {
        case .firstFullWeek, .days30, .days100: ForgeColor.effort
        case .goodWeek, .goodMonth: ForgeColor.fat
        case .habit: ForgeColor.nutrientLeaf
        }
    }
}

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

/// The short celebration of a newly earned badge.
struct FoodBadgeCelebration: View {
    let earned: FoodBadges.Earned
    let done: () -> Void
    @State private var shown = false

    var body: some View {
        VStack(spacing: 16) {
            FoodBadgeMedal(badge: earned.badge, earned: true, size: 96)
                .scaleEffect(shown ? 1 : 0.6)
                .symbolEffect(.bounce, value: shown)
            Text("New badge").font(ForgeFont.caption.weight(.semibold)).foregroundStyle(ForgeColor.secondary)
            Text(FoodText.badgeTitle(earned.badge)).font(ForgeFont.headerTitle).foregroundStyle(ForgeColor.text)
                .multilineTextAlignment(.center)
            Text(FoodText.badgeDetail(earned.badge)).font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                .multilineTextAlignment(.center)
            Button(action: done) {
                Text("Nice").font(.headline).foregroundStyle(ForgeColor.onAccent)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(ForgeColor.accent, in: .capsule)
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
        .padding(24)
        .presentationDetents([.medium])
        .sensoryFeedback(.success, trigger: shown)
        .onAppear { withAnimation(.spring(duration: 0.5, bounce: 0.4)) { shown = true } }
    }
}
#endif
