#if os(iOS)
import SwiftUI
import StrandCore

/// The short celebration of a newly earned badge.
struct FoodBadgeCelebration: View {
    let earned: FoodBadges.Earned
    let done: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 16) {
            FoodBadgeMedal(badge: earned.badge, earned: true, size: 96)
                // With Reduce Motion the medal fades in instead of growing.
                .scaleEffect(shown || reduceMotion ? 1 : 0.6)
                .opacity(shown ? 1 : 0)
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
        .onAppear(perform: appear)
    }

    private func appear() {
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.4)) { shown = true }
    }
}
#endif
