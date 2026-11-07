import SwiftUI
import StrandDesign
import StrandCore
import WhoopStore

// Analysis migration required: no. Moves the deleted-night list out of SleepView so the new design's
// Sleep tab shows it too; recompute and hide are unchanged.

/// The nights the wearer deleted whose deletion marker still stands, newest first, minus the ones hidden from
/// the list (`Repository.dismissedSleepManagementWindows`, #515), with what the last action on the list did.
/// The undo strip lasts seconds; this list is how a night deleted by mistake comes back afterwards.
struct DeletedSleepNightsSection: View {
    @EnvironmentObject private var repo: Repository
    @Environment(\.dashboardAppModel) private var appModel
    @State private var deletedSleepWindows: [DeletedSleepWindow] = []
    /// The window being recomputed, so its button says so and the other rows wait.
    @State private var recomputingDeletedSleep: DeletedSleepWindow?
    /// What the last action on the list did, shown for a few seconds (`deletedSleepNoteRevision` re-arms it).
    @State private var deletedSleepNote: DeletedSleepNote?
    @State private var deletedSleepNoteRevision = 0


    /// The deleted-night list and what its last action did. The note sits outside the card, so it still shows
    /// when hiding the last row takes the card away.
    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) { content }
            // Read with the sessions on each refresh, as the Sleep screen's load did.
            .task(id: repo.refreshSeq) { deletedSleepWindows = loadDeletedSleepWindows() }
            .task(id: deletedSleepNoteRevision) {
                guard deletedSleepNote != nil else { return }
                do { try await Task.sleep(nanoseconds: 6_000_000_000) }
                catch { return }
                withAnimation(.easeOut(duration: 0.2)) { deletedSleepNote = nil }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let deletedSleepNote {
            // On the card surface, not a bare tint: this sits over the night scene, where a faint wash left the
            // line unreadable.
            NoopCard(padding: NoopMetrics.space3, tint: StrandPalette.restColor) {
                Text(deletedSleepNote.message)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)
        }
        if !deletedSleepWindows.isEmpty { deletedSleepWindowsCard }
    }

    /// Each night the user deleted, with "Recompute this night" (lift its marker and detect it again from the raw
    /// data) and "Hide" (take the row away, keep the marker). Android's card, with its strings (#515).
    private var deletedSleepWindowsCard: some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text("Deleted sleep windows")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Recompute clears the deletion marker and scans the most recent 21 days.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(deletedSleepWindows) { window in deletedSleepRow(window) }
                Text("If this sleep came only from an import and no raw samples are stored, it may not reappear.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One deleted night: its window on a line of its own (two dates and times do not fit beside two buttons on
    /// a phone), its actions under it. Both wait while any night is being recomputed.
    private func deletedSleepRow(_ window: DeletedSleepWindow) -> some View {
        let idle = recomputingDeletedSleep == nil
        return VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(verbatim: "\(deletedSleepStamp(window.start)) – \(deletedSleepStamp(window.end))")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: NoopMetrics.space4) {
                Spacer(minLength: 0)
                Button { hideDeletedSleep(window) } label: {
                    Text("Hide").font(StrandFont.subhead)
                }
                .buttonStyle(LiquidPressStyle())
                .foregroundStyle(idle ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                .disabled(!idle)
                .accessibilityLabel("Hide this deleted sleep window")
                Button { Task { await recomputeDeletedSleep(window) } } label: {
                    // Two Texts, not one over a ternary: a ternary of literals is a String, which Text shows
                    // untranslated.
                    Group {
                        if recomputingDeletedSleep == window { Text("Recomputing…") } else { Text("Recompute this night") }
                    }
                    .font(StrandFont.subhead.weight(.semibold))
                }
                .buttonStyle(LiquidPressStyle())
                .foregroundStyle(idle ? StrandPalette.restColor : StrandPalette.textTertiary)
                .disabled(!idle)
                .accessibilityLabel("Recompute this deleted sleep night")
            }
        }
    }

    /// "3 Oct, 23:10" in the app's language: a deleted window can span midnight, so each end carries its date.
    private func deletedSleepStamp(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts))
            .formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(AppClock.formattingLocale))
    }

    private func loadDeletedSleepWindows() -> [DeletedSleepWindow] {
        repo.dismissedSleepManagementWindows().map { DeletedSleepWindow(start: $0.start, end: $0.end) }
    }

    /// Lift the night's marker, then run the normal recent scan. An older night is outside that 21-day window;
    /// the success note reports only the marker change, not whether detection processed or restored this night.
    private func recomputeDeletedSleep(_ window: DeletedSleepWindow) async {
        recomputingDeletedSleep = window
        await repo.allowSleepReDetection(startTs: window.start, endTs: window.end)
        // Without day reuse: lifting a marker changes no raw input, so a fingerprint-reused day would keep
        // the night suppressed. The fork reaches the engine through the dashboard app model here.
        await appModel?.intelligence.analyzeRecent(force: true, allowDayReuse: false, reason: .semanticChange)
        await repo.refresh()
        deletedSleepWindows = loadDeletedSleepWindows()
        recomputingDeletedSleep = nil
        showDeletedSleepNote(.recomputed)
    }

    /// Take the row off the list; the marker stays, so the night stays deleted.
    private func hideDeletedSleep(_ window: DeletedSleepWindow) {
        repo.hideDeletedSleepWindow(startTs: window.start, endTs: window.end)
        withAnimation(.easeOut(duration: 0.2)) { deletedSleepWindows = loadDeletedSleepWindows() }
        showDeletedSleepNote(.hidden)
    }

    private func showDeletedSleepNote(_ note: DeletedSleepNote) {
        withAnimation(.easeOut(duration: 0.2)) { deletedSleepNote = note }
        deletedSleepNoteRevision += 1
    }
}

/// One night on the Sleep screen's deleted list: the window its deletion marker covers.
private struct DeletedSleepWindow: Identifiable, Equatable {
    let start: Int
    let end: Int
    var id: String { DismissedSleepSpans.token(startTs: start, endTs: end) }
}

/// What the last action on the deleted list changed (#515). Recompute reports only that its marker was lifted.
private enum DeletedSleepNote {
    case recomputed, hidden

    var message: LocalizedStringKey {
        switch self {
        case .recomputed: return "Deletion marker cleared."
        case .hidden: return "Deleted sleep window hidden. It will stay deleted."
        }
    }
}
