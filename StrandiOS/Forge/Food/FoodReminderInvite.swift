#if os(iOS)
import SwiftUI

/// Asks once whether the food reminders may start: a morning look back and an evening reminder only when one meal
/// can still close a gap. Notifications stay off until the wearer says yes, as everywhere in the project.
struct FoodReminderInvite: View {
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Daily look back", systemImage: "bell.badge")
                .font(ForgeFont.cardTitle).foregroundStyle(ForgeColor.text)
            Text("Each morning your note and goal from yesterday, and on Mondays the week. In the evening only when one meal can still close a gap.")
                .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button(action: accept) {
                    Text("Turn on").font(.headline).foregroundStyle(ForgeColor.onAccent)
                        .padding(.horizontal, 20).frame(minHeight: 44)
                        .background(ForgeColor.accent, in: .capsule)
                }
                .buttonStyle(.plain)
                Button("Not now", action: decline)
                    .font(ForgeFont.body).foregroundStyle(ForgeColor.secondary)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 12)
            }
        }
        .forgeCard(radius: ForgeRadius.card, padding: 16)
    }
}
#endif
