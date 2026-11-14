import Foundation

/// Reads the XML plist inside an `embedded.mobileprovision`.
///
/// The file is a CMS / PKCS#7 (DER) blob that wraps an XML plist. Rather than pull in Security/CMS
/// decoding, the plist is sliced out of the raw bytes, from the first `<?xml` to the first `</plist>`,
/// and parsed with `PropertyListSerialization`. Every reader of the profile (App Group resolution,
/// the HealthKit entitlement check, the diagnostics expiry line) goes through this one parse.
public enum ProvisioningProfile {
    /// The profile's top-level plist, or nil when the bytes carry no parseable plist.
    public static func plist(from data: Data) -> [String: Any]? {
        guard let xmlStart = data.range(of: Data("<?xml".utf8)),
              let xmlEnd = data.range(of: Data("</plist>".utf8)),
              xmlStart.lowerBound < xmlEnd.upperBound else { return nil }
        let plistData = data.subdata(in: xmlStart.lowerBound..<xmlEnd.upperBound)
        return try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
            as? [String: Any]
    }

    /// The plist of the `embedded.mobileprovision` inside `bundleURL`, or nil when there is none.
    public static func plist(inBundleAt bundleURL: URL) -> [String: Any]? {
        let url = bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return plist(from: data)
    }

    /// The App Groups a profile grants (`Entitlements` → `com.apple.security.application-groups`).
    public static func appGroups(in plist: [String: Any]) -> [String] {
        let entitlements = plist["Entitlements"] as? [String: Any]
        return (entitlements?["com.apple.security.application-groups"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("group.") && $0.count > "group.".count }
    }
}

/// The ONE place that decides which App Group the app, its widgets, its Live Activity, the Watch app and
/// the complication share. `WidgetSnapshot.suiteName` and `WatchScoreSnapshot.appGroupId` both forward
/// here, so two readers can never settle on different groups.
///
/// The build asks for the group in `AppGroupIdentifier` (from `$(APP_GROUP_ID)`), but a re-signed
/// install usually gets another one:
/// - AltStore / SideStore append the signing team and list the result in `ALTAppGroups`. With
///   SideStore's "Use Main Profile" only the app's Info.plist carries that list, not the extension's.
/// - Certificate signers (Feather, ESign, the Forge Signer) apply the profile's entitlements. A seller's
///   profile often brings its own fixed groups (`group.<id>.1` … `.5`), none named like ours.
///
/// So at runtime the resolver takes the first candidate the signature actually grants, in an order
/// that both the app and every extension walk the same way:
/// 1. the configured group,
/// 2. `ALTAppGroups` (own first, then the containing app's), groups named after the configured one first,
/// 3. the profile's groups sorted by name (own profile, else the containing app's),
/// and only when none is granted falls back to the build-time rule, so an unentitled install behaves
/// exactly as before. Sharing a seller's group means other apps signed with the same certificate on the
/// same device could read what NOOP writes there; that is the price of widgets under such a profile.
public enum AppGroupResolver {
    /// The canonical upstream group, used only when nothing else names one.
    public static let fallbackGroup = "group.com.noopapp.noop"

    /// The group this process uses, computed once.
    public static let current: String = {
        #if os(macOS)
        // macOS signs with no re-signer in between and its containerURL answers without an entitlement,
        // so a runtime probe would prove nothing there: keep the build-time rule.
        return resolve(info: Bundle.main.infoDictionary ?? [:])
        #else
        let bundleURL = Bundle.main.bundleURL
        let containingURL: URL? = bundleURL.pathExtension == "appex"
            ? bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            : nil
        let containingInfo = containingURL.flatMap { Bundle(url: $0)?.infoDictionary }
        let profile = ProvisioningProfile.plist(inBundleAt: bundleURL)
            ?? containingURL.flatMap { ProvisioningProfile.plist(inBundleAt: $0) }
        return resolve(
            info: Bundle.main.infoDictionary ?? [:],
            containingAppInfo: containingInfo,
            profileGroups: profile.map(ProvisioningProfile.appGroups(in:)) ?? [],
            isGranted: { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil }
        )
        #endif
    }()

    /// Pure resolution over injected inputs. With `isGranted` nil it applies only the build-time rule
    /// (configured group, or the matching / single `ALTAppGroups` entry), which is what tests of the old
    /// behaviour and the macOS build use.
    public static func resolve(info: [String: Any],
                               containingAppInfo: [String: Any]? = nil,
                               profileGroups: [String] = [],
                               isGranted: ((String) -> Bool)? = nil) -> String {
        let configured = configuredGroup(info)
        if let isGranted {
            if let configured, isGranted(configured) { return configured }
            let alt = ordered(altGroups(info), configured: configured)
                + ordered(altGroups(containingAppInfo ?? [:]), configured: configured)
            if let granted = alt.first(where: isGranted) { return granted }
            if let granted = Array(Set(profileGroups)).sorted().first(where: isGranted) { return granted }
        }
        return buildTimeRule(configured: configured, altGroups: altGroups(info))
    }

    private static func configuredGroup(_ info: [String: Any]) -> String? {
        guard let value = (info["AppGroupIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static func altGroups(_ info: [String: Any]) -> [String] {
        ((info["ALTAppGroups"] as? [String]) ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("group.") && $0.count > "group.".count }
    }

    /// Groups named after the configured one (AltStore's `<configured>.<TEAM>`) ahead of the rest.
    private static func ordered(_ groups: [String], configured: String?) -> [String] {
        guard let configured else { return groups }
        let matches = groups.filter { $0 == configured || $0.hasPrefix(configured + ".") }
        return matches + groups.filter { !matches.contains($0) }
    }

    /// The rule that applied before runtime probing: a provisioned AltStore group named after the
    /// configured one, else a single provisioned group, else the configured group, else the fallback.
    private static func buildTimeRule(configured: String?, altGroups: [String]) -> String {
        if let configured,
           let provisioned = altGroups.first(where: { $0 == configured || $0.hasPrefix(configured + ".") }) {
            return provisioned
        }
        if altGroups.count == 1, let provisioned = altGroups.first { return provisioned }
        return configured ?? fallbackGroup
    }
}
