import Foundation
import StrandCore
import WhoopStore

/// Records the donation windows during a workout, and leaves the finished recording waiting for the
/// wearer to decide. The schedule, the package and the upload live in `StrandCore.RawDonation`; this is
/// the part that has to touch the strap, so it stays in the app layer like every other BLE caller.
///
/// Three things it will not do, each one a promise the explainer page makes:
///
/// - **It does not arm itself.** `begin` returns without doing anything unless the wearer ticked this
///   sport. An empty tick list is the default, so an app nobody configured never streams raw data.
/// - **It does not send.** `finish` produces a pending donation and stops. The send is a separate press
///   on the donation page, and without a service address there is no send at all.
/// - **It does not keep running when the strap is gone.** A dropped connection ends the window; the
///   recording keeps what it had rather than waiting for a reconnect mid-session.
///
/// What it cannot promise, and what the page says in as many words: whether streaming 100 Hz raw motion
/// during a workout disturbs the live heart rate or the history offload is unmeasured. That is why the
/// default is off, why the windows are two minutes rather than the whole session, and why the first
/// person to try it is asked to say what happened.
@MainActor
final class RawDonationRecorder: ObservableObject {
    static let shared = RawDonationRecorder()

    @Published private(set) var isRecordingWindow = false
    @Published private(set) var pending: [PendingDonation] = []

    private let settings: RawDonationSettings
    private let store: DonationStore
    private var windows: [RawDonationWindow] = []
    private var sport = ""
    private var sessionID: String?
    private var captureStart: Date?
    private var recordedSeconds: TimeInterval = 0

    /// Set by the host so this file never reaches into `AppModel`: start, stop, and the bytes.
    var startCapture: ((String) -> Bool)?
    var stopCapture: (() async -> Void)?
    var collectPayload: ((String, Date, Date) async -> Data)?
    var strapFamily: (() -> (family: String, firmware: String?))?

    init(settings: RawDonationSettings = .standard, store: DonationStore = .shared) {
        self.settings = settings
        self.store = store
        pending = store.load()
    }

    /// Called when a workout starts. Does nothing unless this sport was ticked.
    func begin(sport: String, expected: TimeInterval) {
        guard let plan = settings.plan(for: sport, expected: expected) else { return }
        windows = plan
        self.sport = sport
        sessionID = "donation-\(UUID().uuidString.prefix(8))"
        recordedSeconds = 0
    }

    /// Called on the workout's own tick. Opens and closes the windows; cheap enough for every second.
    func tick(elapsed: TimeInterval, strapConnected: Bool) {
        guard let sessionID, !windows.isEmpty else { return }
        let wants = strapConnected && RawDonationPlan.isRecording(at: elapsed, windows: windows)
        if wants, !isRecordingWindow {
            guard startCapture?(sessionID) == true else { return }
            captureStart = Date()
            isRecordingWindow = true
        } else if !wants, isRecordingWindow {
            closeWindow()
        }
    }

    /// Called when the workout ends. Leaves a pending donation when anything was recorded.
    func finish() async {
        guard let sessionID, !windows.isEmpty else { return reset() }
        if isRecordingWindow { closeWindow() }
        await stopCapture?()
        let seconds = Int(recordedSeconds.rounded())
        guard seconds >= 30 else { return reset() }
        let identity = strapFamily?() ?? (family: "unknown", firmware: nil)
        let bytes = RawDonationPlan.approximateBytes(windows)
        let donation = PendingDonation(id: sessionID, sport: sport, recordedSeconds: seconds,
                                       bytes: bytes, strapFamily: identity.family,
                                       firmware: identity.firmware)
        store.add(donation)
        pending = store.load()
        reset()
    }

    /// The bytes for one pending donation, read when the wearer presses send and not before.
    func payload(for donation: PendingDonation) async -> Data {
        await collectPayload?(donation.id, donation.recordedAt.addingTimeInterval(-7200),
                              donation.recordedAt) ?? Data()
    }

    func forget(_ donation: PendingDonation) {
        store.remove(donation.id)
        pending = store.load()
    }

    func markSent(_ donation: PendingDonation) {
        if settings.keepsLocalCopy {
            store.markSent(donation.id)
        } else {
            store.remove(donation.id)
        }
        pending = store.load()
    }

    private func closeWindow() {
        if let start = captureStart { recordedSeconds += Date().timeIntervalSince(start) }
        captureStart = nil
        isRecordingWindow = false
        Task { await stopCapture?() }
    }

    private func reset() {
        windows = []
        sessionID = nil
        sport = ""
        captureStart = nil
        isRecordingWindow = false
    }
}

/// The pending donations on disk. A plain file beside the collector's sessions: this is a short list of
/// small records, and it must survive a restart so a recording is not lost before it was decided about.
final class DonationStore {
    static let shared = DonationStore()

    private let file: URL

    init(directory: URL? = nil) {
        let base = directory ?? (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                              in: .userDomainMask, appropriateFor: nil,
                                                              create: true))
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("OpenWhoop/Donations", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        file = folder.appendingPathComponent("pending.json", isDirectory: false)
    }

    func load() -> [PendingDonation] {
        guard let data = try? Data(contentsOf: file),
              let rows = try? JSONDecoder().decode([PendingDonation].self, from: data) else { return [] }
        return rows.sorted { $0.recordedAt > $1.recordedAt }
    }

    func add(_ donation: PendingDonation) {
        var rows = load()
        rows.append(donation)
        write(rows)
    }

    func remove(_ id: String) {
        write(load().filter { $0.id != id })
    }

    func markSent(_ id: String) {
        write(load().map { row in
            var copy = row
            if row.id == id { copy.sentAt = Date() }
            return copy
        })
    }

    private func write(_ rows: [PendingDonation]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(rows) { try? data.write(to: file, options: .atomic) }
    }
}
