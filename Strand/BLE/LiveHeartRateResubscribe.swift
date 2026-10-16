import Foundation

/// When the standard 0x2A37 heart-rate subscription on a WHOOP 5/MG must be renewed by hand.
///
/// A field log (2026-10-16, MG, fw 50.41.1.0) showed a link that reported 0x2A37 as notifying for more
/// than two hours while not one HR value arrived, although history offload, the clock and the strap's own
/// log all worked on the same link. On that connect the services came back heart-rate first, so the
/// 0x2A37 subscription was confirmed BEFORE the CLIENT_HELLO ack, i.e. before the link was encrypted.
/// The post-bond pass then skipped 0x2A37 because it already read `isNotifying`. Every other connect in
/// the available logs confirmed 0x2A37 after the ack, was re-requested post-bond, and streamed. A later
/// relaunch that attached to the same OS link stayed silent too, and only a real disconnect brought the
/// stream back. The firmware's handling of a pre-encryption subscription is not observed directly, so
/// both rules here only renew the subscription, an off→on CCCD write that changes nothing on a healthy
/// link: they never drop the link.
enum LiveHeartRateResubscribe {
    /// Silence on a notifying 0x2A37 before one renewal is tried. The stream normally delivers about
    /// once a second; at rest or off the wrist it can pause for minutes (#580), which is why a renewal is
    /// tried once per silent stretch rather than repeated.
    static let silenceSeconds: TimeInterval = 90

    /// Was this confirmation of the 0x2A37 subscription made before the bond was proven on this link?
    static func confirmedBeforeBond(isNotifying: Bool, encryptedBond: Bool, isWhoop5: Bool) -> Bool {
        isWhoop5 && isNotifying && !encryptedBond
    }

    /// Should a notifying 0x2A37 that has delivered nothing for a while be renewed now?
    ///
    /// The silent stretch runs from the later of the subscription's confirmation and the last value, so
    /// a fresh subscription gets the whole window. `alreadyTried` holds for the rest of the stretch and
    /// is cleared by the next value, so a strap that is simply off the wrist gets one renewal, not one
    /// per keep-alive tick.
    static func shouldRenewSilent(now: Date, confirmedAt: Date?, lastValueAt: Date?,
                                  alreadyTried: Bool, silence: TimeInterval = silenceSeconds) -> Bool {
        guard !alreadyTried, let confirmedAt else { return false }
        let quietSince = max(confirmedAt, lastValueAt ?? confirmedAt)
        return now.timeIntervalSince(quietSince) > silence
    }
}
