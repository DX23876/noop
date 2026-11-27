import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// ProjectService.swift — the two writes the Roadmap page can make: a thumb on a roadmap item, and a
// suggestion sent to the owner. Shared by both platforms, like the reading side in ProjectFeed.swift.
//
// Four properties this file exists to keep:
//
// 1. **Nothing happens without an address.** The service URL comes from `docs/app-feed.json`, never from
//    the binary. No field, no calls, and the screens hide both features. That is also the kill switch:
//    removing the field silences every installed copy, however old, without an update.
// 2. **The device key is not an identity.** 128 random bits, made on first use, sent only so a second
//    thumb on the same item can be refused. It carries no name, no account and no device detail, it
//    never leaves this one purpose, and clearing the app's data makes a new one.
// 3. **A thumb can be taken back.** A vote you cannot withdraw is one people do not cast.
// 4. **What was voted is remembered here, not asked for.** The screen must know its own thumbs offline,
//    so they live in preferences; the service is only asked for totals.

/// Why a write did not go out. ONE vocabulary, resolved in ONE place (`ProjectService.failure`),
/// because the screens used to answer every cause with the same sentence: "that did not go out, try
/// again later". A reporter who reads that cannot tell a switch they threw themselves from a service
/// that said no from a dead connection, and neither can anybody trying to help them.
public enum ProjectWriteFailure: String, Equatable, Sendable, CaseIterable {
    /// Nothing left the device because the wearer switched sending off. Only the switch: a device that
    /// simply has no address yet answers `unreachable`, because telling a wearer who left the switch on
    /// that it is off sends them looking for a setting that is already right (tester report, 2026-11-24).
    case notSending
    /// The service answered, and asked for less: this device has written too often in the last hour.
    case tooMany
    /// The service answered, and did not take it.
    case refused
    /// Nothing answered.
    case unreachable
}

/// One write to the project's service. Pure value, so the call sites and the tests see the same thing.
public enum ProjectServiceResult: Equatable, Sendable {
    case sent(count: Int?)
    case failed(ProjectWriteFailure)

    /// The two spellings the call sites were written with. The same VALUE, not a second answer: they
    /// exist so a `return .refused` in a validation guard still reads as a sentence.
    public static let refused = ProjectServiceResult.failed(.refused)
    public static let unreachable = ProjectServiceResult.failed(.unreachable)
}

