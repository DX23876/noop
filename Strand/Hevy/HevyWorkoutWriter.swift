import Foundation
import WhoopStore
import StrandImport

enum HevyWorkoutWriter {
    static func send(_ proposal: HevyWorkoutProposal, using fetcher: HevyFetching) async throws -> HevyWorkout {
        let body = try requestBody(for: proposal.workout)
        let data: Data
        switch proposal.operation {
        case .create: data = try await fetcher.post(path: "/workouts", body: body)
        case .update: data = try await fetcher.put(path: "/workouts/\(proposal.workout.id)", body: body)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HevyError.decode
        }
        let document = (root["workout"] as? [String: Any]) ?? root
        guard let workout = HevyApiParser.parseWorkouts([document]).items.first else {
            throw HevyError.decode
        }
        return workout
    }

    static func requestBody(for workout: HevyWorkout) throws -> Data {
        let iso = ISO8601DateFormatter()
        var value: [String: Any] = [
            "title": workout.title,
            "start_time": iso.string(from: Date(timeIntervalSince1970: TimeInterval(workout.startTs))),
            "end_time": iso.string(from: Date(timeIntervalSince1970: TimeInterval(workout.endTs))),
            "exercises": workout.exercises.map { exercise in
                var item: [String: Any] = [
                    "exercise_template_id": exercise.templateId ?? "",
                    "sets": exercise.sets.map { set -> [String: Any] in
                        var row: [String: Any] = ["type": set.type == .other ? "normal" : set.type.rawValue]
                        if let value = set.weightKg { row["weight_kg"] = value }
                        if let value = set.reps { row["reps"] = value }
                        if let value = set.distanceM { row["distance_meters"] = value }
                        if let value = set.durationS { row["duration_seconds"] = value }
                        if let value = set.rpe { row["rpe"] = value }
                        if let value = set.customMetric { row["custom_metric"] = value }
                        return row
                    }
                ]
                if let value = exercise.supersetId { item["superset_id"] = value }
                if let value = exercise.notes, !value.isEmpty { item["notes"] = value }
                return item
            }
        ]
        if let notes = workout.notes, !notes.isEmpty { value["description"] = notes }
        return try JSONSerialization.data(withJSONObject: ["workout": value], options: [.sortedKeys])
    }
}
