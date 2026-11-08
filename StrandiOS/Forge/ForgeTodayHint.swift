#if os(iOS)
import Foundation

/// The one hint under Today's rings, as Liquid Today's Momentum line shows it: the most pressing thing the
/// day holds, chosen once here so the hint and the timeline never show the same fact twice. The rest of the
/// candidates stay one tap away under the hint.
struct ForgeTodayHint: Identifiable, Equatable {
    enum Source: Equatable {
        case notice(ForgeTimeline.Notice)
        case coach(entryId: String)
        case proposal
        case weighIn
    }

    let id: String
    let source: Source
    let title: String
    let detail: String?

    /// The day's candidates, most pressing first: a raised warning, a plan waiting for an answer, the newest
    /// coach note, the other notices (care before news), then a missing weigh-in. Dismissed ones are left out.
    static func candidates(today entries: [ForgeTimeline.Entry], proposal: Bool, weighIn: Bool,
                           dismissed: Set<String>) -> [ForgeTodayHint] {
        let notices = entries.compactMap { entry -> (ForgeTimeline.Entry, ForgeTimeline.Notice)? in
            entry.notice.map { (entry, $0) }
        }
        func notice(_ pair: (ForgeTimeline.Entry, ForgeTimeline.Notice)) -> ForgeTodayHint {
            ForgeTodayHint(id: pair.0.id, source: .notice(pair.1), title: pair.1.headline,
                           detail: pair.1.detail.isEmpty ? nil : pair.1.detail)
        }
        let toneRank: [ForgeTimeline.Notice.Tone: Int] = [.critical: 0, .caution: 1, .neutral: 2, .positive: 3]
        var out: [ForgeTodayHint] = []
        out += notices.filter { $0.1.tone == .critical }.sorted { $0.0.date > $1.0.date }.map(notice)
        if proposal {
            out.append(ForgeTodayHint(id: "hint.proposal", source: .proposal,
                                      title: String(localized: "A suggestion waits for your answer"), detail: nil))
        }
        let coach = entries.filter { if case .coach = $0.kind { return true } else { return false } }
            .sorted { $0.date > $1.date }
        out += coach.prefix(1).map {
            ForgeTodayHint(id: $0.id, source: .coach(entryId: $0.id), title: $0.title,
                           detail: $0.detail.isEmpty ? nil : $0.detail)
        }
        out += notices.filter { $0.1.tone != .critical }
            .sorted { (toneRank[$0.1.tone] ?? 9, -$0.0.date.timeIntervalSince1970) < (toneRank[$1.1.tone] ?? 9, -$1.0.date.timeIntervalSince1970) }
            .map(notice)
        if weighIn {
            out.append(ForgeTodayHint(id: "hint.weighIn", source: .weighIn,
                                      title: String(localized: "No weigh-in for a week"),
                                      detail: String(localized: "Your weight goal needs one now and then.")))
        }
        return out.filter { !dismissed.contains($0.id) }
    }

    /// The dismissed hints of `day` from their stored form ("day|id" lines); other days' lines are ignored.
    static func dismissed(_ raw: String, day: String) -> Set<String> {
        Set(raw.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: "|", maxSplits: 1)
            return parts.count == 2 && parts[0] == day ? String(parts[1]) : nil
        })
    }

    /// `raw` with `id` dismissed for `day`, keeping only that day's lines so the store never grows.
    static func dismissing(_ id: String, day: String, in raw: String) -> String {
        let kept = raw.split(separator: "\n").filter { $0.hasPrefix("\(day)|") }.map(String.init)
        return (kept + ["\(day)|\(id)"]).joined(separator: "\n")
    }
}
#endif
