#if os(Android)
/// Shared app helpers carry English fallback labels alongside their data. Android Swift Foundation does not offer
/// Apple's `String(localized:)`; the Compose layer localizes visible labels with its own resources.
extension String {
    init(localized key: String) { self = key }
    init(localized key: String, defaultValue: String) { self = defaultValue }
}
#endif
