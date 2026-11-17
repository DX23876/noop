import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import StrandCore
import WhoopStore

// Analysis migration required: no. Moves the night editor out of SleepView so the new design's Sleep tab
// opens the same editor in place; the edit, delete, undo and re-score paths are unchanged.

/// The transient UNDO banner state after a suppressing delete (#65). `identityStart` is the immutable
/// detected key so a stale auto-dismiss task can tell whether it still owns the current banner;
/// `displayStart` is the effective (shown) onset for the message clock.
struct SleepUndoBanner {
    let snapshots: [SleepDeletionSnapshot]
    let identityStart: Int
    let displayStart: Int
    let windowEnd: Int
    let fromEdit: Bool
}

/// Seeds the "Add a nap" sheet (#508). A nap is short, so the picker opens on a 30-minute window an hour
/// after the night's wake — the time of day a missed afternoon nap usually sits — and the wearer moves it.
/// The identity is the seed start, so `.sheet(item:)` presents once per request.
struct AddNapSeed: Identifiable {
    let bedTs: Int
    let wakeTs: Int
    /// The night's wake the window is measured against, carried into the sheet so it can say what the
    /// chosen window will become (`SleepStageTotals.napEntryVerdict`) before it is written.
    let nightEndTs: Int
    var id: Int { bedTs }

    /// Seeded from the shared core (`SleepStageTotals.napEntrySeed`), which both platforms call: an early
    /// afternoon half hour, never inside the window the selector would fold back into the night. The
    /// suggestion used to be wake + 1 h, which is inside the night-tail bridge all morning — taken,
    /// counted into the day's figures, and then reported as no nap at all (#49).
    init(afterWake wakeTs: Int, now: Int = Int(Date().timeIntervalSince1970),
         offsetSec: Int = TimeZone.current.secondsFromGMT()) {
        let seed = SleepStageTotals.napEntrySeed(nightEnd: wakeTs, offsetSec: offsetSec, now: now)
        self.bedTs = seed.start
        self.wakeTs = seed.end
        self.nightEndTs = wakeTs
    }
}

struct WakeEdit: Identifiable {
    /// The exact bridged fragments represented by the editor's visible window. A nap is a one-row group.
    let group: [CachedSleepSession]
    let detectedStartTs: Int   // immutable detected key the edit writes against
    let bedTs: Int             // current effective onset (seeds the bed picker)
    let wakeTs: Int            // current wake (seeds the wake picker)
    /// True for a hand-edited / manually-added (nap) night. Such a delete writes NO tombstone (it is
    /// never re-detected), so the editor's delete-confirm copy must NOT promise re-detection suppression
    /// for it. Mirrors the undo-banner branch (#65 banner/confirm honesty).
    let userEdited: Bool
    var id: Int { detectedStartTs }
}

/// One night's corrections in one place: the bed and wake editor, deleting a night or a nap, the few-second
/// undo and the targeted re-score after each. The full Sleep screen and the new design's Sleep tab both
/// hold one, so a night is edited the same way from either.
@MainActor
final class SleepNightEditor: ObservableObject {
    @Published var wakeEdit: WakeEdit?
    /// Non-nil while the "Add a nap" sheet is open (#508, ryanbr/noop fork issue #49). The store and the
    /// repository have carried `addManualNap` since v4.6.0, and the time editor was written with this
    /// caller in mind — its own documentation names the "Add a nap" sheet — but no iOS screen reached it
    /// after the app returned to the tree, so a wearer could delete a nap the detector invented and had no
    /// way to add one it missed.
    @Published var addingNap: AddNapSeed?
    @Published var napPendingDelete: CachedSleepSession?
    @Published var undo: SleepUndoBanner?
    private var undoTask: Task<Void, Never>?

    /// Open the editor on `night`'s whole bridged group.
    func edit(_ night: Night) { wakeEdit = Self.wakeEdit(for: night) }

