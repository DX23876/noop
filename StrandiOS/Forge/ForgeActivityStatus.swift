#if os(iOS)
import SwiftUI
import StrandDesign

// The wearer's own day status in the new design. The status itself (`ActivityStatus`, four states with a
// validity window and a silent reset) and its sheet (`SharedActivityStatusSheet`) both already existed and
// are unchanged here; what was missing was any way to reach them. The old Today carried a chip, the new one
// carried nothing, so from the redesign onwards nobody could say "I am ill" and the app kept proposing
// training (owner, 2026-11-20).
//
// Analysis migration required: no. This sets an input the app already read; no stored derived value changes.

/// The Log sheet's "Status" entry: the shared sheet, with the stored status loaded into it.
struct ActivityStatusQuickSheet: View {
    @State private var status = ActivityStatusStore.load()

    var body: some View {
        SharedActivityStatusSheet(status: $status)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }
}

/// The line at the head of Today while the status is not `active`.
///
/// A status nobody can see is a status nobody remembers setting, and it quietly suppresses the training
/// suggestions. So it says itself, with how long it holds.
///
/// Tapping the line OPENS the sheet; only the labelled button ends the status. That split is the rule the
/// hint card was written under: a tap on a card body must not commit anything the card does not say it
/// commits.
struct ForgeActivityStatusLine: View {
    /// Observed, not read once: the sheet and the "Unwell" chip both write this key, and a line that read
    /// it on appear alone would keep showing a status the reader had just ended.
    @AppStorage(ActivityStatusStore.key) private var stored: Data?
    @State private var editing = false
    private var status: ActivityStatus { ActivityStatusStore.decode(stored) }

    var body: some View {
        Group {
            if status.state != .active {
                HStack(spacing: 12) {
                    Image(systemName: status.state.symbolName)
                        .font(.system(.body, weight: .semibold))
                        .foregroundStyle(ForgeColor.effort)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(ForgeColor.effort.opacity(ForgeOpacity.wash)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.state.displayName)
                            .font(.system(.subheadline, weight: .semibold))
                            .foregroundStyle(ForgeColor.text)
                        Text(Self.holdsUntil(status))
                            .font(ForgeFont.caption)
                            .foregroundStyle(ForgeColor.secondaryOnPicture)
                    }
                    Spacer(minLength: 8)
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { ActivityStatusStore.save(.active) }
                    } label: {
                        Text("End")
                            .font(.system(.subheadline, weight: .medium))
                            .foregroundStyle(ForgeColor.accent)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 34)
                            .background(Capsule().fill(ForgeColor.fill))
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .forgeCard(radius: ForgeRadius.card, padding: 0)
                .contentShape(Rectangle())
                .onTapGesture { editing = true }
            }
        }
        .sheet(isPresented: $editing) {
            ActivityStatusQuickSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    /// How long the status holds, in the reader's words. A status set for "today" stores the START of
    /// tomorrow, which printed as a date would name a day the wearer never chose.
    static func holdsUntil(_ status: ActivityStatus, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let until = status.validUntil else { return String(localized: "Until you change it") }
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        if let endOfToday, until <= endOfToday { return String(localized: "For today") }
        return String(localized: "Until \(until.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(AppLanguage.activeLocale)))")
    }
}
#endif
