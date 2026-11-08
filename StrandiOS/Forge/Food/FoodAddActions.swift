#if os(iOS)
import SwiftUI

/// The add sheet's three ways besides search: scan, calories only, describe to the coach.
struct FoodAddActions: View {
    let coachOn: Bool
    let scan: () -> Void
    let quick: () -> Void
    let describe: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            FoodActionTile(title: String(localized: "Scan"), systemImage: "barcode.viewfinder", action: scan)
            FoodActionTile(title: String(localized: "Calories"), systemImage: "number", action: quick)
            if coachOn {
                FoodActionTile(title: String(localized: "Describe"), systemImage: "text.bubble", action: describe)
            }
        }
    }
}
#endif
