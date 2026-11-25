import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// ProjectFeed.swift — the data behind the in-app Roadmap page, for both platforms.
//
// The page reads two static files from the repository: `docs/roadmap.json`, written by hand, and
// `docs/app-feed.json`, generated from the issues by `Tools/build_app_feed.py`. Nothing about the
// reader is sent, there is no account, and the read happens when the page is opened, never on its own.
//
// Everything here is shared: Android reaches it through NoopCoreJNI, the Apple apps call it directly, so
// the two platforms cannot disagree about what a status word means or how a title is clamped.
//
// The file arrives over the network, and an installed app may read a file written by a much later
// version of the generator, so this layer trusts nothing: unknown phases, areas and statuses drop the
// item instead of failing the page, text is clamped and stripped of control characters a second time,
// and a `service` URL that is not https is discarded rather than honoured.

/// Where a roadmap item sits. The file's order inside a phase is the screen's order (there is no rank
/// and no weight, so re-sorting is a text edit and nothing can contradict the file).
public enum ProjectPhase: String, Codable, Sendable, CaseIterable {
    case now, next, later
}

/// Which measure a roadmap item belongs to. The screens tint a card from this, so the page stays
/// consistent inside the wearer's chosen colour profile instead of turning into a rainbow.
public enum ProjectArea: String, Codable, Sendable, CaseIterable {
    case sleep, cardio, strength, body, app
}

/// One planned piece of work, as the owner wrote it.
public struct ProjectRoadmapItem: Equatable, Sendable, Identifiable {
    public let id: String
    public let phase: ProjectPhase
    public let title: String
    public let line: String
    /// An SF Symbol name. The Android screen maps it; `Tools/check_roadmap.py` fails when a name used
    /// here has no counterpart there, because the alternative is a card that silently draws nothing.
    public let icon: String
    public let area: ProjectArea
    /// `yyyy-MM-dd`, only on a `now` item, for "in progress since".
    public let since: String?

    public init(id: String, phase: ProjectPhase, title: String, line: String, icon: String,
                area: ProjectArea, since: String? = nil) {
        self.id = id
        self.phase = phase
        self.title = title
        self.line = line
        self.icon = icon
        self.area = area
        self.since = since
    }
}

/// One reported problem, reduced to what a screen may show: number, title, state, dates, version.
/// There is deliberately no body, no handle and no avatar — a bug report carries logs and device
/// details, and a title is the only part written to be read by other people.
public struct ProjectIssue: Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case reported, working, fixed, notPlanned
    }

    public let number: Int
    public let title: String
    public let status: Status
    public let opened: String?
    public let closed: String?
    public let fixedIn: String?

    public var id: Int { number }

    public init(number: Int, title: String, status: Status, opened: String? = nil,
                closed: String? = nil, fixedIn: String? = nil) {
        self.number = number
        self.title = title
        self.status = status
        self.opened = opened
        self.closed = closed
        self.fixedIn = fixedIn
    }
}


/// One suggestion a wearer sent in, as the owner released it.
///
/// The text is someone else's, so it reaches a screen only after the owner let it through (the generator
/// takes none without the release label), and the app clamps it again on arrival. `reply` is the owner's
/// own answer, taken from the issue; `status` is what they decided. `id` is the vote anchor and comes
/// from the file, never built here: the app must not invent an id the service would reject.
public struct ProjectSuggestion: Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case open, planned, maybe, notPlanned, done
    }

    public let id: String
    public let title: String
    public let detail: String
    public let status: Status
    public let reply: String?
    /// Set once it became a roadmap item, so the card can say so instead of the suggestion vanishing.
    public let roadmapID: String?

    public init(id: String, title: String, detail: String, status: Status,
                reply: String? = nil, roadmapID: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.reply = reply
        self.roadmapID = roadmapID
    }
}

/// The whole page in one value: the roadmap, the issue lists, and when this was last read. A screen
/// renders this and nothing else, so an empty page and a stale page are the same shape.
public struct ProjectPage: Equatable, Sendable {
    public var roadmap: [ProjectRoadmapItem]
    public var suggestions: [ProjectSuggestion]
    public var reported: [ProjectIssue]
    public var fixed: [ProjectIssue]
    public var decided: [ProjectIssue]
    /// When the generator last wrote the issue file, not when the app read it.
    public var generated: Date?
    /// When this copy was fetched. Nil means it came from nowhere (first run, no network ever).
    public var fetchedAt: Date?
    /// The base URL of the project's service, once there is one. Absent means the app hides voting and
    /// the suggestion field rather than pointing at a dead endpoint, which is how an installed build
    /// from a year ago is supposed to behave.
    public var service: URL?

    public static let empty = ProjectPage(roadmap: [], suggestions: [], reported: [], fixed: [],
                                          decided: [], generated: nil, fetchedAt: nil, service: nil)

