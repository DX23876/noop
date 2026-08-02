import SwiftUI
import StrandDesign

/// Native journal logging, yes/no chips and numeric fields for the merged behaviour catalog plus a
/// custom-question field, hosted at the top of Insights. Answers write under
/// `Repository.journalDeviceId` ("noop-journal"), NEVER the imported source, so a CSV re-import can't
/// clobber them and clearing is safe (imported rows are never touched). Tri-state: tapping the selected
/// chip again clears the answer. Day attribution follows the importer's wake-day convention, answers
/// describe the night and day leading into the selected morning, so logged days line up with imported
/// history.
///
/// v2 (#322): items sit under collapsible groups (Nutrition / Supplements / …); an item can be a
/// numeric value (with a unit) instead of a toggle; and custom items can be renamed / regrouped /
/// converted / reordered in edit mode. The stored KEY (`canonical`) never changes on a rename, so all
/// history, logged and imported, stays joined under the original question.
/// `.task(id:)` key for the card's day read: which pill is selected, plus the host's live "today", so a
/// midnight rollover under an open screen re-reads too.
private struct JournalDayKey: Equatable {
    let offset: Int
    let anchor: String
}

struct JournalLogCard: View {
    @EnvironmentObject var repo: Repository
    /// Only for the duplicate review, which is a Coach feature end to end. Injected at both app roots
    /// (`StrandApp` / `StrandiOSApp`), so this resolves wherever the card is hosted.
    @EnvironmentObject var coach: AICoachEngine
    /// The journal catalog is single-user state owned here (UserDefaults-backed), so hosting the card
    /// needs no app-level injection.
    @StateObject private var catalog = JournalCatalogStore()

    /// Distinct imported question strings (from InsightsView's load), adopted into the catalog so
    /// logged answers and imported history group under the same behaviour. Arrives late (it needs the
    /// host's history read) — until then the catalog's own starters and custom items carry the card.
    let importedQuestions: [String]
    /// #860 item 4: the host's live "today" key. The pills are relative to the current date, so when the
    /// calendar day rolls over under a screen that stayed open, this changes and the day below is re-read
    /// — otherwise yesterday's answers would sit under a pill that now says "Today".
    let dayAnchor: String
    @Binding var dayOffset: Int            // -1 = tomorrow, 0 = today, 1 = yesterday
    /// "The journal history changed" — the host refreshes its derived analysis when it suits it. NOT a
    /// request to reload this card: the answers below are this card's own.
    let onChanged: () -> Void

    init(importedQuestions: [String], dayAnchor: String, dayOffset: Binding<Int>,
         onChanged: @escaping () -> Void) {
        self.importedQuestions = importedQuestions
        self.dayAnchor = dayAnchor
        self._dayOffset = dayOffset
        self.onChanged = onChanged
    }

    /// The selected day's answers, owned HERE.
    ///
    /// They used to be `let`s from InsightsView's `@State`, which made every chip tap a state change on
    /// the host — and re-evaluating that host means its whole body: the experiment snapshot, the ranked
    /// effects, the correlations, every card on the screen. The card only ever needs one day of native
    /// rows, and both reads are single-day and index-backed (`journal` is keyed by
    /// (deviceId, day, question)), so it reads them itself. A tap now repaints this card and nothing
    /// else, and the card no longer waits for the host's full history load to render at all.
    @State private var answers: [String: Bool] = [:]
    @State private var numericAnswers: [String: Double] = [:]

    /// The resolved catalog, bucketed by group — memoized.
    ///
    /// `resolvedItems` merges the imported questions with the saved catalog and the starters and sorts
    /// the result; computing it in `body` meant redoing that merge on every chip tap, when its inputs
    /// (the imported set, the catalog itself, and edit mode) had not moved at all. Refreshed by
    /// `refreshGrouped()` exactly when one of them does.
    @State private var grouped: [JournalGroup: [JournalCatalogItem]] = [:]

