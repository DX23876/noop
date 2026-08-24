import WidgetKit
import SwiftUI

/// The widget extension entry point. Bundles the glanceable widget, the three-rings widget (redesign §9),
/// and the live-HR Live Activity.
@main
struct NOOPWidgetBundle: WidgetBundle {
    var body: some Widget {
        NOOPWidget()
        NOOPRingsWidget()
        NOOPEnergyWidget()
        NOOPLiveActivity()
    }
}
