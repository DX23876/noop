#if os(iOS)
import Foundation
import Observation
import StrandCore
import WhoopStore

/// The add sheet's search and lists: local results as you type, Open Food Facts after a pause in typing (it allows
/// about ten searches a minute), and the recent, favourite and own foods.
@MainActor
@Observable
final class FoodSearchModel {
    var query = ""
    private(set) var local: [FoodItem] = []
    private(set) var online: [FoodItem] = []
    private(set) var onlineFailed = false
    private(set) var searched = false
    private(set) var recents: [FoodItem] = []
    private(set) var lastGrams: [String: Double] = [:]
    private(set) var favourites: [FoodItem] = []
    private(set) var mine: [FoodItem] = []

    /// Run by `.task(id: query)`, so a new keystroke cancels the previous search.
    func run(repo: Repository, online allowOnline: Bool) async {
        let text = query
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            local = []; online = []; searched = false
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled, let store = await repo.storeHandle() else { return }
        let found = await FoodLibrary.search(store: store, query: text)
        guard !Task.isCancelled else { return }
        local = found
        online = []
        onlineFailed = false
        searched = true
        guard allowOnline, text.count >= FoodOnline.minimumQueryLength else { return }
        try? await Task.sleep(for: .milliseconds(650))
        guard !Task.isCancelled else { return }
        do {
            let results = try await FoodOnline.search(text, countries: FoodProductDataPrefs.countries,
                                                      language: FoodProductDataPrefs.language)
            guard !Task.isCancelled else { return }
            // A product already kept (with its filled nutrients) shows as the kept one, and only once.
            let kept = await FoodLibrary.preferKept(store: store, results)
            let localIds = Set(found.map(\.id))
            online = kept.filter { !localIds.contains($0.id) }
        } catch {
            if !Task.isCancelled { onlineFailed = true }
        }
    }

    func loadLists(repo: Repository) async {
        guard let store = await repo.storeHandle() else { return }
        let recent = await FoodLibrary.recents(store: store)
        recents = recent.map(\.item)
        lastGrams = Dictionary(recent.compactMap { pair in pair.lastGrams.map { (pair.item.id, $0) } }, uniquingKeysWith: { a, _ in a })
        favourites = await FoodLibrary.favourites(store: store)
        let own = ((try? await store.customFoods()) ?? []).map(FoodLibrary.item(for:))
        let recipes = ((try? await store.foodRecipes()) ?? []).compactMap(FoodLog.item(for:))
        mine = recipes + own
    }
}
#endif