    static func wakeEdit(for night: Night) -> WakeEdit? {
        guard let target = night.editTarget, let window = SleepGroupEdit.groupWindow(night.editGroup) else { return nil }
        return WakeEdit(group: night.editGroup, detectedStartTs: target.startTs, bedTs: window.start,
                        wakeTs: window.end, userEdited: night.editGroup.contains(where: \.userEdited))
    }

    /// Show the transient UNDO banner after a suppressing delete, and arm the 7-second auto-dismiss. A
    /// second delete replaces the banner (its old auto-dismiss task is cancelled first) so only the most
    /// recent delete is undoable.
    func presentUndo(_ snapshots: [SleepDeletionSnapshot], displayStart: Int, windowEnd: Int, fromEdit: Bool) {
        guard let first = snapshots.first else { return }
        undoTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            undo = SleepUndoBanner(snapshots: snapshots, identityStart: first.session.startTs,
                                   displayStart: displayStart, windowEnd: windowEnd, fromEdit: fromEdit)
        }
        let armed = first.session.startTs
        undoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Only clear if this is still the banner we armed (a newer delete would have replaced it).
                if self?.undo?.identityStart == armed {
                    withAnimation(.easeOut(duration: 0.2)) { self?.undo = nil }
                }
            }
        }
    }

    /// Undo the most recent suppressing delete: restore and publish immediately, then repair any local
    /// derived score in the same targeted background path as save and delete.
    func undoDelete(_ banner: SleepUndoBanner, repo: Repository, appModel: AppModel?) async {
        undoTask?.cancel()
        await repo.undoDeleteSleepSessions(banner.snapshots)
        let localSnapshots = banner.snapshots.filter { $0.ownerDeviceId.hasSuffix("-noop") }
        Self.scheduleRescore(wakeDays: Set(localSnapshots.map { Repository.sleepEndDayKey($0.endTs) }),
                             required: !localSnapshots.isEmpty, repo: repo, appModel: appModel)
        withAnimation(.easeOut(duration: 0.2)) { undo = nil }
    }

    /// Deletes a wrongly detected nap: tombstoned so the next analysis does not bring it back, without
    /// hiding the day's main night, with the same few-second undo as a deleted night.
    func deleteNap(_ nap: CachedSleepSession, repo: Repository, appModel: AppModel?) async {
        guard let snapshot = await repo.deleteSleepSession(detectedStartTs: nap.startTs, endTs: nap.endTs,
                                                           suppressesWakeDay: false) else { return }
        presentUndo([snapshot], displayStart: nap.effectiveStartTs, windowEnd: nap.endTs, fromEdit: false)
        Self.scheduleRescore(wakeDays: [Repository.sleepEndDayKey(nap.endTs)],
                             required: snapshot.ownerDeviceId.hasSuffix("-noop"), repo: repo, appModel: appModel)
    }

    /// Write a hand-entered nap and re-score the day it belongs to, exactly as a delete or an edit does.
    /// `addManualNap` stages the window from the raw streams, writes it as its own `userEdited` row and
    /// never folds it into the night, so this cannot alter the main sleep.
    func addNap(startTs: Int, endTs: Int, repo: Repository, appModel: AppModel?) async {
        await repo.addManualNap(startTs: startTs, endTs: endTs)
        Self.scheduleRescore(wakeDays: [Repository.sleepEndDayKey(endTs)], required: true,
                             repo: repo, appModel: appModel)
    }

    /// A changed revision makes only the affected wake-days miss their persisted fingerprints. The pass
    /// still spans back to the oldest edited day, but `allowDayReuse` lets every unchanged day return in
    /// the cheap probe path. It never delays sheet dismissal.
    static func scheduleRescore(wakeDays: Set<String>, required: Bool, repo: Repository, appModel: AppModel?) {
        guard required, !wakeDays.isEmpty else { return }
        let today = Calendar.current.startOfDay(for: Date())
        let oldestDistance = wakeDays.compactMap(dateFromDayKey).map {
            max(0, Calendar.current.dateComponents([.day], from: $0, to: today).day ?? 0)
        }.max() ?? 0
        let maxDays = max(1, oldestDistance + 2)
        Task(priority: .utility) {
            await appModel?.intelligence.analyzeRecent(maxDays: maxDays, force: true,
                                                       allowDayReuse: true, reason: .semanticChange)
            await repo.refresh()
        }
    }

    private static func dateFromDayKey(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// One honest sentence per `SleepEditFailure`, so a correction that did not reach the database says
    /// so instead of closing the sheet as if it had worked.
    static func failureMessage(_ failure: SleepEditFailure) -> String {
        switch failure {
        case .storeUnavailable:
            return String(localized: "Couldn't open the database, so the sleep times weren't changed.")
        case .invalidWindow:
            return String(localized: "Those times aren't a valid sleep window, so nothing was changed.")
        case .noOverlap:
            return String(localized: "Those times don't overlap this night's recorded data, so nothing was changed.")
        case .ownerUnresolved:
            return String(localized: "This night's stored record couldn't be found, so the times weren't changed.")
        case .writeFailed:
            return String(localized: "Saving the new sleep times failed. Nothing was changed.")
        }
    }
}

