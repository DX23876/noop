import Foundation
import StrandCore

/// Settings › About › Acknowledgements for Android: the one credit list the Apple screen shows
/// (`Acknowledgements` in StrandCore), as the wire shape the Android screen draws. The licence texts the rows
/// open are files, shipped with the app; the core only names them.
enum CoreAcknowledgements {
    struct Wire: Encodable, Equatable {
        struct Entry: Encodable, Equatable { let title: String; let detail: String; let link: String? }
        struct License: Encodable, Equatable {
            let title: String; let detail: String; let link: String
            let licenseName: String; let resource: String; let fileLabel: String
        }
        struct Person: Encodable, Equatable { let handle: String; let work: String }
        let content: [Entry]
        let licenses: [License]
        let media: Entry
        let contributors: [Person]
        let attributionUrl: String
    }

    /// `appleOnly` licences (the Markdown renderer and the memory-index model) are left out for Android: the list
    /// never names a dependency the Android build does not contain.
    static func wire(android: Bool = true) -> Wire {
        func entry(_ e: Acknowledgements.Entry) -> Wire.Entry { .init(title: e.title, detail: e.detail, link: e.link) }
        return Wire(
            content: Acknowledgements.contentEntries.map(entry),
            licenses: Acknowledgements.bundledLicenses.filter { !(android && $0.appleOnly) }.map {
                .init(title: $0.title, detail: $0.detail, link: $0.link, licenseName: $0.licenseName,
                      resource: $0.resource, fileLabel: $0.fileLabel)
            },
            media: entry(Acknowledgements.mediaEntry),
            contributors: Acknowledgements.contributors.map { .init(handle: $0.handle, work: $0.work) },
            attributionUrl: Acknowledgements.attributionURL)
    }

    static func run(_ op: String, _ args: [String: Any]) -> String? {
        switch op {
        case "about.acknowledgements": return CoreRead.json(wire())
        default: return nil
        }
    }
}
