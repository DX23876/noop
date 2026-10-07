import WidgetKit
import SwiftUI

/// The ten fitness widgets, bundled on their own so the main bundle stays within its ten entries.
struct NOOPFitnessWidgets: WidgetBundle {
    var body: some Widget {
        NOOPSleepWidget()
        NOOPHrvWidget()
        NOOPRestingHrWidget()
        NOOPChargeWeekWidget()
        NOOPEffortWeekWidget()
        NOOPStepsWidget()
        NOOPWeightWidget()
        NOOPWorkoutsWidget()
        NOOPConsistencyWidget()
        NOOPVitalsWidget()
    }
}
