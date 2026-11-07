import Combine
import Foundation
import WhoopProtocol

/// The strap facts the Settings page prints. `LiveState` publishes with every heart rate and R-R value; none of
/// them is on this page, so the page runs its body again only when one of these moves.
struct SettingsLiveFacts: Equatable {
    let advertisingName: String?
    let batteryPct: Double?
    let bonded: Bool
    let charging: Bool?
    let connected: Bool
    let deepPacketsThisSession: Int
    let ecgRawDataGate: EcgRawDataGateReport?
    let encryptedBond: Bool
    let pairingHint: String?
    let puffinCaptureCount: Int
    let puffinCaptureURL: URL?
    let r22DisableReport: String?
    let r22FlagsAccepted: Int
    let renameStatus: String?
    let whoop5Variant: String?
    let worn: Bool

    @MainActor
    init(_ live: LiveState) {
        advertisingName = live.advertisingName
        batteryPct = live.batteryPct
        bonded = live.bonded
        charging = live.charging
        connected = live.connected
        deepPacketsThisSession = live.deepPacketsThisSession
        ecgRawDataGate = live.ecgRawDataGate
        encryptedBond = live.encryptedBond
        pairingHint = live.pairingHint
        puffinCaptureCount = live.puffinCaptureCount
        puffinCaptureURL = live.puffinCaptureURL
        r22DisableReport = live.r22DisableReport
        r22FlagsAccepted = live.r22FlagsAccepted
        renameStatus = live.renameStatus
        whoop5Variant = live.whoop5Variant
        worn = live.worn
    }
}

/// Passes on a change of `LiveState` only when `SettingsLiveFacts` differ. `objectWillChange` fires before the new
/// value is stored, so the comparison waits for the main queue, which also runs while a page scrolls.
@MainActor
final class SettingsLiveGate: ObservableObject {
    private var last: SettingsLiveFacts
    private var subscription: AnyCancellable?

    init(live: LiveState) {
        last = SettingsLiveFacts(live)
        subscription = live.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak live] _ in
                MainActor.assumeIsolated {
                    guard let self, let live else { return }
                    let now = SettingsLiveFacts(live)
                    if now != self.last {
                        self.last = now
                        self.objectWillChange.send()
                    }
                }
            }
    }
}
