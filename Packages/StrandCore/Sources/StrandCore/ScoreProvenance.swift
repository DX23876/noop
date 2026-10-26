import Foundation
import StrandAnalytics
import WhoopStore

/// Which provider's inputs produced a resolved Today score, and how its name reads (Android plan E-3, moved from
/// `Repository.scoreInputProvider` and `TodayView.todayScoreProviderLabel` so the Apple and the Android hero name
/// the same source).
public enum ScoreProvenance {
    /// The sensor/import provider whose inputs produced a resolved Today score. `sourceId` is durable and `brand`
    /// comes from the paired-device registry when available, so every supported provider can be named without
    /// guessing from opaque device ids.
    public struct Provider: Equatable, Sendable {
        public let sourceId: String
        public let brand: String?
        public init(sourceId: String, brand: String?) { self.sourceId = sourceId; self.brand = brand }
    }

    /// A provider's name: a brand or product name as is, or one of the few that each platform translates.
    public enum Label: Equatable, Hashable, Sendable {
        case name(String)
        case workoutFiles, nutrition, cached
    }

    /// The import source a workout file (GPX, FIT, TCX) lands under.
    public static let activityFileSource = "activity-file"
    static let whoopBrandName = "WHOOP"

    /// Resolve a displayed score back to the provider that supplied its inputs. Direct imported points already
    /// name their provider. A `-noop` point is looked up in the metric-level provenance cache; missing legacy
    /// metadata returns nil rather than falsely claiming its parent device.
    public static func provider(store: WhoopStore, resolvedSource: String, day: String,
                                metricKey: String) async -> Provider? {
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        let sourceId: String
        if resolvedSource.hasSuffix("-noop") {
            guard let cached = try? await store.scoreInputSource(deviceId: resolvedSource, day: day, key: metricKey)
            else { return nil }
            sourceId = cached
        } else {
            sourceId = resolvedSource
        }
        let brand = (try? registry.all())?.first(where: { $0.id == sourceId })?.brand
        return Provider(sourceId: sourceId, brand: brand)
    }

    /// The hero names the provider that supplied the score inputs, not where NOOP ran the math. Registered
    /// device brands cover every live source; stable import ids cover providers without a paired registry row.
    /// Unknown ids remain visible rather than being falsely labelled as WHOOP.
    public static func label(sourceId: String, brand: String?) -> Label {
        let source = sourceId.lowercased()
        switch source {
        case MetricResolver.appleHealthSource: return .name("Apple Watch")
        case MetricResolver.healthConnectSource: return .name("Health Connect")
        case "oura-import", "oura-api": return .name("Oura")
        case "fitbit-import": return .name("Fitbit")
        case "garmin-import": return .name("Garmin")
        case "xiaomi-band": return .name("Mi Band")
        case activityFileSource: return .workoutFiles
        default: break
        }
        if let brand = brand?.trimmingCharacters(in: .whitespacesAndNewlines), !brand.isEmpty {
            return .name(brand.caseInsensitiveCompare("WHOOP") == .orderedSame ? whoopBrandName : brand)
        }
        if source == MetricResolver.whoopSource { return .name(whoopBrandName) }
        switch FusionSource(rawValue: sourceId) {
        case .nutritionCsv: return .nutrition
        case .localCache: return .cached
        case let known?: return .name(known.displayName)
        case nil: return .name(sourceId)
        }
    }

    /// The hero's card-level label for one day: the provider of Charge, Effort and Rest in that order, identical
    /// names collapsed, at most two (the iOS hero joins them with " + "). Empty when no score has a provider.
    public static func heroLabels(day: String, reader: StoreReader) async -> [Label] {
        var labels: [Label] = []
        for key in ["recovery", "strain", "sleep_performance"] {
            let resolution = await MetricResolver.resolve(
                store: reader.store, key: key, preferredSource: MetricResolver.whoopSource,
                actualWhoopSource: reader.activeDeviceId, from: day, to: day, suppressedSleepWakeDays: [])
            guard let point = resolution.points.last(where: { $0.day == day }),
                  let provider = await provider(store: reader.store, resolvedSource: point.source, day: day,
                                                metricKey: key) else { continue }
            let label = label(sourceId: provider.sourceId, brand: provider.brand)
            if !labels.contains(label) { labels.append(label) }
            if labels.count == 2 { break }
        }
        return labels
    }
}
