import SwiftUI
import StrandDesign

// MARK: - Updates inbox
//
// The sheet behind the Today header's bell. A calm, newest-first log of what's new — release notes,
// "new data arrived" readings, strap heads-ups, and the Today info-cards the user swiped away (which
// can be restored from here). Tapping an actionable row routes via NavRouter; a dismissed-card row
// offers "Restore to Today". Everything is on-device and non-clinical — informational, never a verdict.
//
// Sheet idiom matches WhatsNewView: a FIXED macOS frame (a macOS sheet hosting a ScrollView collapses
// without one) and iOS presentationDetents via `noopSheetPresentation`.
struct UpdatesInboxView: View {
    @EnvironmentObject var updateStore: UpdateStore
    @EnvironmentObject var router: NavRouter
    let onClose: () -> Void

    private var unread: [UpdateItem] { updateStore.sortedItems.filter { !$0.read } }
    private var read: [UpdateItem] { updateStore.sortedItems.filter { $0.read } }

    var body: some View {
        VStack(spacing: 0) {
            header
                .background(NoopChromeSurface())
            Divider().overlay(StrandPalette.hairline)
            content
            if !updateStore.items.isEmpty {
                Divider().overlay(StrandPalette.hairline)
                footer
            }
        }
        #if os(macOS)
        // A fixed frame is mandatory — a macOS sheet hosting a ScrollView collapses to nothing without
        // one (same reason WhatsNewView pins 560×640).
        .frame(width: 460, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase)
        .onAppear { updateStore.pruneExpired() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("INBOX").font(StrandFont.overline)
                    .tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text("Updates")
                    .font(StrandFont.rounded(26, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(subtitle).font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(20)
    }

    private var subtitle: String {
        let n = updateStore.unreadCount
        if updateStore.items.isEmpty { return String(localized: "What's new in the app and your data") }
        return n == 0 ? String(localized: "All caught up") : String(localized: "\(n) unread")
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if updateStore.items.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    if !unread.isEmpty {
                        section("NEW", items: unread)
                    }
                    if !read.isEmpty {
                        section("EARLIER", items: read)
                    }
                }
                .padding(20)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
        }
    }

    private func section(_ label: LocalizedStringKey, items: [UpdateItem]) -> some View {
        // Items still awaiting a decision (`actionRequired`) lead the section — a pending session
        // suggestion shouldn't bury under a pile of informative hints. Stable sort preserves the existing
        // newest-first order within each half.
        let ordered = items.sorted { $0.actionRequired && !$1.actionRequired }
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text(label).font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textTertiary)
            ForEach(ordered) { item in
                UpdateRow(item: item, onTap: { handleTap(item) }, onRestore: { restore(item) },
                          onCloseForChange: onClose)
            }
        }
    }

    /// This layout used to be hand-built here because `ComingSoon` could only draw the compact card.
    /// It was the better of the two, so it became `ComingSoon`'s `.spacious` presentation rather than
    /// staying a second empty-state idiom sitting next to the shared one. Identical rendering; the
    /// glyph, headline and centred body are the same.
    private var emptyState: some View {
        ComingSoon(what: "New release notes and fresh data will land here.",
                   symbol: "bell.slash",
                   title: "You're all caught up.",
                   presentation: .spacious)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button {
                StrandHaptic.selection.play()
                withAnimation(StrandMotion.interactive) { updateStore.clearAll() }
            } label: {
                Label("Clear all", systemImage: "trash")
                    .font(StrandFont.subhead)
            }
            .buttonStyle(.plain)
            .foregroundStyle(StrandPalette.textSecondary)
            .disabled(updateStore.items.isEmpty)

            Spacer()

            Button {
                StrandHaptic.selection.play()
                withAnimation(StrandMotion.interactive) { updateStore.markAllRead() }
            } label: {
                Text("Mark all read").frame(minWidth: 120).padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .appleInspiredTint("updates")
            .disabled(updateStore.unreadCount == 0)
        }
        .padding(16)
    }

    // MARK: Actions

    /// Tapping a row marks it read, then routes if it carries a known deep link (else just stays open).
    private func handleTap(_ item: UpdateItem) {
        StrandHaptic.selection.play()
        withAnimation(StrandMotion.interactive) { updateStore.markRead(item.id) }
        guard let key = item.deepLink, let dest = NavRouter.Destination(deepLinkKey: key) else { return }
        // Route via the shell, then close this sheet so the destination is visible.
        router.requestedDestination = dest
        onClose()
    }

    /// Restore a dismissed Today card: flip its `@AppStorage` flag back (so it reappears), drop the
    /// inbox item, and close so the card is on screen.
    private func restore(_ item: UpdateItem) {
        StrandHaptic.selection.play()
        if let payload = item.restorePayload {
            // Clear the dismissed flag directly using the SAME key TodayView writes, so a Today that's
            // already mounted under the sheet picks the card back up immediately.
            UserDefaults.standard.set(false, forKey: TodayCardDismissal.flagKey(payload))
        }
        updateStore.requestRestore(item)
        onClose()
    }
}

