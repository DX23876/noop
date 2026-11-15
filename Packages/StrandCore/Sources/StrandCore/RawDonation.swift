import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// RawDonation.swift — recording bounded raw-motion windows during a workout and, on the wearer's press,
// sending them so a sport detector can one day be built. Shared by both platforms.
//
// Five properties this file exists to keep, each of them a promise the explainer page makes:
//
// 1. **Nothing records unless a sport was ticked.** The default is an empty set: no tick, no capture,
//    and `plan(for:)` returns nil rather than an empty schedule, so the caller cannot arm by accident.
// 2. **Short windows, not the whole session.** Three windows of two minutes spread across the workout.
//    Many clean examples teach a detector more than one long recording, and it keeps the strap, the
//    battery and the file small.
// 3. **Nothing leaves without a press.** A finished recording waits as a pending donation until the
//    wearer reviews it. The upload path does not exist without a service address either.
// 4. **The package carries no identity.** Sport, strap family, firmware, app version, sample rate, times
//    counted from the start of the recording, and a withdrawal code. Never the device id the collector's
//    own export writes, never a wall clock finer than a date, never location or heart data.
// 5. **A donation can be withdrawn.** Each one shows a short code; the owner deletes the object that
//    code names. Without it a withdrawal would be impossible, because nothing links a file to a person,
//    which is the point.
//
// What this file does NOT decide: whether streaming raw data during a workout disturbs the live heart
// rate or the history offload. That is a hardware question, unmeasured at the time of writing, and it is
// why nothing is ticked by default and why the page says so in as many words.

/// One two-minute stretch to record, measured from the start of the workout.
public struct RawDonationWindow: Equatable, Sendable, Codable {
    public let startOffset: TimeInterval
    public let duration: TimeInterval

    public init(startOffset: TimeInterval, duration: TimeInterval) {
        self.startOffset = startOffset
        self.duration = duration
    }

    public var endOffset: TimeInterval { startOffset + duration }
    public func contains(_ offset: TimeInterval) -> Bool {
        offset >= startOffset && offset < endOffset
    }
}

/// When to record during a workout. Pure: the same inputs give the same plan on both platforms.
public enum RawDonationPlan {
    public static let windowCount = 3
    public static let windowSeconds: TimeInterval = 120
    /// Below this there is no room for a spread, so one window is recorded and that is the whole plan.
    public static let shortestSession: TimeInterval = 240

    /// The windows for a session of this expected length, or nil when the sport is not ticked.
    ///
    /// `expected` is only a hint: a session that ends early simply stops, and one that runs long keeps
    /// the plan it started with. The first window never begins at zero, because the first seconds of a
    /// workout are someone fiddling with their phone, not the movement we are after.
    public static func windows(expected: TimeInterval) -> [RawDonationWindow] {
        guard expected > 0 else { return [] }
        let lead: TimeInterval = 60
        guard expected >= shortestSession else {
            return [RawDonationWindow(startOffset: min(lead, max(0, expected - windowSeconds)),
                                      duration: min(windowSeconds, expected))]
        }
        let usable = expected - lead
        let slot = usable / Double(windowCount)
        guard slot >= windowSeconds else {
            return [RawDonationWindow(startOffset: lead, duration: windowSeconds)]
        }
        return (0..<windowCount).map { index in
            RawDonationWindow(startOffset: lead + Double(index) * slot, duration: windowSeconds)
        }
    }

    /// Whether the strap should be streaming at this moment of the session.
    public static func isRecording(at offset: TimeInterval, windows: [RawDonationWindow]) -> Bool {
        windows.contains { $0.contains(offset) }
    }

    /// How much raw data a plan produces, as i16 six-axis samples at 100 Hz. The page says this before
    /// anyone ticks anything, so the number has to come from the plan rather than from a guess.
    public static func approximateBytes(_ windows: [RawDonationWindow], sampleRate: Int = 100) -> Int {
        let samples = windows.reduce(0.0) { $0 + $1.duration } * Double(sampleRate)
        return Int(samples * 12)
    }
}

/// Which sports the wearer ticked, and the explainer's one acknowledgement. Preferences, not the
/// database: this is a choice about the app, not a measurement about the body.
public struct RawDonationSettings: Sendable {
    public static let sportsDefault = "rawDonationSports"
    public static let keepCopyDefault = "rawDonationKeepCopy"
    public static let explainedDefault = "rawDonationExplained"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public static let standard = RawDonationSettings()

    /// Empty by default. Everything else in this file is reachable only through a non-empty set.
    public func sports() -> Set<String> {
        Set(defaults.stringArray(forKey: Self.sportsDefault) ?? [])
    }

    public func isOn(_ sport: String) -> Bool { sports().contains(WorkoutSource.sportKey(sport)) }

    public func set(_ sport: String, on: Bool) {
        var all = sports()
        let key = WorkoutSource.sportKey(sport)
        if on { all.insert(key) } else { all.remove(key) }
        defaults.set(all.sorted(), forKey: Self.sportsDefault)
    }

    /// After a successful send the local copy goes, unless the wearer asked to keep it: raw motion is
    /// the heaviest thing this app can store, and the database is already large.
    public var keepsLocalCopy: Bool {
        get { defaults.bool(forKey: Self.keepCopyDefault) }
        nonmutating set { defaults.set(newValue, forKey: Self.keepCopyDefault) }
    }

