#if os(iOS)
import SwiftUI
import StrandCore
import WhoopStore

/// One logged food: name, amount and brand, calories; a tap edits it, a hold offers copy and delete.
struct FoodEntryRow: View {
    let entry: FoodLogEntry
    let onEdit: (FoodLogEntry) -> Void
    let onCopy: (FoodLogEntry) -> Void
    let onDelete: (FoodLogEntry) -> Void

    var body: some View {
        Button(action: edit) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.callout).bold().foregroundStyle(ForgeColor.text).lineLimit(2)
                    Text(detail).font(.footnote).foregroundStyle(ForgeColor.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(FoodText.kcal(entry.totals["energy_kcal"])).font(ForgeFont.rounded(17, .semibold))
                    .foregroundStyle(ForgeColor.text)
            }
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy to other days", systemImage: "doc.on.doc", action: copy)
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        }
        .accessibilityHint(Text("Edit amount, time or meal"))
    }

    private var detail: String {
        var parts: [String] = []
        if let label = entry.portionLabel { parts.append(label) } else if let grams = entry.grams { parts.append("\(FoodText.grams(grams)) g") }
        if let brand = entry.brand { parts.append(brand) }
        if !entry.estimatedKeys.isEmpty { parts.append(String(localized: "partly estimated")) }
        return parts.joined(separator: " · ")
    }

    private func edit() { onEdit(entry) }
    private func copy() { onCopy(entry) }
    private func delete() { onDelete(entry) }
}
#endif
