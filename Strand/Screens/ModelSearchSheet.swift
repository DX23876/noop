import SwiftUI
import StrandDesign

/// A searchable model picker for a provider whose catalogue is too long for an inline menu — today only
/// OpenRouter's 300+ models, but `CoachSettingsView` decides that by a plain count threshold, so this
/// applies to whichever provider's list grows past it, not to OpenRouter by name.
///
/// Typing a query that matches nothing offers it as a free-text choice — the sheet's own equivalent of
/// the inline picker's "Custom…" escape hatch, so a model id newer than the last refresh is never
/// unreachable.
struct ModelSearchSheet: View {
    let models: [String]
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [String] {
        guard !query.isEmpty else { return models }
        let q = query.lowercased()
        return models.filter { $0.lowercased().contains(q) }
    }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var offersTypedEntry: Bool {
        !trimmedQuery.isEmpty && !models.contains(trimmedQuery)
    }

    var body: some View {
        NavigationStack {
            List {
                if offersTypedEntry {
                    Section {
                        Button {
                            selection = trimmedQuery
                            dismiss()
                        } label: {
                            Label("Use \"\(query)\"", systemImage: "square.and.pencil")
                        }
                    }
                }
                Section {
                    ForEach(filtered, id: \.self) { candidate in
                        Button {
                            selection = candidate
                            dismiss()
                        } label: {
                            HStack {
                                Text(candidate)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if candidate == selection {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(StrandPalette.accent)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        // `candidate` is a technical model id (not translated); mixing it with a plain
                        // `candidate` branch typed the whole ternary as `String`, which never localizes
                        // even the "selected" suffix — String(localized:) fixes that while leaving the
                        // id itself exactly as typed.
                        .accessibilityLabel(candidate == selection
                                            ? String(localized: "\(candidate), selected") : candidate)
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: Text("Search models"))
            .navigationTitle("Choose a model")
            #if !os(macOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
