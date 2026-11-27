#if os(iOS)
import SwiftUI
import StrandCore
import WhoopStore

/// Picks one food for the builder: search, or the recent and starred foods, then its amount. Closes after one,
/// so the builder shows each food as it comes in.
struct FoodPickSheet: View {
    let model: ForgeFoodModel
    let add: (FoodCartLine) -> Void
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FoodProductDataPrefs.modeKey) private var modeRaw = FoodProductDataMode.none.rawValue
    @State private var search = FoodSearchModel()
    @State private var portionFor: FoodItem?

    var body: some View {
        NavigationStack {
            List {
                if search.query.isEmpty {
                    if !model.favouriteFoods.isEmpty {
                        FoodListSection(title: String(localized: "Favourites"), items: model.favouriteFoods, empty: nil,
                                        lastGrams: search.lastGrams, favouriteIds: model.favouriteIds,
                                        onPick: pick, onFavourite: favourite, onQuickAdd: quickAdd)
                    }
                    FoodListSection(title: String(localized: "Recent"),
                                    items: search.recents.filter { !model.favouriteIds.contains($0.id) },
                                    empty: String(localized: "What you log shows up here."), lastGrams: search.lastGrams,
                                    favouriteIds: model.favouriteIds, onPick: pick, onFavourite: favourite, onQuickAdd: quickAdd)
                } else {
                    FoodListSection(items: search.local + search.online, empty: nil, lastGrams: search.lastGrams,
                                    favouriteIds: model.favouriteIds, onPick: pick, onFavourite: favourite, onQuickAdd: quickAdd)
                }
            }
            .overlay {
                if !search.query.isEmpty && search.searched && search.local.isEmpty && search.online.isEmpty {
                    ContentUnavailableView.search
                }
            }
            .searchable(text: $search.query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search foods"))
            .navigationTitle("Add a food")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) } }
            .task(id: search.query) {
                await search.run(repo: repo, online: FoodProductDataMode(rawValue: modeRaw) == .online)
            }
            .task { await search.loadLists(repo: repo) }
            .sheet(item: $portionFor) { item in
                FoodPortionSheet(item: item, model: model, lastGrams: search.lastGrams[item.id], add: chosen)
            }
        }
    }

    private func close() { dismiss() }
    private func pick(_ item: FoodItem) { portionFor = item }
    private func quickAdd(_ item: FoodItem, _ grams: Double) { chosen(FoodItemRow.quickLine(item, grams)) }
    private func favourite(_ item: FoodItem, _ on: Bool) { Task { await model.setFavourite(item, on: on, repo: repo) } }

    private func chosen(_ line: FoodCartLine) {
        add(line)
        dismiss()
    }
}
#endif
