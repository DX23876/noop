import Foundation

/// UserDefaults that survive a restart on Android. Foundation outside Apple keeps `UserDefaults.standard` in
/// memory only when the process has no bundle identifier, which an Android app process does not, so every setting
/// the shared code stores there (the coach's identity and settings, goal preferences) was gone on the next launch.
/// The core reads one property list into the store at start (`core.setResources`) and writes it back after each
/// call (`CoreCall.run`) when something changed. On Apple, where UserDefaults persists by itself, both do nothing.
enum CoreDefaults {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var file: URL?
    /// What the file holds, compared by value: a dictionary's encoding can differ in key order run to run.
    nonisolated(unsafe) private static var written: NSDictionary?

    static func load(from url: URL) {
        #if !canImport(Darwin)
        lock.lock(); file = url; lock.unlock()
        guard let data = try? Data(contentsOf: url),
              let stored = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return }
        for (key, value) in stored { UserDefaults.standard.set(value, forKey: key) }
        lock.lock(); written = stored as NSDictionary; lock.unlock()
        #endif
    }

    static func save() {
        #if !canImport(Darwin)
        lock.lock(); defer { lock.unlock() }
        guard let file else { return }
        let values = UserDefaults.standard.dictionaryRepresentation()
            .filter { PropertyListSerialization.propertyList($0.value, isValidFor: .binary) }
        let current = values as NSDictionary
        guard written.map({ !$0.isEqual(to: values) }) ?? true,
              let data = try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
        else { return }
        if (try? data.write(to: file, options: .atomic)) != nil { written = current }
        #endif
    }
}