    public var hasReadExplainer: Bool {
        get { defaults.bool(forKey: Self.explainedDefault) }
        nonmutating set { defaults.set(newValue, forKey: Self.explainedDefault) }
    }

    /// The plan for a workout of this sport, or nil when it was not ticked.
    public func plan(for sport: String, expected: TimeInterval) -> [RawDonationWindow]? {
        guard isOn(sport) else { return nil }
        let windows = RawDonationPlan.windows(expected: expected)
        return windows.isEmpty ? nil : windows
    }
}

/// A recording that is finished and waiting for the wearer to decide. Nothing is sent from here.
public struct PendingDonation: Equatable, Sendable, Codable, Identifiable {
    public let id: String
    /// The short code the wearer can quote to have this withdrawn later.
    public let code: String
    public let sport: String
    public let recordedSeconds: Int
    public let bytes: Int
    public let strapFamily: String
    public let firmware: String?
    public let recordedAt: Date
    public var sentAt: Date?

    public init(id: String = UUID().uuidString, code: String = RawDonationCode.make(),
                sport: String, recordedSeconds: Int, bytes: Int, strapFamily: String,
                firmware: String? = nil, recordedAt: Date = Date(), sentAt: Date? = nil) {
        self.id = id
        self.code = code
        self.sport = sport
        self.recordedSeconds = recordedSeconds
        self.bytes = bytes
        self.strapFamily = strapFamily
        self.firmware = firmware
        self.recordedAt = recordedAt
        self.sentAt = sentAt
    }
}

/// `R-4K8T`: short enough to read out, from an alphabet without the characters people confuse.
public enum RawDonationCode {
    static let alphabet = Array("ACDEFGHJKLMNPQRTUVWXY34789")

    public static func make(count: Int = 4) -> String {
        "R-" + (0..<count).map { _ in String(alphabet.randomElement() ?? "A") }.joined()
    }

    public static func isValid(_ code: String) -> Bool {
        guard code.hasPrefix("R-") else { return false }
        let body = code.dropFirst(2)
        return body.count == 4 && body.allSatisfy { alphabet.contains($0) }
    }
}

/// What actually goes up: the metadata beside the samples. Written here rather than reusing the
/// collector's own export, which carries `device_id` and would link every donation of one person.
public enum RawDonationPackage {
    public static let schema = 1

    public static func metadata(for donation: PendingDonation, sampleRate: Int = 100,
                                appVersion: String) -> [String: Any] {
        [
            "schema": schema,
            "code": donation.code,
            "sport": WorkoutSource.sportKey(donation.sport),
            "seconds": donation.recordedSeconds,
            "sample_rate_hz": sampleRate,
            "axes": 6,
            "strap_family": donation.strapFamily,
            // The decoded firmware LAYOUT number, not a version string: it is what the app knows.
            "firmware_layout": donation.firmware ?? "",
            "app_version": appVersion,
            // A day, not a moment: enough to tell an old capture from a new one, not enough to line a
            // donation up with anything else about a person.
            "recorded_on": RawDonationPackage.day(donation.recordedAt),
        ]
    }

    /// Everything a package must never contain, as one list the test can read. A field added to the
    /// metadata above is checked against this, so the promise on the explainer page has a gate.
    public static let forbiddenKeys = ["device_id", "deviceId", "name", "email", "latitude", "longitude",
                                       "route", "heart_rate", "hr", "bpm", "timestamp", "started_at_ms"]

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Sending one donation: ask the service where to put it, put it there, tell the service it landed.
///
/// The service address comes from the feed, like voting. No address, no upload path at all, which is
/// also what the screens check before they offer to send anything.
public actor RawDonationUploader {
    public enum Outcome: Equatable, Sendable {
        case sent
        case refused
        case unreachable
    }

    private let service: URL?
    private let send: @Sendable (URLRequest, Data?) async throws -> (Data, URLResponse)

    public init(service: URL?,
                send: (@Sendable (URLRequest, Data?) async throws -> (Data, URLResponse))? = nil) {
        self.service = service
        self.send = send ?? { request, body in
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            if let body { return try await session.upload(for: request, from: body) }
            return try await session.data(for: request)
        }
    }

    public var isAvailable: Bool { service != nil }

    /// The whole send. Split from the screens so a test can drive it without a strap or a network.
    public func send(donation: PendingDonation, payload: Data, metadata: [String: Any]) async -> Outcome {
        guard let service, !payload.isEmpty else { return .refused }
        var ask = URLRequest(url: service.appendingPathComponent("v1/raw-upload-url"),
                             cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        ask.httpMethod = "POST"
        ask.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = metadata
        body["bytes"] = payload.count
        guard let askBody = try? JSONSerialization.data(withJSONObject: body) else { return .refused }
        ask.httpBody = askBody
        guard let (data, response) = try? await send(ask, nil),
              let http = response as? HTTPURLResponse else { return .unreachable }
        guard (200...299).contains(http.statusCode) else {
            return http.statusCode == 400 || http.statusCode == 429 ? .refused : .unreachable
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let target = ProjectFeedParser.service(from: root["url"]) else { return .unreachable }

        var put = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        put.httpMethod = "PUT"
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        guard let (_, putResponse) = try? await send(put, payload),
              let putHTTP = putResponse as? HTTPURLResponse,
              (200...299).contains(putHTTP.statusCode) else { return .unreachable }
        return .sent
    }
}
