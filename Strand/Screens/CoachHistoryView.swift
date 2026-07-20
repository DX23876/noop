import SwiftUI
import StrandDesign

/// The conversation history: every saved Coach chat as its own findable thread. Tap to switch, swipe
/// (or long-press) to rename or delete. Presented as a sheet from the chat header's history button.
struct CoachHistoryView: View {
    @EnvironmentObject var coach: AICoachEngine
    @Environment(\.dismiss) private var dismiss

    /// Called after the user picks (switches to) a conversation, so the chat can dismiss this sheet.
    var onPick: () -> Void = {}

    @State private var renamingID: UUID?
    @State private var renameText: String = ""

    var body: some View {
        NavigationStack {
            Group {
                if coach.conversations.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("Conversations")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        coach.newConversation()
                        onPick()
                    } label: {
                        Label("New chat", systemImage: "square.and.pencil")
                    }
                    .accessibilityLabel("New chat")
                }
            }
            .alert("Rename conversation", isPresented: renameBinding) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) { renamingID = nil }
                Button("Save") {
                    if let id = renamingID { coach.renameConversation(id, to: renameText) }
                    renamingID = nil
                }
            }
        }
    }

    /// Live threads, most-recent-first (the sweep and manual archiving keep these out of the way).
    private var activeConversations: [CoachConversation] { coach.conversations.filter { !$0.archived } }
    /// Auto-archived threads — past daily briefs the user never replied to, plus anything archived by hand.
    private var archivedConversations: [CoachConversation] { coach.conversations.filter { $0.archived } }

    private var list: some View {
        List {
            ForEach(activeConversations) { convo in
                conversationRow(convo)
            }
            if !archivedConversations.isEmpty {
                Section {
                    ForEach(archivedConversations) { convo in
                        conversationRow(convo)
                    }
                } header: {
                    Text("Archived")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .listStyle(.plain)
    }

    private func conversationRow(_ convo: CoachConversation) -> some View {
        Button { coach.switchTo(convo.id); onPick() } label: { row(convo) }
            .buttonStyle(.plain)
            .listRowBackground(StrandPalette.surfaceBase)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) { coach.deleteConversation(convo.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
                if convo.archived {
                    Button { coach.setArchived(convo.id, false) } label: {
                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                    }
                    .tint(StrandPalette.accent)
                } else {
                    Button { coach.setArchived(convo.id, true) } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                    .tint(StrandPalette.textSecondary)
                }
                Button { beginRename(convo) } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .tint(StrandPalette.accent)
            }
            .contextMenu {
                Button { beginRename(convo) } label: { Label("Rename", systemImage: "pencil") }
                if convo.archived {
                    Button { coach.setArchived(convo.id, false) } label: {
                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                    }
                } else {
                    Button { coach.setArchived(convo.id, true) } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                }
                Button(role: .destructive) { coach.deleteConversation(convo.id) } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }

    private func row(_ convo: CoachConversation) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(convo.title.isEmpty ? String(localized: "New chat") : convo.title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(preview(convo))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if convo.id == coach.activeConversationID {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityLabel("Current conversation")
                }
                Text(convo.updatedAt.formatted(.relative(presentation: .named)))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func preview(_ convo: CoachConversation) -> String {
        if let last = convo.messages.last(where: { !$0.text.isEmpty }) {
            return last.text.replacingOccurrences(of: "\n", with: " ")
        }
        return String(localized: "No messages yet")
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32))
                .foregroundStyle(StrandPalette.textTertiary)
            Text("No conversations yet")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func beginRename(_ convo: CoachConversation) {
        renameText = convo.title
        renamingID = convo.id
    }

    /// Drives the rename alert's presentation from `renamingID` without a second bool.
    private var renameBinding: Binding<Bool> {
        Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })
    }
}
