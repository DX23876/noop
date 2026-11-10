#if os(iOS)
import SwiftUI

/// Under a day's meals: the wearer marks the day as completely logged (owner, 2026-11-10). Only marked days count
/// when Forge works out the real burn from food and weight. From the evening on, an unmarked today asks instead.
/// The one place the mark is shown or set, so it cannot disagree with itself.
struct FoodCompleteDayRow: View {
    let complete: Bool
    let asks: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(complete ? ForgeColor.chargeInk : ForgeColor.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(complete ? String(localized: "Everything logged")
                         : asks ? String(localized: "Did you log everything today?") : String(localized: "Mark as completely logged"))
                        .font(.subheadline.weight(.semibold)).foregroundStyle(ForgeColor.text)
                    Text("Only completely logged days count toward your real burn.")
                        .font(.footnote).foregroundStyle(ForgeColor.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(asks && !complete ? ForgeColor.accent.opacity(0.12) : ForgeColor.card,
                        in: .rect(cornerRadius: ForgeRadius.card))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(complete ? [.isButton, .isSelected] : .isButton)
        .sensoryFeedback(.selection, trigger: complete)
    }
}
#endif