/// The editor's sheet and the nap delete confirmation, attached to whichever screen holds the editor.
struct SleepNightEditing: ViewModifier {
    @ObservedObject var editor: SleepNightEditor
    @EnvironmentObject private var repo: Repository
    @Environment(\.dashboardAppModel) private var appModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Delete this nap?", isPresented: Binding(
                get: { editor.napPendingDelete != nil }, set: { if !$0 { editor.napPendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete nap", role: .destructive) {
                    if let nap = editor.napPendingDelete {
                        Task { await editor.deleteNap(nap, repo: repo, appModel: appModel) }
                    }
                    editor.napPendingDelete = nil
                }
                Button("Cancel", role: .cancel) { editor.napPendingDelete = nil }
            } message: {
                Text("It no longer counts toward the day's sleep, and the next analysis leaves it out.")
            }
            // Add a nap by hand (#508): the same editor, seeded on a free window instead of a recorded
            // night. No coverage range, because the chosen window deliberately sits outside the night, and
            // no delete, because there is nothing to delete yet.
            .sheet(item: $editor.addingNap) { seed in
                SleepTimeEditor(bedTs: seed.bedTs, wakeTs: seed.wakeTs,
                                napAfterNightEnd: seed.nightEndTs,
                                title: "Add a nap",
                                blurb: "Pick when the nap started and ended. NOOP stages it from your data as its own session, separate from the night's sleep.",
                                bedLabel: "Nap started", wakeLabel: "Nap ended",
                                coverage: nil,
                                onSave: { startTs, endTs, _ in
                                    await editor.addNap(startTs: startTs, endTs: endTs,
                                                        repo: repo, appModel: appModel)
                                    return .success
                                },
                                onDelete: nil)
            }
            .sheet(item: $editor.wakeEdit) { edit in
                // Validate against the WHOLE bridged night, not just its selector-winning fragment.
                // On a split night that one row often owns neither visible edge; fragment-scoped seed,
                // gate and write were why a successful correction appeared to jump straight back.
                let coverageLo = edit.group.map { min($0.startTs, $0.effectiveStartTs) }.min() ?? edit.bedTs
                let coverageHi = edit.group.map(\.endTs).max() ?? edit.wakeTs
                SleepTimeEditor(bedTs: edit.bedTs, wakeTs: edit.wakeTs,
                                coverage: coverageLo...max(coverageHi, coverageLo + 1),
                                suppressesReDetection: !edit.userEdited,
                                onSave: { newBedTs, newWakeTs, relocating in
                    let outcome = await repo.editSleepGroupTimes(edit.group,
                                                                newStartTs: newBedTs,
                                                                newEndTs: newWakeTs,
                                                                allowRelocation: relocating)
                    switch outcome {
                    case .failure(let failure):
                        return .failure(SleepNightEditor.failureMessage(failure))
                    case .success(let result):
                        CoachBriefStamp.invalidateAfterSleepCorrection(wakeTs: newWakeTs)
                        if !result.retired.isEmpty {
                            editor.presentUndo(result.retired, displayStart: newBedTs,
                                               windowEnd: newWakeTs, fromEdit: true)
                        }
                        SleepNightEditor.scheduleRescore(wakeDays: result.affectedWakeDays,
                                                         required: result.requiresLocalRescore,
                                                         repo: repo, appModel: appModel)
                        return .success
                    }
                }, onDelete: {
                    // Delete = the edit path minus the re-insert: drop this session so every metric
                    // recomputes immediately as if the night were never recorded, durably tombstoned so a
                    // re-detect doesn't bring it back, then re-score + refresh exactly like an edit. (#68)
                    // #65: the returned snapshot lets the user UNDO within a few seconds.
                    guard let snapshot = await repo.deleteSleepSession(
                        detectedStartTs: edit.detectedStartTs, endTs: edit.wakeTs) else {
                        return .failure(String(localized: "Deleting this sleep failed. Nothing was changed."))
                    }
                    CoachBriefStamp.invalidateAfterSleepCorrection(wakeTs: edit.wakeTs)
                    editor.presentUndo([snapshot], displayStart: edit.bedTs,
                                       windowEnd: edit.wakeTs, fromEdit: false)
                    SleepNightEditor.scheduleRescore(
                        wakeDays: [snapshot.suppressedWakeDay ?? Repository.sleepEndDayKey(snapshot.endTs)],
                        required: snapshot.ownerDeviceId.hasSuffix("-noop"), repo: repo, appModel: appModel)
                    return .success
                })
                #if os(iOS)
                // Two times and two buttons: a half-height sheet, pulled up only for large text.
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                #endif
            }
    }
}

