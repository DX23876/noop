import Foundation
import Security
import StrandTraining

enum ExerciseDBCredentials {
    private static let service = "app.noop.training.exercisedb"
    private static let account = "personal-api-key"

    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { clear(); return true }
        clear()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(trimmed.utf8)
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func clear() { SecItemDelete(baseQuery as CFDictionary) }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

enum ExerciseDBProviderError: Error {
    case invalidEndpoint
    case invalidResponse
    case emptyResponse
}

/// Small opt-in client for a wearer-supplied ExerciseDB-compatible endpoint. It downloads one page
/// only and keeps provider media as a URL identifier; animations and videos are never copied into
/// completed workouts or bulk-downloaded in the background.
enum ExerciseDBProviderClient {
    static func fetch(endpoint: String, key: String?, headerName: String?) async throws -> [TrainingExercise] {
        guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(),
              scheme == "https" else { throw ExerciseDBProviderError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key, !key.isEmpty, let headerName, !headerName.isEmpty {
            request.setValue(key, forHTTPHeaderField: headerName)
        }
        if headerName?.lowercased() == "x-rapidapi-key", let host = url.host {
            request.setValue(host, forHTTPHeaderField: "x-rapidapi-host")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ExerciseDBProviderError.invalidResponse
        }
        let decoder = JSONDecoder()
        let records: [RemoteExercise]
        if let direct = try? decoder.decode([RemoteExercise].self, from: data) {
            records = direct
        } else if let wrapped = try? decoder.decode(RemoteEnvelope.self, from: data) {
            records = wrapped.data ?? wrapped.exercises ?? []
        } else {
            throw ExerciseDBProviderError.invalidResponse
        }
        let exercises = records.compactMap(\.trainingExercise)
        guard !exercises.isEmpty else { throw ExerciseDBProviderError.emptyResponse }
        return exercises
    }

    private struct RemoteEnvelope: Decodable {
        let data: [RemoteExercise]?
        let exercises: [RemoteExercise]?
    }

    private struct RemoteExercise: Decodable {
        let id: String?
        let exerciseId: String?
        let name: String
        let bodyPart: String?
        let bodyParts: [String]?
        let target: String?
        let targetMuscles: [String]?
        let secondaryMuscles: [String]?
        let equipment: String?
        let equipments: [String]?
        let instructions: [String]?
        let gifUrl: String?
        let imageUrl: String?
        let videoUrl: String?

        var trainingExercise: TrainingExercise? {
            guard let rawId = exerciseId ?? id, !rawId.isEmpty,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let equipmentValues = equipments ?? equipment.map { [$0] } ?? []
            let normalizedEquipment = equipmentValues.map(Self.key)
            let rawPrimary = targetMuscles?.first ?? target ?? bodyParts?.first ?? bodyPart
            return TrainingExercise(
                id: "exercisedb:\(rawId)", title: name.trimmingCharacters(in: .whitespacesAndNewlines),
                mode: normalizedEquipment.contains("bodyweight") ? .bodyweightReps : .weightReps,
                primaryMuscleId: Self.muscle(rawPrimary),
                secondaryMuscleIds: (secondaryMuscles ?? []).compactMap(Self.muscle),
                equipmentIds: normalizedEquipment,
                instructions: instructions ?? [], source: .exerciseDB, sourceId: rawId,
                mediaId: videoUrl ?? gifUrl ?? imageUrl)
        }

        private static func key(_ value: String) -> String {
            value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased().replacingOccurrences(of: " ", with: "-")
        }

        private static func muscle(_ value: String?) -> String? {
            guard let value else { return nil }
            let key = key(value)
            if key.contains("pector") || key == "chest" { return "chest" }
            if key.contains("latiss") || key == "lats" { return "lats" }
            if key.contains("biceps") { return "biceps" }
            if key.contains("triceps") { return "triceps" }
            if key.contains("forearm") { return "forearms" }
            if key.contains("deltoid-anterior") { return "front_delts" }
            if key.contains("deltoid-posterior") { return "rear_delts" }
            if key.contains("deltoid") || key.contains("shoulder") { return "side_delts" }
            if key.contains("trapez") { return "traps" }
            if key.contains("erector") || key.contains("lower-back") { return "lower_back" }
            if key.contains("back") { return "upper_back" }
            if key.contains("quad") || key.contains("upper-legs") { return "quadriceps" }
            if key.contains("hamstring") { return "hamstrings" }
            if key.contains("glute") { return "glutes" }
            if key.contains("adductor") { return "adductors" }
            if key.contains("abductor") { return "abductors" }
            if key.contains("calf") || key.contains("lower-legs") { return "calves" }
            if key.contains("tibial") { return "tibialis" }
            if key.contains("oblique") { return "obliques" }
            if key.contains("abdom") || key == "abs" || key == "waist" { return "abdominals" }
            if key.contains("neck") { return "neck" }
            return nil
        }
    }
}
