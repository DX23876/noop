#if os(iOS)
import SwiftUI

/// The dot on the header's coach button while the coach has written something on its own that has not been seen.
/// Its own leaf, so only this dot follows the coach's updates while a reply streams, not the page's header.
struct ForgeCoachUnseenDot: View {
    @EnvironmentObject private var coach: AICoachEngine

    var body: some View {
        if coach.hasUnseenCoachMessage {
            Circle()
                .fill(ForgeColor.accent)
                .frame(width: 9, height: 9)
                .offset(x: -2, y: 2)
                .accessibilityLabel(Text("New message from the coach"))
        }
    }
}
#endif
