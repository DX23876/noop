import Foundation

/// Modal tasks launched from Settings. Keeping one optional route prevents competing sheets from
/// becoming active at the same time and makes dismissal a single state transition.
enum SettingsSheet: String, Identifiable {
    case whatsNew
    case scoringGuide
    case acknowledgements
    case howNoopWorks
    case appleWatchSetup
    case heartRateZones
    case stepCalibration
    case diagnostics

    var id: String { rawValue }
}
