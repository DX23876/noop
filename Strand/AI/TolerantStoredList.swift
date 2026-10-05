import Foundation

/// A stored JSON array read one element at a time, so an element this build cannot read stays in storage.
///
/// The goal stores keep their records as one array. Decoded as `[T]`, a single element written by a newer
/// build (a daily goal kind this build has no case for) fails the whole array: the store starts empty and
/// its next save writes the empty list over everything the wearer had. Here every element is read on its
/// own. The readable ones become `T`; the rest are kept verbatim as `foreign` and written back after the
/// readable ones on save, so installing the newer build again finds them as they were.
struct TolerantStoredList<T: Codable>: Codable {
    var items: [T]
    var foreign: [PreservedJSON]

    init(items: [T], foreign: [PreservedJSON] = []) {
        self.items = items
        self.foreign = foreign
    }

    init(from decoder: Decoder) throws {
        // Each element as raw JSON first: a failed `decode(T.self)` on an unkeyed container does not move
        // past the element, so reading `T` directly could not skip the unreadable one.
        let raw = try [PreservedJSON](from: decoder)
        var items: [T] = []
        var foreign: [PreservedJSON] = []
        for element in raw {
            if let data = try? JSONEncoder().encode(element), let item = try? JSONDecoder().decode(T.self, from: data) {
                items.append(item)
            } else {
                foreign.append(element)
            }
        }
        self.items = items
        self.foreign = foreign
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        for item in items { try c.encode(item) }
        for element in foreign { try c.encode(element) }
    }
}
