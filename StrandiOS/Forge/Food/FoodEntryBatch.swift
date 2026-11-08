#if os(iOS)
import WhoopStore

/// Entries handed to a sheet together (copy to days, save as recipe).
struct FoodEntryBatch: Identifiable {
    let entries: [FoodLogEntry]
    var id: String { entries.map(\.id).joined(separator: ",") }
}
#endif
