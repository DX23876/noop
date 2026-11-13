import Foundation

/// A strap heard during a scan: the stable handle the platform reconnects by (an address on Android, a
/// peripheral identifier on Apple), the advertised name and the last signal strength.
public struct HeardStrap: Equatable, Sendable, Codable {
    public let address: String
    public let name: String?
    public let rssi: Int

    public init(address: String, name: String?, rssi: Int) {
        self.address = address
        self.name = name
        self.rssi = rssi
    }
}

/// What a scan may do with what it heard while the app's WHOOP entry carries no strap of its own.
public struct StrapChoice: Equatable, Sendable {
    public enum Verdict: String, Sendable, Codable {
        /// One strap, so it is the wearer's: connect to `address`.
        case connect
        /// Several straps are in earshot and nothing says which belongs to this wearer: ask.
        case ask
        /// Nothing usable yet; keep scanning.
        case keepLooking
    }

    public let verdict: Verdict
    public let address: String?
    /// The straps to offer, strongest signal first. Empty unless the verdict is `ask`.
    public let choices: [HeardStrap]

    public init(verdict: Verdict, address: String? = nil, choices: [HeardStrap] = []) {
        self.verdict = verdict
        self.address = address
        self.choices = choices
    }
}

/// Which strap a scan connects to before the wearer has named one.
///
/// Until 2026-11-13 both apps took the FIRST WHOOP that advertised, and the first connect then stamped
/// that strap's address onto the WHOOP entry for good (`SourceCoordinator` identity adoption). In a
/// household with two straps that is a coin toss, and the loser cannot be undone from the Devices screen:
/// the entry holds a stranger's address and refuses to overwrite it with another strap. A tester paired
/// his wife's WHOOP 5 that way and could not reach his own 4.0 at all.
///
/// So an entry with no strap of its own does not decide on one advertisement. The host listens for
/// [listenMilliseconds], then asks here. One strap is still connected without a question, which keeps the
/// ordinary single-strap first run exactly as it was; two or more are handed to the wearer to choose
/// from, because nothing in an advertisement says whose strap it is. A strap the entry already names is
/// never a choice: that claim was made by the wearer and the scan only confirms it.
public enum StrapClaim {
    /// How long a host collects advertisements before asking. Long enough for a second strap in the same
    /// room to advertise at least once (WHOOP advertises several times a second), short enough that the
    /// ordinary first run does not feel stalled.
    public static let listenMilliseconds = 4_000

    /// The heard straps with one entry per address (addresses are compared without case, as SQLite's own
    /// `peripheralId` reads are), strongest signal first. An address keeps the spelling it was first heard
    /// in, which is the one the host has in hand, and gains the strongest signal and any name that arrived
    /// later: a scan record can carry the address on every advertisement and the local name on only some.
    public static func distinct(_ heard: [HeardStrap]) -> [HeardStrap] {
        var order: [String] = []
        var best: [String: HeardStrap] = [:]
        for strap in heard {
            let key = strap.address.lowercased()
            guard let seen = best[key] else {
                order.append(key)
                best[key] = strap
                continue
            }
            best[key] = HeardStrap(address: seen.address, name: seen.name ?? strap.name,
                                   rssi: max(seen.rssi, strap.rssi))
        }
        // Swift's sort is not stable, so equal signals fall back to the order they were first heard in
        // rather than to whatever the sort happens to do: a list that reshuffles under the wearer's
        // finger is its own bug.
        return order.compactMap { best[$0] }.enumerated()
            .sorted { $0.element.rssi == $1.element.rssi ? $0.offset < $1.offset : $0.element.rssi > $1.element.rssi }
            .map(\.element)
    }

    /// The verdict for what a scan heard. [claimed] is the strap the active WHOOP entry already names, or
    /// nil while it names none.
    public static func choose(heard: [HeardStrap], claimed: String?) -> StrapChoice {
        let straps = distinct(heard)
        if let claimed, !claimed.isEmpty {
            // The wearer already named this strap. Hearing others changes nothing, and hearing the named
            // one is simply the reconnect the entry exists for.
            guard let mine = straps.first(where: { $0.address.caseInsensitiveCompare(claimed) == .orderedSame })
            else { return StrapChoice(verdict: .keepLooking) }
            return StrapChoice(verdict: .connect, address: mine.address)
        }
        switch straps.count {
        case 0: return StrapChoice(verdict: .keepLooking)
        case 1: return StrapChoice(verdict: .connect, address: straps[0].address)
        default: return StrapChoice(verdict: .ask, choices: straps)
        }
    }
}
