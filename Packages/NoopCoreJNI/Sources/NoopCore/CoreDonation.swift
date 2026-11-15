import Foundation
import StrandCore

/// The raw-motion donation for Android: the same ticks, the same window plan, the same package and the
/// same upload the Apple apps use. Kotlin keeps the strap and the screen, as everywhere else in this
/// fork, and decides nothing about what is recorded or what is sent.
///
/// The pending donations live here rather than in Kotlin for one reason: a recording that is waiting for
/// its owner to decide is state both platforms have to treat identically, and two stores would be two
/// answers to "what is still unsent".
enum CoreDonation {

    static func run(_ op: String, _ args: [String: Any]) async -> String? {
        let settings = RawDonationSettings.standard
        switch op {
        case "donation.settings":
            struct Wire: Encodable {
                let sports: [String]
                let keepCopy: Bool
                let windowSeconds: Int
                let windowCount: Int
                let approximateBytes: Int
            }
            let plan = RawDonationPlan.windows(expected: 2700)
            return CoreRead.json(Wire(sports: settings.sports().sorted(),
                                      keepCopy: settings.keepsLocalCopy,
                                      windowSeconds: Int(RawDonationPlan.windowSeconds),
                                      windowCount: RawDonationPlan.windowCount,
                                      approximateBytes: RawDonationPlan.approximateBytes(plan)))
        case "donation.setSport":
            guard let sport = args["sport"] as? String else { return #"{"ok":false}"# }
            settings.set(sport, on: args["on"] as? Bool ?? false)
            return #"{"ok":true}"#
        case "donation.keepCopy":
            settings.keepsLocalCopy = args["on"] as? Bool ?? false
            return #"{"ok":true}"#
        case "donation.plan":
            // Nil for a sport nobody ticked: Kotlin arms nothing of its own accord.
            guard let sport = args["sport"] as? String,
                  let windows = settings.plan(for: sport,
                                              expected: (args["expected"] as? NSNumber)?.doubleValue ?? 2700)
            else { return "null" }
            struct Window: Encodable { let start: Double; let duration: Double }
            return CoreRead.json(windows.map { Window(start: $0.startOffset, duration: $0.duration) })
        case "donation.pending":
            return CoreRead.json(DonationBox.shared.all())
        case "donation.record":
            guard let sport = args["sport"] as? String,
                  let seconds = (args["seconds"] as? NSNumber)?.intValue, seconds >= 30 else {
                return #"{"ok":false}"#
            }
            let donation = PendingDonation(id: args["id"] as? String ?? UUID().uuidString,
                                           sport: sport, recordedSeconds: seconds,
                                           bytes: (args["bytes"] as? NSNumber)?.intValue ?? 0,
                                           strapFamily: args["family"] as? String ?? "unknown",
                                           firmware: args["firmware"] as? String)
            DonationBox.shared.add(donation)
            return CoreRead.json(donation)
        case "donation.forget":
            DonationBox.shared.remove(args["id"] as? String ?? "")
            return #"{"ok":true}"#
        case "donation.send":
            guard let id = args["id"] as? String,
                  let donation = DonationBox.shared.all().first(where: { $0.id == id }),
                  let base64 = args["payload"] as? String,
                  let payload = Data(base64Encoded: base64) else { return #"{"ok":false}"# }
            let page = await ProjectPageStore(directory: CoreProject.cacheDirectory).cached()
            let metadata = RawDonationPackage.metadata(for: donation,
                                                       appVersion: args["appVersion"] as? String ?? "?")
            let outcome = await RawDonationUploader(service: page.service)
                .send(donation: donation, payload: payload, metadata: metadata)
            if outcome == .sent {
                if RawDonationSettings.standard.keepsLocalCopy {
                    DonationBox.shared.markSent(id)
                } else {
                    DonationBox.shared.remove(id)
                }
                return #"{"ok":true}"#
            }
            return #"{"ok":false}"#
        default: return nil
        }
    }
}

/// The pending donations on disk, beside the Roadmap page's cache.
final class DonationBox: @unchecked Sendable {
    static let shared = DonationBox()

    private let lock = NSLock()
    private let file: URL

    init(directory: URL? = nil) {
        let folder = (directory ?? CoreProject.cacheDirectory).appendingPathComponent("Donations",
                                                                                      isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("pending.json", isDirectory: false)
    }

    func all() -> [PendingDonation] {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: file),
              let rows = try? JSONDecoder().decode([PendingDonation].self, from: data) else { return [] }
        return rows.sorted { $0.recordedAt > $1.recordedAt }
    }

    func add(_ donation: PendingDonation) { write(all() + [donation]) }
    func remove(_ id: String) { write(all().filter { $0.id != id }) }

    func markSent(_ id: String) {
        write(all().map { row in
            var copy = row
            if row.id == id { copy.sentAt = Date() }
            return copy
        })
    }

    private func write(_ rows: [PendingDonation]) {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(rows) { try? data.write(to: file, options: .atomic) }
    }
}
