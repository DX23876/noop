import Foundation
import StrandCore

// The localized side of `WorkoutCatalog` (StrandCore): sport names in the wearer's language and the search
// over them. Kept in the app so the string catalogue keeps extracting them.
extension WorkoutCatalog.Sport {
    /// The name in the wearer's language. `name` stays the stored, locale-stable key.
    var displayName: String { WorkoutSource.localizedDisplaySport(name) }
}

extension WorkoutCatalog {
    /// Catalogue filtered by a search query (empty → the whole list). Names only, case-insensitive.
    static func matching(_ query: String) -> [Sport] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        // Matches the stored English key and the translated name, so "Laufen" finds Running.
        return all.filter {
            $0.name.range(of: q, options: .caseInsensitive) != nil
                || $0.displayName.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
