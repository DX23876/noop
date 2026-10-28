import Foundation
import StrandAnalytics

/// The Apple host of `CoachDataReading`: the Repository's own reads, unchanged, plus the hooks the coach starts
/// that only the app can run. Kept apart from the protocol so the protocol file links into the Android core.
extension Repository: CoachDataReading {
    var cardioLoadMaxHR: Double { Self.cardioLoadMaxHR(strainProfile) }
    var strainProfileSex: String { strainProfile?.sex ?? "" }
    func coachProfile() -> CoachProfile {
        let p = ProfileStore()
        return CoachProfile(sex: p.sex, age: p.age, heightCm: p.heightCm, weightKg: p.weightKg, hrMax: p.hrMax,
                            hrZoneSet: p.hrZoneSet, analytics: Self.analyticsProfile(p))
    }
    func refreshCoachCheckIn() async { await CoachCheckIn.refreshDynamicSchedule(repo: self) }
    func trainingLoadBrief() async -> String {
        CoachTrainingLoadBrief.text(await TrainingLoadModel.snapshot(repo: self).prepared)
    }
}
