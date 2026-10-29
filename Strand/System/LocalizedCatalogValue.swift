import Foundation

/// Resolves a runtime string against the app's compiled String Catalog — for the handful of places a
/// fixed-set enum label (`CoachPersona.title`, `PlanProposal.SkipReason.label`, …) needs to appear
/// INSIDE a larger sentence (an interpolated `Text`, an accessibility label built from several dynamic
/// pieces) rather than standing alone in its own `Text(_:)`. `Text(LocalizedStringKey(x.label))` covers
/// the standalone case; this covers the composed one, so the embedded word itself follows the system
/// language instead of riding along in English.
///
/// Falls back to the string unchanged when no catalog entry matches — safe on dynamic, non-catalog
/// content (a user-typed conversation title, an AI-generated sentence) that happens to flow through the
/// same call site as a real label.
extension String {
    var localizedCatalogValue: String {
        #if os(Android)
        // Android ships the catalog per language for the shared core (`CoreLocalization`), not as a bundle table.
        CoreLocalization.lookup(self) ?? self
        #else
        Bundle.main.localizedString(forKey: self, value: self, table: nil)
        #endif
    }
}
