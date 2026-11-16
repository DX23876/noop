import Foundation
import StrandCore

/// The Roadmap page for Android: the same two files, read and clamped by the same core code the Apple
/// apps call, so the two platforms cannot disagree about a status word, a date or a dropped item.
///
/// The wire shape is written out by hand rather than encoding `ProjectPage` directly, for one reason:
/// dates. `JSONEncoder` would hand Kotlin a reference-date double, which is a second format to agree
/// about. These are ISO strings, the same ones the files carry.
enum CoreProject {

    /// `project.page` reads the files and keeps the copy; `project.cached` answers from disk only, for
    /// the first frame of the screen; `project.vote`, `project.suggest` and `project.counts` are the two
    /// writes and their totals. Returns nil for an op this file does not own.
    ///
    /// The service address always comes from the page that was read, never from an argument: a screen
    /// cannot talk the core into posting somewhere else.
    static func run(_ op: String, _ args: [String: Any]) async -> String? {
        let store = ProjectPageStore(directory: cacheDirectory)
        switch op {
        case "project.cached": return CoreRead.json(Wire(await store.cached()))
        case "project.page": return CoreRead.json(Wire(await store.refresh()))
        case "project.vote":
            let page = await store.cached()
            guard let id = args["id"] as? String else { return #"{"ok":false}"# }
            let service = ProjectService(service: page.service)
            let result = await service.vote(id: id, on: args["on"] as? Bool ?? true)
            if case .sent(let count) = result {
                struct Answer: Encodable { let ok: Bool; let count: Int?; let voted: Bool }
                return CoreRead.json(Answer(ok: true, count: count,
                                            voted: ProjectDeviceKeyStore.standard.hasVoted(id)))
            }
            return #"{"ok":false}"#
        case "project.suggest":
            let page = await store.cached()
            let service = ProjectService(service: page.service)
            let result = await service.suggest(text: args["text"] as? String ?? "")
            if case .sent = result { return #"{"ok":true}"# }
            return #"{"ok":false}"#
        case "project.report":
            let page = await store.cached()
            let service = ProjectService(service: page.service)
            let result = await service.report(text: args["text"] as? String ?? "",
                                              wantsThread: args["thread"] as? Bool ?? true,
                                              language: args["lang"] as? String
                                                  ?? ProjectService.currentLanguage)
            if case .sent(let code) = result {
                // Remembered here, in the core, so both platforms keep the same list in the same place.
                if let code, let title = args["text"] as? String {
                    ProjectReportStore.standard.add(.init(code: code, title: Wire.firstLine(title),
                                                          sent: Date()))
                }
                struct Answer: Encodable { let ok: Bool; let code: String? }
                return CoreRead.json(Answer(ok: true, code: code))
            }
            return #"{"ok":false}"#
        case "project.reports":
            struct Row: Encodable {
                let code: String, title: String, sent: String, seenStatus: String, seenMessages: Int
            }
            return CoreRead.json(["reports": ProjectReportStore.standard.all().map {
                Row(code: $0.code, title: $0.title, sent: Wire.iso($0.sent),
                    seenStatus: $0.seenStatus.rawValue, seenMessages: $0.seenMessages)
            }])
        case "project.thread":
            let page = await store.cached()
            let code = args["code"] as? String ?? ""
            guard let thread = await ProjectService(service: page.service).thread(code: code) else {
                return #"{"ok":false}"#
            }
            // Reading the thread IS seeing it: anything new here has now been shown.
            let isNew = ProjectReportStore.standard.seen(code: code, status: thread.status,
                                                         messages: thread.messages.count)
            struct Message: Encodable { let mine: Bool; let text: String; let at: String? }
            struct Answer: Encodable {
                let ok: Bool, status: String, fixedIn: String?, publicNumber: Int?, isNew: Bool
                let messages: [Message]
            }
            return CoreRead.json(Answer(
                ok: true, status: thread.status.rawValue, fixedIn: thread.fixedIn,
                publicNumber: thread.publicNumber, isNew: isNew,
                messages: thread.messages.map { Message(mine: $0.mine, text: $0.text,
                                                        at: $0.at.map(Wire.iso)) }))
        case "project.reportLog":
            // The bytes come over as base64 because the bridge carries JSON. The app has already shown
            // the wearer exactly what is in this bundle; the core never builds or opens it.
            let page = await store.cached()
            guard let encoded = args["data"] as? String,
                  let data = Data(base64Encoded: encoded) else { return #"{"ok":false}"# }
            let result = await ProjectService(service: page.service)
                .sendLog(code: args["code"] as? String ?? "", data: data)
            if case .sent = result { return #"{"ok":true}"# }
            return #"{"ok":false}"#
        case "project.reply":
            let page = await store.cached()
            let result = await ProjectService(service: page.service)
                .reply(code: args["code"] as? String ?? "", text: args["text"] as? String ?? "")
            if case .sent = result { return #"{"ok":true}"# }
            return #"{"ok":false}"#
        case "project.withdraw":
            let page = await store.cached()
            let code = args["code"] as? String ?? ""
            let result = await ProjectService(service: page.service).withdraw(code: code)
            if case .sent = result {
                ProjectReportStore.standard.remove(code: code)
                return #"{"ok":true}"#
            }
            return #"{"ok":false}"#
        case "project.codeOk":
            // What a code looks like is one fact, and it lives here. A screen that wants to grey out
            // its own button must not carry a second copy of the alphabet to decide with.
            return CoreRead.json(["ok": ProjectService.isReportCode(args["code"] as? String ?? "")])
        case "project.sharing":
            // One switch, read and written through the core, so the two platforms cannot drift on
            // what "off" means or where it is kept.
            if let on = args["on"] as? Bool { ProjectSharing.standard.set(on) }
            return CoreRead.json(["on": ProjectSharing.standard.isOn])
        case "project.counts":
            let page = await store.cached()
            return CoreRead.json(["counts": await ProjectService(service: page.service).counts()])
        default: return nil
        }
    }

    /// Android sets HOME to the app's own directory (`core.setResources`), so the cache lands beside the
    /// coach's files rather than in a path the process cannot write.
    static var cacheDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("ProjectPage", isDirectory: true)
    }

    struct Wire: Encodable {
        struct Item: Encodable {
            let id: String, phase: String, title: String, line: String, icon: String, area: String
            let since: String?
        }
        struct Issue: Encodable {
            let n: Int, title: String, status: String
            let opened: String?, closed: String?, fixedIn: String?
        }
        struct Suggestion: Encodable {
            let id: String, title: String, detail: String, status: String
            let reply: String?, roadmap: String?
        }
        let roadmap: [Item]
        let suggestions: [Suggestion]
        let reported: [Issue]
        let fixed: [Issue]
        let decided: [Issue]
        let reportedCount: Int
        let workingCount: Int
        let generated: String?
        let fetchedAt: String?
        let service: String?
        /// What THIS installation has voted for, so the Android screen draws its own thumbs with no
        /// network, exactly as the Apple screens do.
        let voted: [String]

        init(_ page: ProjectPage) {
            roadmap = page.roadmap.map {
                Item(id: $0.id, phase: $0.phase.rawValue, title: $0.title, line: $0.line,
                     icon: $0.icon, area: $0.area.rawValue, since: $0.since)
            }
            suggestions = page.suggestions.map {
                Suggestion(id: $0.id, title: $0.title, detail: $0.detail, status: $0.status.rawValue,
                           reply: $0.reply, roadmap: $0.roadmapID)
            }
            reported = page.reported.map(Wire.issue)
            fixed = page.fixed.map(Wire.issue)
            decided = page.decided.map(Wire.issue)
            reportedCount = page.reportedCount
            workingCount = page.workingCount
            generated = page.generated.map(Wire.iso)
            fetchedAt = page.fetchedAt.map(Wire.iso)
            service = page.service?.absoluteString
            voted = ProjectDeviceKeyStore.standard.votedItems().sorted()
        }

        static func issue(_ issue: ProjectIssue) -> Issue {
            Issue(n: issue.number, title: issue.title, status: issue.status.rawValue,
                  opened: issue.opened, closed: issue.closed, fixedIn: issue.fixedIn)
        }

        /// The title a remembered report is listed under: the reporter's own first line, bounded.
        static func firstLine(_ text: String) -> String {
            let line = text.split(separator: "\n").first.map(String.init) ?? text
            return String(line.trimmingCharacters(in: .whitespaces).prefix(80))
        }

        static func iso(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.string(from: date)
        }
    }
}
