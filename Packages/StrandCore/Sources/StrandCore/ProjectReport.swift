import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// ProjectReport.swift — reporting a problem from inside the app, and following what became of it.
//
// Before this, reporting was a drop box: the app built a redacted log, the wearer carried it somewhere
// themselves, and any question the owner had afterwards reached nobody. What is added here is the way
// back, under four rules that are the whole design:
//
// 1. **A report is followed by its CODE, never by the device.** The service makes the code, hands it
//    over once, and it is the entire credential for reading that thread, answering in it and taking it
//    back. The device key is never stored beside it, so nothing here can say which reports came from
//    the same person. The code lives in preferences on this device, and it is shown, so it can be
//    written down and typed back in after a new install.
// 2. **Not wanting a channel back is a first-class choice.** Sent without a thread, no code exists and
//    nothing is stored anywhere: some people want to help once and then be left alone.
// 3. **One switch stops all of it.** `ProjectSharing` gates every write this app makes, the thumbs and
//    the wishes included, and the donation with them. Off means nothing leaves the device. Reading
//    stays, because a roadmap held back for privacy helps nobody.
// 4. **The status is read, never invented.** Arrived, read, being worked on, fixed in a version: each
//    comes from the issue itself. There is no "we are looking into it" that nobody is doing.

/// Where a reported problem stands. The same words both platforms show, from the same bytes.
public enum ProjectReportStatus: String, Codable, Sendable, CaseIterable {
    /// It is in, and nobody has touched it yet. Said plainly rather than dressed up.
    case arrived
    /// Somebody has been there: the issue carries a label that the app did not put on it.
    case read
    case working
    case fixed
    case notPlanned
}

/// One line of the conversation. `mine` is the reporter's own, which the service marks, because both
/// voices are written by the same token and an answer that reads as a question is worse than silence.
public struct ProjectReportMessage: Codable, Sendable, Equatable, Identifiable {
    public let mine: Bool
    public let text: String
    public let at: Date?

    public var id: String { "\(at?.timeIntervalSince1970 ?? 0)-\(mine)-\(text.prefix(24))" }

    public init(mine: Bool, text: String, at: Date?) {
        self.mine = mine
        self.text = text
        self.at = at
    }
}

/// A reported problem as the reporter may see it: their own, and nothing else.
public struct ProjectThread: Sendable, Equatable {
    public let status: ProjectReportStatus
    public let fixedIn: String?
    /// The public issue this became, once the owner published it. Written privately, never the other
    /// way round: the public issue carries no code and no link back.
    public let publicNumber: Int?
    public let messages: [ProjectReportMessage]

    public init(status: ProjectReportStatus, fixedIn: String? = nil, publicNumber: Int? = nil,
                messages: [ProjectReportMessage] = []) {
        self.status = status
        self.fixedIn = fixedIn
        self.publicNumber = publicNumber
        self.messages = messages
    }
}

/// What this installation has reported, so the screen can list it with no network, and so the daily
/// check knows what it saw last time. Preferences, not the database: it is not the wearer's data.
public struct ProjectReportStore: Sendable {
    public static let reportsDefault = "projectReports"

    /// One remembered report. `seenStatus` and `seenMessages` are what was last shown to the reporter:
    /// the difference against a fresh read is exactly what is worth a notification, and nothing else is.
    public struct Entry: Codable, Sendable, Equatable, Identifiable {
        public let code: String
        public var title: String
        public var sent: Date
        public var seenStatus: ProjectReportStatus
        public var seenMessages: Int

        public var id: String { code }

        public init(code: String, title: String, sent: Date,
                    seenStatus: ProjectReportStatus = .arrived, seenMessages: Int = 0) {
            self.code = code
            self.title = title
            self.sent = sent
            self.seenStatus = seenStatus
            self.seenMessages = seenMessages
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public static let standard = ProjectReportStore()

    public func all() -> [Entry] {
        guard let data = defaults.data(forKey: Self.reportsDefault),
              let rows = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return rows.sorted { $0.sent > $1.sent }
    }

    public func entry(code: String) -> Entry? { all().first { $0.code == code } }

    /// Adding the same code twice keeps the first: a code is handed out once, and a second add would
    /// mean the app asked twice for the same report.
    public func add(_ entry: Entry) {
        var rows = all()
        guard !rows.contains(where: { $0.code == entry.code }) else { return }
        rows.append(entry)
        write(rows)
    }

    public func remove(code: String) {
        write(all().filter { $0.code != code })
    }

    /// Record what the reporter has now seen. Returns true when this was NEW to them, which is the one
    /// question a notification should ever be based on: the status moved, or the owner said something.
    @discardableResult
    public func seen(code: String, status: ProjectReportStatus, messages: Int) -> Bool {
        var rows = all()
        guard let at = rows.firstIndex(where: { $0.code == code }) else { return false }
        let changed = rows[at].seenStatus != status || messages > rows[at].seenMessages
        rows[at].seenStatus = status
        rows[at].seenMessages = max(messages, rows[at].seenMessages)
        write(rows)
        return changed
    }

    private func write(_ rows: [Entry]) {
        guard let data = try? JSONEncoder().encode(rows) else { return }
        defaults.set(data, forKey: Self.reportsDefault)
    }
}

/// The one switch over everything this app sends: thumbs, wishes, reports, replies and the raw
/// donation. On by default, because a project page nobody can answer on is half a page.
///
/// It is read in exactly one place, `ProjectService.endpoint`, so a new call site cannot forget it.
public struct ProjectSharing: Sendable {
    public static let enabledDefault = "projectSharingEnabled"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public static let standard = ProjectSharing()

