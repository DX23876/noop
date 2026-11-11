#if os(iOS)
import SwiftUI
import StrandAnalytics
import StrandCore

/// Copy entries to chosen days around the shown one (Bevel's "copy to today, tomorrow or several days").
struct FoodCopySheet: View {
    let batch: FoodEntryBatch
    let model: ForgeFoodModel
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []

    private var days: [String] {
        let base = WeightSeries.date(forDay: model.day) ?? .now
        return (-3...7).compactMap { offset in
            offset == 0 ? nil : Calendar.current.date(byAdding: .day, value: offset, to: base).map(Repository.localDayKey)
        }
    }

    var body: some View {
        NavigationStack {
            List(days, id: \.self, selection: $chosen) { day in
                Text(FoodDayPicker.title(day))
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Copy to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                ToolbarItem(placement: .confirmationAction) { Button("Copy", action: copy).disabled(chosen.isEmpty) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func cancel() { dismiss() }
    private func copy() { Task { await model.copy(batch.entries, toDays: chosen.sorted(), repo: repo); dismiss() } }
}
#endif