    /// Merge candidates for the review sheet, and the per-wording answer counts behind them.
    @State private var duplicateCandidates: [JournalMerge.Candidate] = []
    @State private var duplicateCounts: [String: Int] = [:]
    @State private var showingDuplicates = false
    /// Where the review stands. The scan is one request to the user's own provider, so the sheet says
    /// which of these it is instead of leaving an empty list to be read as "nothing found".
    @State private var duplicateScan: DuplicateScanState = .idle
    /// The survivor the user picked per group, overriding the model's `KEEP`.
    @State private var duplicateTargets: [String: String] = [:]
    /// Pairs the user has waved away, newline-joined so the list stops proposing them every time.
    @AppStorage("journal.dismissedDuplicatePairs") private var dismissedPairsRaw = ""
    private var dismissedPairs: Set<String> {
        Set(dismissedPairsRaw.split(separator: "\n").map(String.init))
    }
    /// The catalog the last reply was bought for, and the reply itself. Re-opening an unchanged list
    /// re-derives the groups from this instead of spending a second request; the derivation is pure, so
    /// dismissals and answer counts still apply freshly.
    @AppStorage("journal.duplicateScanFingerprint") private var duplicateScanFingerprint = ""
    @AppStorage("journal.duplicateScanReply") private var duplicateScanReply = ""

    enum DuplicateScanState: Equatable {
        case idle
        case running
        case done
        /// The request produced no usable answer — no key, no network, or nothing parseable.
        case failed
    }

    @State private var customDraft = ""
    @State private var customIsNumeric = false
    @State private var customGroup: JournalGroup = .other
    /// Edit mode: swaps the answer controls for rename/group/convert/remove and reveals hidden items.
    @State private var editing = false
    /// Collapsed groups (persisted per group).
    @AppStorage("journal.collapsedGroups") private var collapsedGroupsRaw = ""
    /// The item being renamed (drives the rename sheet).
    @State private var renaming: JournalCatalogItem?
    @State private var renameDraft = ""

    private var dayKey: String {
        Repository.localDayKey(
            Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date())
    }

    /// The resolved catalog bucketed by group, each group ordered by sortIndex then display.
    ///
    /// One pass, not six: `resolvedItems` merges the imported questions with the saved catalog and the
    /// starters, and the old `items(in:)` re-ran that whole merge for every one of the six groups on
    /// every render. Same items, same order — see `JournalLogicTests`.
    static func itemsByGroup(_ resolved: [JournalCatalogItem]) -> [JournalGroup: [JournalCatalogItem]] {
        Dictionary(grouping: resolved, by: \.group)
            .mapValues { $0.sorted { ($0.sortIndex, $0.display) < ($1.sortIndex, $1.display) } }
    }

    private var collapsedGroups: Set<String> {
        Set(collapsedGroupsRaw.split(separator: ",").map(String.init))
    }

    private func toggleCollapsed(_ group: JournalGroup) {
        var set = collapsedGroups
        if set.contains(group.rawValue) { set.remove(group.rawValue) } else { set.insert(group.rawValue) }
        collapsedGroupsRaw = set.sorted().joined(separator: ",")
    }

