import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import StrandTraining

public enum ExerciseDBProviderError: String, Error {
    case invalidEndpoint, invalidResponse, emptyResponse, limitExceeded
}

/// One explicit, read-only metadata page. Parsing is shared; media URLs remain identifiers and never
/// trigger downloads. The transient request has no cookies, cache, redirects or health-data payload.
public enum ExerciseDBProviderClient {
    public static let defaultEndpoint = "https://oss.exercisedb.dev/api/v1/exercises"
    public static let defaultDocumentation = "https://oss.exercisedb.dev/docs"
    public static let defaultHeader = "x-rapidapi-key"
    public static let defaultAttribution = "Exercise data: ExerciseDB V1 / AscendAPI — oss.exercisedb.dev."
    public static let maximumResponseBytes = 25_000_000

    public static func fetch(endpoint: String, key: String?, headerName: String?,
                              configuration: URLSessionConfiguration = .ephemeral) async throws -> [TrainingExercise] {
        let request = try request(endpoint: endpoint, key: key, headerName: headerName)
        let data = try await ExerciseDBTransfer.read(request, configuration: configuration)
        try Task.checkCancellation()
        let credit = request.url?.host?.lowercased() == URL(string: defaultEndpoint)?.host ? defaultAttribution : nil
        return try parse(data, attribution: credit)
    }

    public static func request(endpoint: String, key: String?, headerName: String?) throws -> URLRequest {
        guard let url = URL(string: endpoint), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { throw ExerciseDBProviderError.invalidEndpoint }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key, !key.isEmpty {
            let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
            guard let headerName, !headerName.isEmpty, headerName.utf8.count <= 128,
                  headerName.unicodeScalars.allSatisfy(token.contains), key.utf8.count <= 4096,
                  !key.contains("\r"), !key.contains("\n"),
                  !["host", "cookie", "content-length", "connection", "transfer-encoding"].contains(headerName.lowercased())
            else { throw ExerciseDBProviderError.invalidEndpoint }
            request.setValue(key, forHTTPHeaderField: headerName)
            if headerName.lowercased() == "x-rapidapi-key" { request.setValue(host, forHTTPHeaderField: "x-rapidapi-host") }
        }
        return request
    }

    public static func parse(_ data: Data, attribution: String? = nil) throws -> [TrainingExercise] {
        guard data.count <= maximumResponseBytes else { throw ExerciseDBProviderError.limitExceeded }
        let decoder = JSONDecoder()
        let records: [RemoteExercise]
        if let direct = try? decoder.decode([RemoteExercise].self, from: data) { records = direct }
        else if let wrapped = try? decoder.decode(RemoteEnvelope.self, from: data) { records = wrapped.data ?? wrapped.exercises ?? [] }
        else { throw ExerciseDBProviderError.invalidResponse }
        let exercises = records.compactMap { record -> TrainingExercise? in
            guard var exercise = record.trainingExercise else { return nil }
            exercise.attribution = attribution
            return exercise
        }
        guard !exercises.isEmpty else { throw ExerciseDBProviderError.emptyResponse }
        guard Set(exercises.map(\.id)).count == exercises.count else { throw ExerciseDBProviderError.invalidResponse }
        return exercises
    }

    /// A corrected provider measurement must not reinterpret sets that still refer to an older id.
    /// The replacement gets a deterministic id while the old definition and completed logs survive.
    public static func keepingMeasurementIdentity(_ exercises: [TrainingExercise], existing: [TrainingExercise]) throws -> [TrainingExercise] {
        var known = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func compatible(_ old: TrainingExercise, _ new: TrainingExercise) -> Bool {
            old.mode == new.mode && old.effectiveLoadSemantics == new.effectiveLoadSemantics
        }
        let reviewed = exercises.map { exercise in
            var id = exercise.id
            if let old = known[id], !compatible(old, exercise) {
                let base = "\(id):\(exercise.mode.rawValue)"
                id = base
                var suffix = 2
                while let taken = known[id], !compatible(taken, exercise) { id = "\(base):\(suffix)"; suffix += 1 }
            }
            let result = TrainingExercise(id: id, title: exercise.title, mode: exercise.mode,
                primaryMuscleId: exercise.primaryMuscleId, secondaryMuscleIds: exercise.secondaryMuscleIds,
                equipmentIds: exercise.equipmentIds, instructions: exercise.instructions, isUnilateral: exercise.isUnilateral,
                source: exercise.source, sourceId: exercise.sourceId, mediaId: exercise.mediaId, canonicalId: exercise.canonicalId,
                aliases: exercise.aliases, contentVersion: exercise.contentVersion, attribution: exercise.attribution,
                loadSemantics: exercise.loadSemantics)
            known[id] = result
            return result
        }
        guard Set(reviewed.map(\.id)).count == reviewed.count else { throw ExerciseDBProviderError.invalidResponse }
        return reviewed
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
            let normalizedEquipment = equipmentValues.map(TrainingEquipmentCatalog.canonical)
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

/// A bounded streaming transfer, including the cancellation-before-start race. No session outlives its
/// one request, and a redirect never receives the wearer's custom authentication header.
private final class ExerciseDBTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var bytes = Data()
    private var cancelled = false

    static func read(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Data {
        let transfer = ExerciseDBTransfer()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { transfer.start(request, configuration: configuration, continuation: $0) }
        }, onCancel: { transfer.cancel() })
    }
    private func start(_ request: URLRequest, configuration: URLSessionConfiguration,
                       continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.dataTask(with: request)
        lock.unlock()
        task.resume()
    }
    private func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let continuation = self.continuation; self.continuation = nil
        let session = self.session; self.session = nil
        bytes = Data()
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel); finish(.failure(ExerciseDBProviderError.invalidResponse)); return
        }
        guard response.expectedContentLength <= ExerciseDBProviderClient.maximumResponseBytes else {
            completionHandler(.cancel); finish(.failure(ExerciseDBProviderError.limitExceeded)); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        guard data.count <= ExerciseDBProviderClient.maximumResponseBytes - bytes.count else {
            lock.unlock(); finish(.failure(ExerciseDBProviderError.limitExceeded)); return
        }
        bytes.append(data)
        lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { finish(.failure(ExerciseDBProviderError.invalidResponse)); return }
        lock.lock(); let data = bytes; lock.unlock()
        finish(.success(data))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
