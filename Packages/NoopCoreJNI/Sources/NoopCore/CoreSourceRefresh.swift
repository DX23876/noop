import Foundation
import StrandCore

/// Android's way to the pull gesture's rules (`ConnectedSourceRefresh` in StrandCore): who may be asked,
/// how often, and what one line says about several answers.
///
/// Nothing is decided here. This translates the shell's JSON into the shared rule's types and the rule's
/// answer back, so Kotlin holds no second copy of a rule the iPhone also follows — the fork's "logic in
/// the core, never in Kotlin".
enum CoreSourceRefresh {

    /// `{"askable":["health","hevy"]}`
    private struct AskableReply: Encodable { let askable: [String] }

    /// `{"verdict":"partial","brought":2,"failed":["hevy"]}`; `total` only for `brought`, and the two
    /// optional members are left out of the JSON when they do not apply.
    private struct VerdictReply: Encodable {
        let verdict: String
        var total: Int?
        var brought: Int?
        var failed: [String]?
    }

    static func run(_ op: String, _ args: [String: Any]) -> String? {
        switch op {
        case "refresh.askable": return askable(args)
        case "refresh.verdict": return verdict(args)
        default: return nil
        }
    }

    private static func askable(_ args: [String: Any]) -> String {
        let connected = Set((args["connected"] as? [String] ?? [])
            .compactMap(ConnectedSourceRefresh.Source.init(rawValue:)))
        var lastAsked: [ConnectedSourceRefresh.Source: Int] = [:]
        for (key, value) in (args["lastAsked"] as? [String: Any] ?? [:]) {
            guard let source = ConnectedSourceRefresh.Source(rawValue: key) else { continue }
            // JSON numbers arrive as Int or Double depending on the bridge; take either.
            if let stamp = value as? Int { lastAsked[source] = stamp }
            else if let stamp = value as? Double { lastAsked[source] = Int(stamp) }
        }
        let now = (args["now"] as? Int) ?? Int(Date().timeIntervalSince1970)
        let allowed = ConnectedSourceRefresh.askable(connected: connected, lastAsked: lastAsked, now: now)
        return CoreRead.json(AskableReply(askable: allowed.map(\.rawValue).sorted()))
    }

    private static func verdict(_ args: [String: Any]) -> String {
        let answers: [ConnectedSourceRefresh.Answer] = (args["answers"] as? [[String: Any]] ?? [])
            .compactMap { row in
                guard let raw = row["source"] as? String,
                      let source = ConnectedSourceRefresh.Source(rawValue: raw) else { return nil }
                // A missing "brought" means the source cannot count what it fetched, which is not the
                // same as fetching nothing.
                return ConnectedSourceRefresh.Answer(source: source,
                                                     brought: row["brought"] as? Int,
                                                     failed: row["failed"] as? Bool ?? false)
            }
        switch ConnectedSourceRefresh.verdict(answers) {
        case nil:
            return CoreRead.json(VerdictReply(verdict: "none"))
        case .upToDate:
            return CoreRead.json(VerdictReply(verdict: "upToDate"))
        case .refreshed:
            return CoreRead.json(VerdictReply(verdict: "refreshed"))
        case .brought(let total):
            return CoreRead.json(VerdictReply(verdict: "brought", total: total))
        case .partial(let failed, let brought):
            return CoreRead.json(VerdictReply(verdict: "partial", brought: brought,
                                              failed: failed.map(\.rawValue).sorted()))
        }
    }
}