    var body: some View {
        let collapsed = collapsedGroups
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            HStack(alignment: .center) {
                SectionHeader("Journal", overline: "Log")
                Spacer()
                if editing {
                    pillButton("Done", selected: true) { editing = false }
                } else {
                    pillButton("Edit", selected: false) { editing = true }
                }
            }
            // Day picker (#656): a bounded, scrollable range — Tomorrow back through the last 7 days — so
            // any recent day can be backfilled (was Yesterday/Today/Tomorrow only). Chronological
            // left→right; snaps to the selected day, so a deep-link from the Today journal widget lands on
            // that day's pill. Only when not editing.
            if !editing {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Self.journalDayOffsets, id: \.self) { off in
                                dayPill(journalDayLabel(off), offset: off).id(off)
                            }
                        }
                        .padding(.horizontal, 1)   // don't clip the selected pill's ring
                    }
                    // Defer the initial scroll a tick: scrollTo in onAppear can no-op before the pills lay
                    // out, which would leave the picker on the oldest day instead of the selected one.
                    .onAppear { DispatchQueue.main.async { proxy.scrollTo(dayOffset, anchor: .center) } }
                    // onChangeCompat, not onChange: the zero/two-arg onChange is macOS 14+, and this card
                    // is shared with the macOS 13 target.
                    .onChangeCompat(of: dayOffset) { _ in proxy.scrollTo(dayOffset, anchor: .center) }
                }
            }
            NoopCard(tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(editing
                         ? "Rename, regroup, or remove an item to tidy your list. Renaming keeps the original question behind the scenes, so a WHOOP import still lines up. Custom items are deleted; built-in ones are hidden and can be restored below."
                         : dayOffset == -1
                         ? "Logging ahead for tomorrow: today's activities inform tomorrow's recovery, just as yesterday's are reflected in today's. Tomorrow's answers line up with tomorrow's morning."
                         : "Answers are about the night and day leading into this morning, the same attribution a WHOOP export uses, so logged and imported days line up.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if editing, duplicateReviewAvailable {
                        duplicatesRow
                    }

                    ForEach(JournalGroup.displayOrder, id: \.self) { group in
                        groupBlock(group, items: grouped[group] ?? [],
                                   collapsed: collapsed.contains(group.rawValue))
                    }

                    Divider().overlay(StrandPalette.hairline)
                    addRow
                }
            }
        }
        .sheet(item: $renaming) { item in renameSheet(item) }
        .sheet(isPresented: $showingDuplicates) { duplicatesSheet }
        // The selected day's answers, re-read on arrival, on a pill switch, and on a calendar-day
        // rollover. Two single-day queries — nothing here depends on the host's history load.
        .task(id: JournalDayKey(offset: dayOffset, anchor: dayAnchor)) { await loadDay() }
        // The catalog memo's inputs, and only those: the host's imported questions (they arrive after
        // its history read), edit mode (it reveals hidden items), and the catalog's own contents
        // (rename / regroup / retype / add / remove / restore all write `items`).
        .onAppear { refreshGrouped() }
        .onChangeCompat(of: importedQuestions) { _ in refreshGrouped() }
        .onChangeCompat(of: editing) { _ in refreshGrouped() }
        .onChangeCompat(of: catalog.items) { _ in refreshGrouped() }
    }

    private func refreshGrouped() {
        grouped = Self.itemsByGroup(catalog.resolvedItems(imported: importedQuestions,
                                                          includeHidden: editing))
    }

    // MARK: - Duplicate questions (WHOOP re-wordings)

    /// The review exists only with the Coach on and configured, because the Coach's cheap model IS the
    /// detection — see `JournalDuplicateReviewer`. Without it there is no row, no sheet and no greyed
    /// affordance: the edit menu looks exactly as it did before this feature, rather than advertising
    /// something the user cannot reach from here.
    private var duplicateReviewAvailable: Bool {
        CoachFeaturePrefs.isEnabled && coach.isConfigured
    }

    /// The row that opens the review. It can no longer promise a count — nothing has been compared
    /// yet — so it names the action, and tapping it is what authorises the one request.
    private var duplicatesRow: some View {
        Button { showingDuplicates = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.merge")
                    .font(StrandFont.body)
                    .appleInspiredForeground("journal")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Find duplicate questions")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("A WHOOP export can carry several wordings for the same habit, which splits its history. Your coach model compares the wordings — no answers or dates are sent.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }

    /// Load the review: one request to the cheap model, or none at all when the catalog has not moved
    /// since the last one.
    ///
    /// `force` is the explicit re-scan, the only path that spends a second request on an unchanged
    /// list — the user asking again is the one reason to distrust the cached answer.
    private func loadDuplicates(force: Bool = false) async {
        guard duplicateReviewAvailable else { duplicateCandidates = []; return }
        let counts = await repo.journalQuestionCounts()
        let list = AICoachEngine.journalQuestionList(
            catalog.resolvedItems(imported: importedQuestions).map(\.canonical))
        duplicateCounts = counts

        let fingerprint = AICoachEngine.journalCatalogFingerprint(list)
        // With fewer than two visible questions there is nothing to compare. This is a successful
        // local result, not a provider failure, and must never spend an API request.
        if list.count < 2 {
            duplicateCandidates = []
            duplicateTargets = [:]
            duplicateScanReply = ""
            duplicateScanFingerprint = fingerprint
            duplicateScan = .done
            return
        }
        if !force, fingerprint == duplicateScanFingerprint {
            if applyDuplicateReply(duplicateScanReply, list: list, counts: counts) { return }
            // A development build may have cached an answer before invalid replies were distinguished.
            // Forget it and make one clean request rather than pinning the review to a false empty state.
            duplicateScanFingerprint = ""
            duplicateScanReply = ""
        }

        duplicateCandidates = []
        duplicateScan = .running
        guard let reply = await coach.journalDuplicateReply(for: list) else {
            duplicateScan = .failed
            return
        }
        guard applyDuplicateReply(reply, list: list, counts: counts) else { return }
        duplicateScanReply = reply
        duplicateScanFingerprint = fingerprint
    }

    /// Derive the groups from a reply — the pure half, so it also runs on the cached reply and picks up
    /// dismissals and answer counts as they are now.
    @discardableResult
    private func applyDuplicateReply(_ reply: String, list: [String], counts: [String: Int]) -> Bool {
        switch AICoachEngine.journalDuplicateReview(from: reply,
                                                    questions: list,
                                                    counts: counts,
                                                    dismissed: dismissedPairs) {
        case let .candidates(candidates):
            duplicateCandidates = candidates
        case .noDuplicates:
            duplicateCandidates = []
        case .invalid:
            duplicateCandidates = []
            duplicateScan = .failed
            return false
        }
        duplicateTargets = duplicateTargets.filter { id, _ in
            duplicateCandidates.contains { $0.id == id }
        }
        duplicateScan = .done
        return true
    }

    /// The survivor for a group: the user's pick if they made one, otherwise the model's `KEEP`.
    private func target(for candidate: JournalMerge.Candidate) -> String {
        duplicateTargets[candidate.id].flatMap { candidate.questions.contains($0) ? $0 : nil }
            ?? candidate.suggestedTarget
    }

    private func applyMerge(_ candidate: JournalMerge.Candidate, target: String) {
        for question in candidate.questions where question != target {
            catalog.merge(question, into: target)
        }
        // Settled — drop the group locally. Acting on a group CHANGES the catalog, so re-running the
        // scan here would miss the cache and buy a second reply to answer what the user just answered.
        duplicateCandidates.removeAll { $0.id == candidate.id }
        duplicateTargets[candidate.id] = nil
        finishDuplicateAction()
    }

    /// What every catalog change here shares: the shown day re-reads through the new catalog, the
    /// answer counts catch up, and the host re-ranks its analysis on the changed history. No new
    /// request — the groups were adjusted in place above.
    private func finishDuplicateAction() {
        repo.journalAliasesChanged()
        refreshGrouped()
        Task {
            await loadDay()
            duplicateCounts = await repo.journalQuestionCounts()
            onChanged()
        }
    }

    private var duplicatesSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                    Text("Your coach model read the question wordings and grouped the ones it takes for the same habit. Merging joins their history so an effect is ranked on all of it, and never deletes an answer — separate them again at any time. Check each group before merging.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(duplicateCandidates) { candidate in
                        candidateCard(candidate)
                    }

                    switch duplicateScan {
                    case .running:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Comparing your questions…")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                    case .failed:
                        // Named, not silent: an empty list here would read as "nothing found", which is
                        // the one thing this state does NOT mean.
                        Text("The coach model could not be reached, so nothing was compared. Check the connection or your provider in Coach settings, then try again.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .done where duplicateCandidates.isEmpty:
                        Text("Nothing left to review.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    case .idle, .done:
                        EmptyView()
                    }
                }
                .padding(NoopMetrics.space4)
            }
            .navigationTitle("Duplicate questions")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingDuplicates = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Check again") { Task { await loadDuplicates(force: true) } }
                        .disabled(duplicateScan == .running)
                }
            }
            .task { await loadDuplicates() }
        }
    }

    private func candidateCard(_ candidate: JournalMerge.Candidate) -> some View {
        let kept = target(for: candidate)
        return NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(candidate.questions, id: \.self) { question in
                    candidateRow(question, in: candidate, kept: kept)
                }
                // Which history moves is named, not implied — and it is now a choice, so say that too.
                Text("Keeps: \(kept). Tap another wording to keep that one instead.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Merge") { applyMerge(candidate, target: kept) }
                        .buttonStyle(.borderedProminent)
                    Button("Not the same") { dismiss(candidate) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    /// One wording in a group: tap to make it the survivor. Removing or hiding questions remains in
    /// the ordinary edit controls, separate from the focused merge / reject decision here.
    private func candidateRow(_ question: String,
                              in candidate: JournalMerge.Candidate,
                              kept: String) -> some View {
        let isKept = question == kept
        return Button {
            duplicateTargets[candidate.id] = question
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isKept ? "largecircle.fill.circle" : "circle")
                    .font(StrandFont.footnote)
                    .foregroundStyle(isKept ? StrandPalette.accent : StrandPalette.textTertiary)
                Text(verbatim: question)      // data, not a UI literal
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text("\(duplicateCounts[question] ?? 0)")
                    .font(StrandFont.number(13))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityLabel("\(duplicateCounts[question] ?? 0) answers")
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isKept ? [.isSelected] : [])
    }

    /// Undo one merge. The rows were never touched, so this is the same three steps as a merge — the
    /// question simply reads as itself again.
    private func unmerge(_ alias: String) {
        catalog.unmerge(alias)
        finishDuplicateAction()
    }

    private func dismiss(_ candidate: JournalMerge.Candidate) {
        var pairs = dismissedPairs
        for (i, a) in candidate.questions.enumerated() {
            for b in candidate.questions.dropFirst(i + 1) { pairs.insert(JournalMerge.pairKey(a, b)) }
        }
        dismissedPairsRaw = pairs.sorted().joined(separator: "\n")
        // Gone from view now, and gone from the next derivation too: the dismissal is applied to the
        // cached reply, so re-opening does not put the same rejected group back.
        duplicateCandidates.removeAll { $0.id == candidate.id }
        duplicateTargets[candidate.id] = nil
    }

    // MARK: - The selected day

    private func loadDay() async {
        let key = dayKey
        let a = await repo.nativeJournalAnswers(day: key)
        let n = await repo.nativeJournalNumeric(day: key)
        // The day may have moved on while those were in flight (a fast pill tap); only the read that
        // still matches the shown day may paint.
        guard key == dayKey else { return }
        answers = a
        numericAnswers = n
    }

    // MARK: - Group block

    @ViewBuilder private func groupBlock(_ group: JournalGroup,
                                         items groupItems: [JournalCatalogItem],
                                         collapsed: Bool) -> some View {
        // Empty groups hidden outside edit mode; in edit mode all six show so items can be moved in.
        if !groupItems.isEmpty || editing {
            VStack(alignment: .leading, spacing: 8) {
                Button { toggleCollapsed(group) } label: {
                    HStack(spacing: 6) {
                        Text(group.title.uppercased())
                            .font(StrandFont.overline)
                            .tracking(StrandFont.overlineTracking)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text("\(groupItems.count)")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Spacer()
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(group.title), \(groupItems.count) items, \(collapsed ? "collapsed" : "expanded")")

                if !collapsed {
                    ForEach(groupItems) { item in itemRow(item) }
                }
            }
        }
    }

    // MARK: - Item row

    @ViewBuilder private func itemRow(_ item: JournalCatalogItem) -> some View {
        HStack {
            Text(verbatim: item.display)   // display = rename ?? canonical; data, not a UI literal
                .font(StrandFont.body)
                .foregroundStyle(item.hidden ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            Spacer()
            if editing {
                editControls(item)
            } else if item.kind.isNumeric {
                numericField(item)
            } else {
                answerPill("Yes", q: item.canonical, value: true)
                answerPill("No", q: item.canonical, value: false)
            }
        }
    }

    // MARK: - Numeric field

    private func numericField(_ item: JournalCatalogItem) -> some View {
        let current = numericAnswers[item.canonical]
        return HStack(spacing: 6) {
            stepperButton("minus", q: item.canonical, current: current)
            NumericLogField(
                value: current,
                placeholder: "—",
                onCommit: { v in commitNumeric(item.canonical, value: v) })
            .frame(width: 64)
            if let unit = item.kind.unitLabel, !unit.isEmpty {
                Text(verbatim: unit)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            stepperButton("plus", q: item.canonical, current: current)
            if current != nil {
                Button {
                    let day = dayKey
                    numericAnswers[item.canonical] = nil
                    answers[item.canonical] = nil     // a numeric log also carries answeredYes
                    Task { await repo.clearJournalAnswer(day: day, question: item.canonical); onChanged() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear \(item.display)")
            }
        }
    }

    private func stepperButton(_ symbol: String, q: String, current: Double?) -> some View {
        Button {
            let base = current ?? 0
            let next = max(0, symbol == "plus" ? base + 1 : base - 1)
            commitNumeric(q, value: next)
        } label: {
            Image(systemName: "\(symbol).circle")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "plus" ? "Increase" : "Decrease")
    }

    private func commitNumeric(_ q: String, value: Double) {
        let day = dayKey
        numericAnswers[q] = value
        answers[q] = true            // #322: a numeric log stores answeredYes = true alongside the value
        Task {
            await repo.saveJournalNumeric(day: day, question: q, value: value)
            onChanged()
        }
    }

    // MARK: - Edit-mode controls

    private func editControls(_ item: JournalCatalogItem) -> some View {
        HStack(spacing: 10) {
            if item.hidden {
                pillButton("Restore", selected: false) { catalog.restore(item.canonical) }
            } else {
                Menu {
                    Button("Rename…") { startRename(item) }
                    Menu("Group") {
                        ForEach(JournalGroup.displayOrder, id: \.self) { g in
                            Button(g.title) { catalog.setGroup(item.canonical, to: g) }
                        }
                    }
                    if item.kind.isNumeric {
                        Button("Change to Yes/No") { catalog.setKind(item.canonical, to: .bool) }
                    } else {
                        Button("Change to Number") { catalog.setKind(item.canonical, to: .numeric(unitLabel: nil)) }
                    }
                    // Every merge is undoable from the question it was merged into, and the wordings
                    // are named verbatim so it is obvious which history comes back out.
                    if !item.aliases.isEmpty {
                        Menu("Separate") {
                            ForEach(item.aliases, id: \.self) { alias in
                                Button { unmerge(alias) } label: { Text(verbatim: alias) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Edit \(item.display)")

                removeButton(item)
            }
        }
    }

    /// Edit-mode control: delete a custom question / hide a built-in one. Tinted red to read as removal.
    private func removeButton(_ item: JournalCatalogItem) -> some View {
        Button { catalog.remove(item.canonical) } label: {
            Image(systemName: "minus.circle.fill")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.statusCritical)
        }
        .buttonStyle(.plain)
        .help(item.custom ? "Delete this custom item" : "Hide this item")
        .accessibilityLabel(item.custom ? "Delete \(item.display)" : "Hide \(item.display)")
    }

    // MARK: - Rename sheet

    private func startRename(_ item: JournalCatalogItem) {
        renameDraft = item.displayName ?? item.canonical
        renaming = item
    }

    private func renameSheet(_ item: JournalCatalogItem) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text("Rename item").font(StrandFont.headline)
            TextField("Display name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
            Text("History stays under the original question so WHOOP imports still line up.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { renaming = nil }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") {
                    catalog.rename(item.canonical, to: renameDraft)
                    renaming = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(NoopMetrics.space4)
        .frame(minWidth: 320)
    }

    // MARK: - Add row

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Add a custom item…", text: $customDraft)
                    .textFieldStyle(.roundedBorder)
                pillButton(customIsNumeric ? "Number" : "Yes/No", selected: customIsNumeric) {
                    customIsNumeric.toggle()
                }
                Button("Add") {
                    let t = customDraft.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return }
                    catalog.addCustom(t,
                                      kind: customIsNumeric ? .numeric(unitLabel: nil) : .bool,
                                      group: customGroup)
                    customDraft = ""
                }
                .buttonStyle(.bordered)
                .disabled(customDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Picker("Group", selection: $customGroup) {
                ForEach(JournalGroup.displayOrder, id: \.self) { g in
                    Text(g.title).tag(g)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel("New item group")
        }
    }

    // MARK: - Controls

    private func dayPill(_ label: LocalizedStringKey, offset: Int) -> some View {
        // The host observes `dayOffset` and re-reads that day's answers itself, so this does NOT call
        // `onChanged` — that callback means "an answer was written", and firing it here would also
        // schedule the host's derived reload for a switch that changes no history at all.
        pillButton(label, selected: dayOffset == offset) { dayOffset = offset }
    }

    /// The bounded day-picker range (#656): Tomorrow (-1) plus today and the 6 prior days, chronological
    /// oldest → newest left-to-right. Bounded on purpose — journal answers feed the correlation engine, so
    /// unbounded backfill of stale days would distort it (matches WHOOP's limited retroactive window).
    private static let journalDayOffsets: [Int] = Array((-1...6).reversed())

    /// Short pill label for a day-picker offset (daysBack; -1 = Tomorrow). "%lld days ago" is a String
    /// Catalog key, so 2–6 stay localized just like the twin "%lld nights ago" (#527/#656).
    private func journalDayLabel(_ offset: Int) -> LocalizedStringKey {
        switch offset {
        case -1: return "Tomorrow"
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(offset) days ago"
        }
    }

    private func answerPill(_ label: LocalizedStringKey, q: String, value: Bool) -> some View {
        let selected = answers[q] == value
        return pillButton(label, selected: selected) {
            // Paint first, write second: the state this chip draws from is right here, so the tap can
            // never look ignored while the write is in flight.
            let day = dayKey
            if selected { answers[q] = nil } else { answers[q] = value }
            Task {
                // Tri-state: re-tapping the filled chip clears the answer (natural-key delete,
                // scoped to "noop-journal", imported rows can never be removed this way).
                if selected {
                    await repo.clearJournalAnswer(day: day, question: q)
                } else {
                    await repo.saveJournalAnswer(day: day, question: q, answeredYes: value)
                }
                onChanged()
            }
        }
    }

    private func pillButton(_ label: LocalizedStringKey, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(selected ? StrandPalette.restColor : StrandPalette.surfaceInset,
                            in: Capsule())
                .overlay(Capsule().stroke(selected ? StrandPalette.restColor : StrandPalette.hairline,
                                          lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A compact numeric log field: shows the current value or a ghost placeholder, commits a Double on
/// return / focus-out. Kept small so the numeric row reads like the yes/no pills.
private struct NumericLogField: View {
    let value: Double?
    let placeholder: String
    let onCommit: (Double) -> Void

    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .font(StrandFont.number(15))
            .onAppear { text = value.map(Self.format) ?? "" }
            .onChangeCompat(of: value) { v in text = v.map(Self.format) ?? "" }
            .onSubmit { commit() }
        #if os(iOS)
            .keyboardType(.decimalPad)
        #endif
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
        if let v = Double(cleaned) { onCommit(v) }
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }
}
