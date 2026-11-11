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
                    Text(title).font(.body).foregroundStyle(ForgeColor.text).lineLimit(2)
                    Text(detail).font(.footnote).foregroundStyle(ForgeColor.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(FoodText.kcal(entry.totals["energy_kcal"])).font(ForgeFont.rounded(17, .medium)).monospacedDigit()
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

    /// A database name like "Vollmilch frisch, 3,5 % Fett, pasteurisiert" reads as its first part; the rest
    /// moves to the grey line under it.
    private var nameParts: (title: String, rest: String?) {
        guard let comma = entry.name.range(of: ", ") else { return (entry.name, nil) }
        return (String(entry.name[..<comma.lowerBound]), String(entry.name[comma.upperBound...]))
    }
    private var title: String { nameParts.title }

    private var detail: String {
        var parts: [String] = []
        if let rest = nameParts.rest { parts.append(rest) }
        if let label = entry.portionLabel { parts.append(label) } else if let grams = entry.grams { parts.append("\(FoodText.grams(grams)) g") }
        if let brand = entry.brand { parts.append(brand) }
        return parts.joined(separator: " · ")
    }

    private func edit() { onEdit(entry) }
    private func copy() { onCopy(entry) }
    private func delete() { onDelete(entry) }
}
#endif
