import Foundation
import StrandAnalytics

/// The Apple host of `CoachDataReading`: the Repository's own reads, unchanged, plus the hooks the coach starts
/// that only the app can run. Kept apart from the protocol so the protocol file links into the Android core.
extension Repository: CoachDataReading {
    var cardioLoadMaxHR: Double { Self.cardioLoadMaxHR(strainProfile) }
    var strainProfileSex: String { strainProfile?.sex ?? "" }
    func refreshCoachCheckIn() async { await CoachCheckIn.refreshDynamicSchedule(repo: self) }
    func trainingLoadBrief() async -> String {
        CoachTrainingLoadBrief.text(await TrainingLoadModel.snapshot(repo: self).prepared)
    }
}