/// Votes and suggestions. `service` is the base URL from the feed; nil disables everything.
public actor ProjectService {
    public static let maximumSuggestion = 500

    private let service: URL?
    private let keyStore: ProjectDeviceKeyStore
    private let sharing: ProjectSharing
    private let send: @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public init(service: URL?, keyStore: ProjectDeviceKeyStore = .standard,
                sharing: ProjectSharing = .standard,
                send: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil) {
        self.service = service
        self.keyStore = keyStore
        self.sharing = sharing
        self.send = send ?? { request in
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            return try await session.data(for: request)
        }
    }

    /// Whether the screens may show voting, the wish field and reporting at all.
    public var isAvailable: Bool { endpoint != nil }

    /// The ONE gate every write passes. Two things can close it: no address in the feed, which is the
    /// kill switch, and the wearer's own switch. Reading is not gated here, because reading sends
    /// nothing about the reader, and a roadmap withheld for privacy helps nobody.
    var endpoint: URL? { sharing.isOn ? service : nil }

    /// Why `endpoint` is closed, for the writes that report it. The switch is named only when it is the
    /// switch; a missing address is the same as nothing answering, which is what the wearer can act on.
    var closedReason: ProjectWriteFailure { sharing.isOn ? .unreachable : .notSending }

    /// The device key, for the routes that are rate limited. Never stored beside a report code.
    func deviceKey() -> String { keyStore.key() }

    /// What a POST came back with: the body when it was taken, or the one reason it was not. It used
    /// to answer nil for all of them, which is how a rate limit and a dead connection reached the
    /// screen as the same sentence.
    enum Answer {
        case taken([String: Any])
        case not(ProjectWriteFailure)
    }

    /// A POST whose answer is wanted, not just its success.
    func ask(_ url: URL, body: [String: Any]) async -> Answer {
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .not(.refused)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = payload
        guard let (data, response) = try? await perform(request),
              let http = response as? HTTPURLResponse else { return .not(.unreachable) }
        guard (200...299).contains(http.statusCode) else {
            return .not(ProjectService.failure(status: http.statusCode))
        }
        return .taken(((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:])
    }

    /// The ONE resolver from what the service answered to why the write did not go out. Called only
    /// for an answer that was not a success, and never guessed at a second call site.
    ///
    /// Two groups, by what can be said honestly. 429 is the one answer that names itself and is worth
    /// its own sentence, because waiting actually fixes it. Everything else that ARRIVED is "the
    /// service did not take it", whether it was a 400 we should never have sent, a 410 for a code
    /// that is gone or a 502 from the far side; the one thing it is not is a connection problem, and
    /// saying so sent people to their network settings. No answer at all is the only `unreachable`.
    static func failure(status: Int) -> ProjectWriteFailure {
        status == 429 ? .tooMany : .refused
    }

    /// The one place a request actually goes out, so a test can stand in for all of them.
    func perform(_ request: URLRequest, body: Data? = nil) async throws -> (Data, URLResponse) {
        var outgoing = request
        if let body { outgoing.httpBody = body }
        return try await send(outgoing)
    }

    /// Set or withdraw this device's thumb. Returns the new total when the service reports one.
    public func vote(id: String, on: Bool) async -> ProjectServiceResult {
        guard let service = endpoint else { return .failed(closedReason) }
        guard ProjectService.isVotableID(id) else { return .refused }
        let body: [String: Any] = ["id": id, "on": on, "key": keyStore.key()]
        let result = await post(service.appendingPathComponent("v1/vote"), body: body)
        if case .sent = result { keyStore.remember(id: id, voted: on) }
        return result
    }

    /// Send a suggestion. It becomes an issue in the owner's private repository; nothing is public until
    /// the owner releases it, and the app never reads it back.
    public func suggest(text: String) async -> ProjectServiceResult {
        guard let service = endpoint else { return .failed(closedReason) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= ProjectService.maximumSuggestion else { return .refused }
        return await post(service.appendingPathComponent("v1/suggestion"),
                          body: ["text": trimmed, "key": keyStore.key()])
    }

    /// Every item's total. Only asked for once this device has voted, so an untouched page makes no call.
    public func counts() async -> [String: Int] {
        guard let service = endpoint else { return [:] }
        var request = URLRequest(url: service.appendingPathComponent("v1/counts"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await perform(request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let counts = root["counts"] as? [String: Any] else { return [:] }
        return counts.compactMapValues { ($0 as? NSNumber)?.intValue }
    }

    func post(_ url: URL, body: [String: Any]) async -> ProjectServiceResult {
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return .refused }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = payload
        guard let (data, response) = try? await perform(request),
              let http = response as? HTTPURLResponse else { return .failed(.unreachable) }
        guard (200...299).contains(http.statusCode) else {
            return .failed(ProjectService.failure(status: http.statusCode))
        }
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return .sent(count: (root?["count"] as? NSNumber)?.intValue)
    }

    /// The same shape the roadmap file's checker enforces, so an id the service would reject never leaves.
    public static func isVotableID(_ id: String) -> Bool {
        guard (2...40).contains(id.count), let first = id.first, first.isLowercase || first.isNumber else {
            return false
        }
        return id.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    }
}

/// The device key and this device's own thumbs. Preferences, not the database: it is not the wearer's
/// data, it is what this installation has clicked.
public struct ProjectDeviceKeyStore: Sendable {
    public static let keyDefault = "projectDeviceKey"
    public static let votesDefault = "projectVotedItems"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public static let standard = ProjectDeviceKeyStore()

    /// 128 random bits as lowercase hex, made once. Not derived from anything about the device: a
    /// derived value would be the same after a reinstall, and that is an identifier.
    public func key() -> String {
        if let existing = defaults.string(forKey: Self.keyDefault), existing.count == 32 { return existing }
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        let made = bytes.map { String(format: "%02x", $0) }.joined()
        defaults.set(made, forKey: Self.keyDefault)
        return made
    }

    public func votedItems() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.votesDefault) ?? [])
    }

    public func hasVoted(_ id: String) -> Bool { votedItems().contains(id) }

    public func remember(id: String, voted: Bool) {
        var items = votedItems()
        if voted { items.insert(id) } else { items.remove(id) }
        defaults.set(Array(items).sorted(), forKey: Self.votesDefault)
    }
}