    public var isOn: Bool {
        defaults.object(forKey: Self.enabledDefault) as? Bool ?? true
    }

    public func set(_ on: Bool) { defaults.set(on, forKey: Self.enabledDefault) }
}

/// What came back from sending a report. The failure carries its reason, because the screen has to
/// say which of them it was: see `ProjectWriteFailure`.
public enum ProjectReportResult: Equatable, Sendable {
    /// Sent, with the code when one was asked for. No code means it went without a thread.
    case sent(code: String?)
    case failed(ProjectWriteFailure)
}

extension ProjectService {
    public static let maximumReport = 2000
    public static let maximumReply = 1000
    /// What the service will take for one redacted bundle. Checked here as well, so an oversized log
    /// is refused before it is uploaded rather than after.
    public static let maximumLogBytes = 4 * 1024 * 1024

    /// Send a problem. `wantsThread` false means no code, no thread and nothing stored: the reporter
    /// gets no way back, which is the point of asking for it.
    public func report(text: String, wantsThread: Bool = true,
                       language: String = ProjectService.currentLanguage) async -> ProjectReportResult {
        guard let service = endpoint else { return .failed(.notSending) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= ProjectService.maximumReport else {
            return .failed(.refused)
        }
        let body: [String: Any] = ["text": trimmed, "key": deviceKey(), "lang": language,
                                   "thread": wantsThread]
        // One call, switched over: an early draft asked twice to get at the reason, which would have
        // filed the report twice whenever the first one worked.
        switch await ask(service.appendingPathComponent("v1/report"), body: body) {
        case .not(let why):
            return .failed(why)
        case .taken(let root):
            guard root["ok"] as? Bool == true else { return .failed(.refused) }
            return .sent(code: root["code"] as? String)
        }
    }

    /// The thread behind a code. A wrong or withdrawn code answers the same way, so this cannot be
    /// used to find out which codes exist.
    public func thread(code: String) async -> ProjectThread? {
        guard let service = endpoint, ProjectService.isReportCode(code) else { return nil }
        var request = URLRequest(url: service.appendingPathComponent("v1/report"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "code", value: code)]
        guard let url = components?.url else { return nil }
        request.url = url
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await perform(request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        let status = ProjectReportStatus(rawValue: root["status"] as? String ?? "") ?? .arrived
        let rows = (root["messages"] as? [[String: Any]]) ?? []
        return ProjectThread(
            status: status,
            fixedIn: root["fixedIn"] as? String,
            publicNumber: (root["publicNumber"] as? NSNumber)?.intValue,
            messages: rows.compactMap { row in
                guard let text = row["text"] as? String, !text.isEmpty else { return nil }
                return ProjectReportMessage(mine: row["mine"] as? Bool ?? false,
                                            text: text,
                                            at: ProjectService.date(from: row["at"] as? String))
            })
    }

    /// The reporter answering a question.
    public func reply(code: String, text: String) async -> ProjectServiceResult {
        guard let service = endpoint else { return .failed(.notSending) }
        guard ProjectService.isReportCode(code) else { return .refused }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= ProjectService.maximumReply else { return .refused }
        return await post(service.appendingPathComponent("v1/report/reply"),
                          body: ["code": code, "text": trimmed, "key": deviceKey()])
    }

    /// Taking it back: the log is deleted, the thread closed, the code stops working.
    public func withdraw(code: String) async -> ProjectServiceResult {
        guard let service = endpoint else { return .failed(.notSending) }
        guard ProjectService.isReportCode(code) else { return .refused }
        return await post(service.appendingPathComponent("v1/report/withdraw"), body: ["code": code])
    }

    /// The redacted bundle, by the same two steps the donation uses: ask where, then put it there.
    public func sendLog(code: String, data: Data) async -> ProjectServiceResult {
        guard let service = endpoint else { return .failed(.notSending) }
        guard ProjectService.isReportCode(code) else { return .refused }
        guard !data.isEmpty, data.count <= ProjectService.maximumLogBytes else { return .refused }
        let asked = await ask(service.appendingPathComponent("v1/report-log-url"),
                              body: ["code": code, "bytes": data.count])
        guard case .taken(let root) = asked else {
            guard case .not(let why) = asked else { return .failed(.unreachable) }
            return .failed(why)
        }
        guard let target = ProjectFeedParser.service(from: root["url"]) else { return .refused }
        var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 120)
        request.httpMethod = "PUT"
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        guard let (_, response) = try? await perform(request, body: data),
              let http = response as? HTTPURLResponse else { return .failed(.unreachable) }
        guard (200...299).contains(http.statusCode) else {
            return .failed(ProjectService.failure(status: http.statusCode))
        }
        return .sent(count: nil)
    }

    /// Four groups of four, from the service's own alphabet. Checked before every call so a mistyped
    /// code never becomes a request.
    public static func isReportCode(_ code: String) -> Bool {
        let groups = code.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.count == 4 else { return false }
        let allowed = Set("23456789ABCDEFGHJKLMNPQRSTUVWXYZ")
        return groups.allSatisfy { $0.count == 4 && $0.allSatisfy { allowed.contains($0) } }
    }

    /// The reporter's language, so the owner's answers can come back in it.
    public static var currentLanguage: String {
        String((Locale.preferredLanguages.first ?? "en").prefix(2)).lowercased()
    }

    static func date(from iso: String?) -> Date? {
        guard let iso else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}
