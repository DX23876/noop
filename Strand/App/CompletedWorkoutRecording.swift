import Foundation
import StrandAnalytics
import WhoopStore

/// Immutable recording evidence; an edited workout row never rewrites its original measurements.
struct CompletedWorkoutRecording: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let deviceId: String
    let row: WorkoutRow
    let route: WorkoutRoute?
    let timeline: WorkoutRecordingTimeline
}

extension CompletedWorkoutRecording {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        deviceId = try values.decode(String.self, forKey: .deviceId)
        row = try values.decode(WorkoutRow.self, forKey: .row)
        route = try values.decodeIfPresent(WorkoutRoute.self, forKey: .route)
        timeline = try values.decode(WorkoutRecordingTimeline.self, forKey: .timeline)
        guard timeline.isValid, row.startTs > 0, row.endTs >= row.startTs,
              row.durationS.map({ $0.isFinite && $0 >= 0 && $0 < Double(Int.max) / 1000 }) ?? false,
              route.map({ $0.distanceM.isFinite && $0.distanceM >= 0 }) ?? true else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid workout recording evidence"))
        }
    }
}