// MARK: - Row

private struct UpdateRow: View {
    let item: UpdateItem
    let onTap: () -> Void
    let onRestore: () -> Void
    /// Closes the inbox sheet — used by `.actionable`'s "Change", which hands off to
    /// `MorningSuggestionCard`'s own full Change flow on Today rather than opening a second sheet
    /// (`CoachPlanView`) on top of this one, the stacked-sheet pattern this codebase already has scars
    /// from elsewhere. The proposal stays `.proposed`, so the Today card is still there once this closes.
    let onCloseForChange: () -> Void
    @ObservedObject private var planStore = CoachPlanStore.shared

    var body: some View {
        NoopCard(tint: item.read ? nil : tint) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .font(StrandFont.headline)
                        .foregroundStyle(tint)
                        .frame(width: 24)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(StrandFont.headline.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(item.message)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(relativeDate)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(.top, 1)
                    }
                    Spacer(minLength: 0)
                    if !item.read {
                        Circle().fill(StrandPalette.statusCritical)
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                            .accessibilityHidden(true)
                    }
                }
                actions
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .strandPressable()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.read ? "\(item.title). \(item.message)"
                                       : "Unread. \(item.title). \(item.message)")
    }

    /// Per-category actions — the behavioural fix: an informative hint gets no Accept/Change/Decline,
    /// only `.actionable` does.
    @ViewBuilder private var actions: some View {
        switch item.category {
        case .actionable:
            if let proposal = planStore.proposals.first(where: { $0.id == item.planProposalId }) {
                if proposal.status == .proposed {
                    HStack(spacing: 8) {
                        rowActionButton(icon: "checkmark", prominent: true) { planStore.accept(proposal.id) } label: {
                            Text("Accept")
                        }
                        rowActionButton(icon: "arrow.triangle.2.circlepath", run: onCloseForChange) {
                            Text("Change")
                        }
                        rowActionButton(icon: "xmark") { planStore.decline(proposal.id) } label: {
                            Text("Not this one")
                        }
                    }
                } else {
                    Text(decidedStatusLine(proposal.status))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        case .statusReminder:
            if item.kind == .dismissedCard {
                Button(action: onRestore) {
                    Label("Restore to Today", systemImage: "arrow.uturn.up")
                        .font(StrandFont.subhead)
                }
                .buttonStyle(.plain)
                .foregroundStyle(StrandPalette.accent)
            }
        case .informative:
            EmptyView()
        }
    }

    private func rowActionButton<L: View>(
        icon: String, prominent: Bool = false, run: @escaping () -> Void, @ViewBuilder label: () -> L
    ) -> some View {
        Button(action: run) {
            HStack(spacing: 5) {
                Image(systemName: icon).accessibilityHidden(true)
                label()
            }
            .font(StrandFont.footnote)
            .foregroundStyle(prominent ? .white : StrandPalette.textSecondary)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(prominent ? StrandPalette.accent : StrandPalette.surfaceInset,
                        in: RoundedRectangle(cornerRadius: CoachRadius.field, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func decidedStatusLine(_ status: PlanProposal.Status) -> String {
        switch status {
        case .proposed:       return String(localized: "Waiting for your decision")
        case .accepted:       return String(localized: "Accepted")
        case .declined:       return String(localized: "Declined")
        case .modifiedByUser: return String(localized: "Changed")
        case .completed:      return String(localized: "Completed")
        case .skipped:        return String(localized: "Skipped")
        case .paused:         return String(localized: "Paused")
        case .rescheduled:    return String(localized: "Rescheduled")
        }
    }

    private var symbol: String {
        switch item.category {
        case .actionable:     return "sparkles"
        case .informative:
            if item.kind == .newVersion { return "arrow.down.circle" }
            return item.kind == .whatsNew ? "sparkles" : "waveform.path.ecg"
        case .statusReminder:
            return item.kind == .dismissedCard ? "rectangle.on.rectangle" : "bell.badge.fill"
        }
    }

    /// A per-category tint so each row reads in its own colour world; `.informative` additionally leans
    /// on `priority` since a high-priority hint (e.g. a body-concern signal) should read differently from
    /// a release note.
    private var tint: Color {
        switch item.category {
        case .actionable:     return StrandPalette.chargeColor
        case .informative:    return item.priority == .high ? StrandPalette.statusWarning : StrandPalette.accent
        case .statusReminder: return StrandPalette.textSecondary
        }
    }

    private var relativeDate: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: item.date, relativeTo: Date())
    }
}

// MARK: - Today card dismissal keys (shared)
//
// The Today info-cards persist their dismissed state in `@AppStorage` under a stable per-card key. The
// inbox restores a card by clearing that same key, so the key shape lives in ONE place both sides use.
enum TodayCardDismissal {
    /// The `@AppStorage` bool key for a Today info-card's dismissed flag, by stable card id.
    static func flagKey(_ cardID: String) -> String { "noop.todayCard.\(cardID).dismissed" }
}