    public init(roadmap: [ProjectRoadmapItem], suggestions: [ProjectSuggestion] = [],
                reported: [ProjectIssue], fixed: [ProjectIssue],
                decided: [ProjectIssue], generated: Date?, fetchedAt: Date?, service: URL?) {
        self.roadmap = roadmap
        self.suggestions = suggestions
        self.reported = reported
        self.fixed = fixed
        self.decided = decided
        self.generated = generated
        self.fetchedAt = fetchedAt
        self.service = service
    }

    /// The items of one phase, in file order.
    public func items(_ phase: ProjectPhase) -> [ProjectRoadmapItem] {
        roadmap.filter { $0.phase == phase }
    }

    /// True when there is nothing at all to draw, which is the only case a screen has to explain.
    public var isEmpty: Bool {
        roadmap.isEmpty && suggestions.isEmpty && reported.isEmpty && fixed.isEmpty && decided.isEmpty
    }

    /// How many problems are reported and how many are being worked on, for the one quiet summary line.
    public var reportedCount: Int { reported.filter { $0.status == .reported }.count }
    public var workingCount: Int { reported.filter { $0.status == .working }.count }
}

/// Parsing both files. Pure and total: it never throws and never returns a partially trusted value, it
/// drops what it cannot read.
public enum ProjectFeedParser {
    public static let maximumTitle = 120
    public static let maximumLine = 160
    public static let maximumItems = 60

