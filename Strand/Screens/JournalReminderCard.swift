import SwiftUI
import StrandDesign

// MARK: - Journal widget (Today screen) — #627
//
// A persistent Today widget for the Journal: a WHOOP-style strip of the last `stripDays` days
// (filled = a journal entry that day, today ringed) plus an always-present tap-through to the journal.
// The Journal (behavioural logging that feeds Insights / "What Moves You") is otherwise only reachable
// inside the Insights screen, which isn't a primary destination — easy to forget, and the only proactive
// prompt is the once-a-morning sleep sheet — missed on any day you don't open Sleep. This surfaces it on
// Today where it can't be missed, and doubles as the "direct link to Insights" the report (#627) asked for.
//
// Opt-out via `PuffinExperiment.journalReminderKey` (default ON — the same key also gates the Android
// morning sleep sheet twin). Read-only: it never writes a journal entry. Twin of Android
// `JournalReminderCard` (android/.../ui/JournalReminder.kt). Design-Reset compliant — a flat accent-tinted
// NoopCard, NoopMetrics / StrandPalette / StrandFont tokens, matching the other Today cards.

struct JournalReminderCard: View {

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter

    /// Default ON so the reminder works out of the box; the Settings toggle / this key opt out.
    @AppStorage(PuffinExperiment.journalReminderKey) private var reminderEnabled = true

    /// Which of the last `stripDays` day-keys carry a native journal entry. nil = still loading / read
    /// error → render nothing (never a misleading all-empty strip).
    @State private var loggedDays: Set<String>?

    private static let stripDays = 7

    var body: some View {
        Group {
            if reminderEnabled, let logged = loggedDays {
                card(logged)
            }
        }
        // Re-read whenever a sync bumps refreshSeq or the toggle flips (mirrors AutoWorkoutCard's task id),
        // so the strip and the "logged today" state stay current after the user logs and comes back.
        .task(id: JournalReminderLoadKey(seq: repo.refreshSeq, enabled: reminderEnabled)) {
            await reload()
        }
    }

    private func card(_ logged: Set<String>) -> some View {
        let keys = Self.dayKeys()
        let todayKey = keys.last ?? ""
        let todayLogged = logged.contains(todayKey)
        return Button {
            router.openJournal()
        } label: {
            NoopCard(tint: StrandPalette.accent) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack(spacing: NoopMetrics.space2) {
                        Image(systemName: "book.closed")
                            .font(.system(size: 18))
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text(String(localized: "Journal"))
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                    // The last-N-days strip: one equal-width bar per day. Filled = logged; today is ringed
                    // so the orientation is unambiguous even when nothing is logged yet.
                    HStack(spacing: 6) {
                        ForEach(keys, id: \.self) { key in
                            let isLogged = logged.contains(key)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isLogged ? StrandPalette.accent : StrandPalette.textTertiary.opacity(0.22))
                                .frame(maxWidth: .infinity)
                                .frame(height: 10)
                                .overlay {
                                    if key == todayKey, !isLogged {
                                        RoundedRectangle(cornerRadius: 3)
                                            .strokeBorder(StrandPalette.accent, lineWidth: 1)
                                    }
                                }
                        }
                    }
                    Text(todayLogged
                         ? String(localized: "Logged today")
                         : String(localized: "Log today's journal"))
                        .font(StrandFont.footnote)
                        .foregroundStyle(todayLogged ? StrandPalette.textSecondary : StrandPalette.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(String(localized: "Journal")))
        .accessibilityHint(Text(String(localized: "Open journal")))
    }

    private func reload() async {
        guard reminderEnabled else { loggedDays = nil; return }
        let keys = Self.dayKeys()
        loggedDays = await repo.nativeJournalDays(from: keys.first ?? "", to: keys.last ?? "")
    }

    /// The `stripDays` local-day keys (yyyy-MM-dd), oldest → today, matching Android's `journalDayKey`
    /// (civil-day arithmetic via Calendar so a DST edge can't mislabel a day).
    private static func dayKeys() -> [String] {
        let cal = Calendar.current
        let today = Date()
        return (0..<stripDays).reversed().map { n in
            Repository.localDayKey(cal.date(byAdding: .day, value: -n, to: today) ?? today)
        }
    }
}

/// Reload key: a sync (seq) or toggle flip re-reads completion. Mirrors `AutoWorkoutLoadKey`.
private struct JournalReminderLoadKey: Equatable {
    let seq: Int
    let enabled: Bool
}
