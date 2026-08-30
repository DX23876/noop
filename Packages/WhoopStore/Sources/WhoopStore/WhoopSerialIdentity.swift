import Foundation

/// The stable WHOOP device id derived from the strap's own serial (#1303).
///
/// WHOOP strap identity is otherwise a TRANSIENT CoreBluetooth UUID: a re-pair or factory reset mints a
/// fresh one, so the same physical strap forks into a second registry row and orphans its history (#1193).
/// The ring path already solved this — `DeviceRegistryStore.adoptSerialIdentity` re-points a provisional id
/// onto a serial id and migrates every device-scoped row — and this is the WHOOP half of the same idea.
///
/// Pure and store-free so both platforms can pin the composition and, more importantly, the REFUSALS: a
/// blank or implausible serial must yield nil and leave the existing id alone. Adopting onto a junk id
/// would be worse than not adopting at all, because the migration moves every row onto it.
///
/// Kotlin twin: `WhoopSerialIdentity`.
public enum WhoopSerialIdentity {

    /// The one place the WHOOP id namespace is spelled. `AddDeviceWizard` mints `whoop-<CB-UUID>` and
    /// `DeviceRegistryStore` classifies on the same prefix; a serial id joins the same namespace so every
    /// existing prefix check keeps working unchanged.
    public static let idPrefix = "whoop"

    /// Shortest serial worth adopting. A 5.0/MG DIS serial is far longer; this only rejects a truncated or
    /// placeholder read, which a partial GATT response can produce.
    public static let minSerialLength = 6

    /// The `whoop-<serial>` id for a strap serial, or nil when the serial cannot be trusted to identify it.
    ///
    /// Refuses blank/whitespace, anything under `minSerialLength`, and any serial carrying a character
    /// outside `[A-Z0-9-]` after upper-casing — a DIS read that returns a descriptive string rather than a
    /// serial should never become a device id. Upper-cased so the same strap read twice, in either case,
    /// resolves to ONE id rather than two.
    public static func adoptedId(serial: String?) -> String? {
        guard let raw = serial?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let up = raw.uppercased()
        guard up.count >= minSerialLength else { return nil }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard up.allSatisfy({ allowed.contains($0) }) else { return nil }
        return "\(idPrefix)-\(up)"
    }

    /// Whether this pairing's id may be re-pointed onto a serial id at all.
    ///
    /// ONLY a provisional `whoop-<CB-UUID>` id qualifies. The legacy `my-whoop` seed is deliberately
    /// EXCLUDED, and that exclusion is what makes this safe to ship before #1304: every existing
    /// single-WHOOP install is still on that seed, ~47 code paths still read the literal `"my-whoop"`
    /// directly, and `WhoopBleClient.deviceId` documents that the single-WHOOP path never reassigns it.
    /// Adopting it would migrate the whole history onto `whoop-<serial>` while new samples kept being
    /// written under `my-whoop` — a split history that reads as data loss.
    ///
    /// The legacy seed joins this path as part of #1304, once the literals no longer assume it.
    public static func mayAdopt(currentId: String) -> Bool {
        currentId.hasPrefix("\(idPrefix)-")
    }

    /// True when `id` is already the serial id for `serial` — the steady state on every reconnect after the
    /// first adoption, and the cheap early-out that keeps re-adoption from doing database work per connect.
    public static func isAlreadyAdopted(id: String, serial: String?) -> Bool {
        guard let target = adoptedId(serial: serial) else { return false }
        return id == target
    }

    /// What may be written to a SHAREABLE strap log. The serial identifies the device, so only its leading
    /// characters are ever logged — the same rule `noteWhoop5VariantFromDIS` already applies to the variant
    /// line. Never log `adoptedId`'s result directly.
    public static func logSafe(serial: String?) -> String {
        guard let raw = serial?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return "?" }
        return String(raw.uppercased().prefix(3)) + "…"
    }
}