    /// Plain text a screen can render: one line, no control characters, bounded length.
    public static func clamp(_ text: String, limit: Int) -> String {
        var cleaned = String(text.unicodeScalars.map { scalar -> Character in
            scalar.properties.isDefaultIgnorableCodePoint || scalar.value < 0x20 || scalar.value == 0x7f
                ? " " : Character(scalar)
        })
        cleaned = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if cleaned.count > limit {
            cleaned = String(cleaned.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return cleaned
    }

    /// `docs/roadmap.json`. An item with an unknown phase or area is dropped: a reader from an older
    /// build must show the items it understands rather than an empty page.
    public static func roadmap(from data: Data) -> [ProjectRoadmapItem] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = root["items"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var out: [ProjectRoadmapItem] = []
        for row in rows.prefix(maximumItems) {
            guard let id = row["id"] as? String, !id.isEmpty, !seen.contains(id),
                  let phase = (row["phase"] as? String).flatMap(ProjectPhase.init(rawValue:)),
                  let area = (row["area"] as? String).flatMap(ProjectArea.init(rawValue:)),
                  let icon = row["icon"] as? String, !icon.isEmpty,
                  let rawTitle = row["title"] as? String else { continue }
            let title = clamp(rawTitle, limit: maximumTitle)
            guard !title.isEmpty else { continue }
            seen.insert(id)
            let since = phase == .now ? (row["since"] as? String) : nil
            out.append(ProjectRoadmapItem(id: id, phase: phase, title: title,
                                          line: clamp(row["line"] as? String ?? "", limit: maximumLine),
                                          icon: icon, area: area, since: since))
        }
        return out
    }

    /// `docs/app-feed.json`. `fetchedAt` is the caller's clock, never the file's, so a screen that shows
    /// "last checked" cannot be fooled by a wrong timestamp in a file.
    public static func feed(from data: Data, fetchedAt: Date?) -> ProjectPage {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .empty
        }
        let issues = (root["issues"] as? [[String: Any]] ?? []).compactMap(issue(from:))
        let fixed = (root["fixed"] as? [[String: Any]] ?? []).compactMap(issue(from:))
        let decided = (root["decided"] as? [[String: Any]] ?? []).compactMap(issue(from:))
        let suggestions = (root["suggestions"] as? [[String: Any]] ?? []).compactMap(suggestion(from:))
        return ProjectPage(roadmap: [],
                           suggestions: Array(suggestions.prefix(maximumItems)),
                           reported: Array(issues.prefix(maximumItems)),
                           fixed: Array(fixed.prefix(maximumItems)),
                           decided: Array(decided.prefix(maximumItems)),
                           generated: (root["generated"] as? String).flatMap(date(from:)),
                           fetchedAt: fetchedAt,
                           service: service(from: root["service"]))
    }

    /// Only https, and only a host-bearing URL. A file is a thing other people could one day serve, so
    /// an endpoint read out of one is checked before it is kept rather than after it was called.
    public static func service(from value: Any?) -> URL? {
        guard let string = value as? String, !string.isEmpty, let url = URL(string: string),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// A released suggestion. Someone else wrote the text, so it is clamped here as well as in the
    /// generator: an app from a year ago must stay readable whatever a later generator starts sending.
    static func suggestion(from row: [String: Any]) -> ProjectSuggestion? {
        guard let id = row["id"] as? String, !id.isEmpty,
              let rawTitle = row["title"] as? String,
              let status = (row["status"] as? String).flatMap(ProjectSuggestion.Status.init(rawValue:))
        else { return nil }
        let title = clamp(rawTitle, limit: maximumTitle)
        guard !title.isEmpty else { return nil }
        let reply = (row["reply"] as? String).map { clamp($0, limit: 400) }
        return ProjectSuggestion(id: id, title: title,
                                 detail: clamp(row["detail"] as? String ?? "", limit: 600),
                                 status: status,
                                 reply: (reply?.isEmpty ?? true) ? nil : reply,
                                 roadmapID: row["roadmap"] as? String)
    }

    static func issue(from row: [String: Any]) -> ProjectIssue? {
        guard let number = row["n"] as? Int, number > 0,
              let status = (row["status"] as? String).flatMap(ProjectIssue.Status.init(rawValue:)),
              let rawTitle = row["title"] as? String else { return nil }
        let title = clamp(rawTitle, limit: maximumTitle)
        guard !title.isEmpty else { return nil }
        return ProjectIssue(number: number, title: title, status: status,
                            opened: row["opened"] as? String, closed: row["closed"] as? String,
                            fixedIn: row["fixedIn"] as? String)
    }

    static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// The two files' canonical addresses. One copy for both platforms: a second copy is how an updater and
/// a screen end up disagreeing about which branch they read.
public struct ProjectFeedSources: Sendable {
    public let roadmap: URL
    public let feed: URL

    public init(roadmap: URL, feed: URL) {
        self.roadmap = roadmap
        self.feed = feed
    }

    public static let github = ProjectFeedSources(
        roadmap: URL(string: "https://raw.githubusercontent.com/DX23876/noop/main/docs/roadmap.json")!,
        feed: URL(string: "https://raw.githubusercontent.com/DX23876/noop/main/docs/app-feed.json")!)
}

/// Reads the two files, keeps the last good copy on disk, and hands a screen one value.
///
/// It never throws. A failed read is not an error state worth a screen of its own: the page shows the
/// last copy with the date it was fetched, which is also what it does with no network at all.
public actor ProjectPageStore {
    public static let maximumResponseBytes = 262_144

    private let sources: ProjectFeedSources
    private let cacheFile: URL
    private let fetch: @Sendable (URL) async throws -> Data

    public init(directory: URL, sources: ProjectFeedSources = .github,
                fetch: (@Sendable (URL) async throws -> Data)? = nil) {
        self.sources = sources
        self.cacheFile = directory.appendingPathComponent("project-page.json", isDirectory: false)
        self.fetch = fetch ?? { url in try await ProjectPageStore.read(url) }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The last copy that was read, or an empty page. Cheap: a screen may call this before it shows.
    public func cached() -> ProjectPage {
        guard let data = try? Data(contentsOf: cacheFile),
              let box = try? JSONDecoder().decode(CachedPage.self, from: data) else { return .empty }
        return box.page
    }

    /// The page a write should use: the cached copy when it already knows the service's address, else a
    /// fresh read. Writes used to take the cache alone, so a device whose cache was empty or predated the
    /// address told the wearer sending was switched off while the switch was on (tester report,
    /// 2026-11-24). A read that fails still returns the cache, and the write then says nothing answered.
    public func forWriting(now: Date = Date()) async -> ProjectPage {
        let page = cached()
        return page.service != nil ? page : await refresh(now: now)
    }

    /// Fetch both files and keep the result. Returns the cached page when the read fails, so a caller
    /// has one path and never has to decide what to show on an error.
    public func refresh(now: Date = Date()) async -> ProjectPage {
        async let roadmapData = try? fetch(sources.roadmap)
        async let feedData = try? fetch(sources.feed)
        guard let feedBytes = await feedData, let roadmapBytes = await roadmapData else {
            return cached()
        }
        var page = ProjectFeedParser.feed(from: feedBytes, fetchedAt: now)
        page.roadmap = ProjectFeedParser.roadmap(from: roadmapBytes)
        if page.isEmpty { return cached() }
        if let encoded = try? JSONEncoder().encode(CachedPage(page: page)) {
            try? encoded.write(to: cacheFile, options: .atomic)
        }
        return page
    }

    /// One read: no cookies, no cache, no redirect to another host, bounded size.
    static func read(_ url: URL, configuration: URLSessionConfiguration = .ephemeral) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= maximumResponseBytes else { throw ProjectFeedError.unreadable }
        return data
    }
}

public enum ProjectFeedError: String, Error {
    case unreadable
}

/// The on-disk shape of the cache. Separate from `ProjectPage` on purpose: the page is what screens
/// read, this is a storage format that may gain a version field without touching them.
struct CachedPage: Codable, Sendable {
    var schema = 1
    var page: ProjectPage
}

// MARK: - Codable for the cached page
//
// Hand-written rather than synthesised so the cache file stays readable and a field added to
// `ProjectPage` cannot silently change the format a shipped app wrote.

extension ProjectRoadmapItem: Codable {}
extension ProjectIssue: Codable {}
extension ProjectSuggestion: Codable {}

extension ProjectPage: Codable {
    enum CodingKeys: String, CodingKey {
        case roadmap, suggestions, reported, fixed, decided, generated, fetchedAt, service
    }
}