extension View {
    /// The night editor's sheet and confirmations for `editor`.
    func sleepNightEditing(_ editor: SleepNightEditor) -> some View {
        modifier(SleepNightEditing(editor: editor))
    }
}

/// The transient undo strip: a Rest-tinted banner with the suppressed window and a real Undo button.
struct SleepUndoStrip: View {
    @ObservedObject var editor: SleepNightEditor
    @EnvironmentObject private var repo: Repository
    @Environment(\.dashboardAppModel) private var appModel

    var body: some View {
        if let banner = editor.undo {
            strip(banner)
        }
    }

    private func clockTime(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts))
            .formatted(Date.FormatStyle(date: .omitted, time: .shortened)
                .locale(AppClock.formattingLocale))   // #1821
    }

    private func strip(_ banner: SleepUndoBanner) -> some View {
        // Branch the copy on userEdited: a hand-edited/added night writes NO tombstone (it is never
        // re-detected), so the suppression promise would be false for it. Only a DETECTED delete writes a
        // tombstone, so only it gets the "won't detect ... again" wording. (#65 banner honesty.)
        let first = banner.snapshots[0]
        let message = banner.fromEdit
            ? String(localized: "Sleep outside the new times was removed.")
            : (first.session.userEdited
                ? String(localized: "Sleep deleted.")
                : String(localized: "Sleep deleted. NOOP won't detect sleep between \(clockTime(banner.displayStart)) and \(clockTime(banner.windowEnd)) again."))
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.restColor)
                .accessibilityHidden(true)
            Text(message)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                Task { await editor.undoDelete(banner, repo: repo, appModel: appModel) }
            } label: {
                Text("Undo").font(StrandFont.footnote.weight(.semibold))
            }
            .buttonStyle(LiquidPressStyle())
            .foregroundStyle(StrandPalette.restColor)
            .accessibilityLabel("Undo sleep deletion")
        }
        .padding(NoopMetrics.space3)
        .background(StrandPalette.restColor.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
            .strokeBorder(StrandPalette.restColor.opacity(0.22), lineWidth: 1))
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }
}
