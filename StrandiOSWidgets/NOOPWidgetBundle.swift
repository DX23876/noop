import WidgetKit
import SwiftUI

/// The widget extension entry point. Bundles the glanceable widget, the three-rings widget
/// (redesign §9), the energy widget, the live-HR Live Activity, the heart-rate trace widget (#1957),
/// the stress curve widget (#2040) and the Coach brief widget.
///
/// The brief widget renders whatever `CoachBriefScheduler` last stored, and that store is now fed by
/// this fork's OWN brief (`AICoachEngine.generateBriefText`) rather than a second generation path — so
/// the widget, the notification and the Coach transcript quote one model run.
@main
struct NOOPWidgetBundle: WidgetBundle {
    var body: some Widget {
        NOOPWidget()
        NOOPRingsWidget()
        NOOPEnergyWidget()
        NOOPLiveActivity()
        HeartRateWidget()
        StressWidget()
        CoachBriefWidget()
    }
}
