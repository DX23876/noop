import SwiftUI
import StrandDesign

// MARK: - "Customise" dashboard editor (WHOOP "My Dashboard" ✎)
//
// A Today-local sheet (no new nav destination) for choosing WHICH "Your cards" dashboard cards show and in
// what order. Display-only: it edits the persisted `today.dashboardCards` selection string, never any
// stored metric. Enabled cards render in the list's order; a toggle hides/shows a card and a drag handle
// (List .onMove under EditMode) reorders it — the WHOOP "My Dashboard" customise flow.
//
// The enabled cards come first in their saved order, then the disabled remainder in canonical order, so
// toggling one on drops it at the end of the visible set and the editor always lists every card exactly
// once. Persists on every change via the bound @AppStorage so an edit takes effect live and survives
// relaunch.

struct DashboardCardsEditorSheet: View {
    /// The persisted selection string (JSON array of enabled `DashboardCard` ids, in order). Bound straight
    /// to the Today screen's @AppStorage so an edit takes effect live and survives relaunch.
    @Binding var selectionRaw: String

    @Environment(\.dismiss) private var dismiss

    /// Working copy: the full ordered list with an enabled flag per card.
    @State private var items: [Item]
    #if os(iOS)
    /// Drag-to-reorder mode for the List (.onMove only fires under .active EditMode on iOS). macOS Lists
    /// drag-reorder without an explicit EditMode, so this is iOS-only.
    @State private var editMode: EditMode = .active
    #endif

    private struct Item: Identifiable, Equatable {
        let card: DashboardCard
        var enabled: Bool
        var id: String { card.rawValue }
    }

    init(selectionRaw: Binding<String>) {
        _selectionRaw = selectionRaw
        let enabled = DashboardCardPrefs.decodeEnabled(selectionRaw.wrappedValue)
        let enabledSet = Set(enabled)
        // Enabled cards first (saved order), then the rest in the canonical order.
        var working = enabled.map { Item(card: $0, enabled: true) }
        for c in DashboardCard.canonicalOrder where !enabledSet.contains(c) {
            working.append(Item(card: c, enabled: false))
        }
        _items = State(initialValue: working)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach($items) { $item in
                        row($item)
                    }
                    .onMove(perform: move)
                } header: {
                    Text("Show & reorder")
                        .strandOverline()
                } footer: {
                    Text("Drag to reorder. Toggle a card on or off. Cards with no value yet show a dash.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .listRowBackground(StrandPalette.surfaceRaised)
            }
            .scrollContentBackground(.hidden)
            .background(StrandPalette.surfaceBase)
            #if os(iOS)
            .environment(\.editMode, $editMode)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("My Dashboard")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { resetToDefault() }
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityLabel("Reset dashboard cards to default")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commit(); dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(StrandPalette.accent)
                        // At least one card must stay visible — an empty dashboard reads as a bug.
                        .disabled(!items.contains { $0.enabled })
                        .accessibilityLabel("Done customising dashboard")
                }
            }
            // Persist on EVERY change (toggle / reorder / reset), not only on Done — so closing the sheet by
            // swipe still keeps the edit, mirroring WHOOP's live "My Dashboard" customise. Done just dismisses.
            .onChange(of: items) { _ in commit() }
        }
        .appleInspiredTint("settings.controls")
        #if os(macOS)
        // macOS sheets don't auto-size to content the way iOS does — give it a usable frame.
        .frame(width: 420, height: 540)
        #endif
    }

    // MARK: Row

    @ViewBuilder
    private func row(_ item: Binding<Item>) -> some View {
        let card = item.wrappedValue.card
        let enabled = item.wrappedValue.enabled
        HStack(spacing: 12) {
            // The card's own thin-line icon, flat WHOOP styling — accent when on, grey when off.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill((enabled ? StrandPalette.accent : StrandPalette.textTertiary).opacity(0.14))
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: card.icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(enabled ? StrandPalette.accent : StrandPalette.textTertiary)
                )
                .accessibilityHidden(true)

            Toggle(isOn: item.enabled) {
                Text(card.title.uppercased())
                    .font(StrandFont.subhead.weight(.semibold))
                    .tracking(0.4)
                    .foregroundStyle(enabled ? StrandPalette.textPrimary : StrandPalette.textTertiary)
            }
            .toggleStyle(.switch)
            .appleInspiredTint("settings.controls")
            .accessibilityLabel("Show \(card.title)")
        }
    }

    // MARK: Mutations

    /// Reorder under EditMode. Cards stay in one list; a card can be dragged anywhere. The enabled/disabled
    /// split is recomputed at commit time from the flags, so dragging a disabled card among enabled ones is
    /// harmless (it only matters once it's toggled on).
    private func move(from: IndexSet, to: Int) {
        items.move(fromOffsets: from, toOffset: to)
    }

    private func resetToDefault() {
        let enabledSet = Set(DashboardCard.defaultSelection)
        var working = DashboardCard.defaultSelection.map { Item(card: $0, enabled: true) }
        for c in DashboardCard.canonicalOrder where !enabledSet.contains(c) {
            working.append(Item(card: c, enabled: false))
        }
        items = working
    }

    /// Persist the enabled cards in their current order. Disabled cards are omitted from the stored string;
    /// `DashboardCardPrefs.decodeEnabled` rebuilds the editor's disabled remainder from the canonical order
    /// on next open, so nothing is lost.
    private func commit() {
        selectionRaw = DashboardCardPrefs.encode(items.filter { $0.enabled }.map(\.card))
    }
}

#if DEBUG
#Preview("Dashboard editor") {
    DashboardCardsEditorSheet(selectionRaw: .constant(""))
        .preferredColorScheme(.dark)
}
#endif
