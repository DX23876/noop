import SwiftUI
import StrandDesign
import StrandCore

/// Third-party content NOOP uses under its own licence, in one place instead of scattered across the
/// screens that happen to use it. Content mirrors `docs/fork/THIRD_PARTY_NOTICES.md` — keep both in
/// sync by hand when a source is added, removed or its rights status changes.
struct AcknowledgementsView: View {
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("NOOP uses the following third-party content under its own licence. A licence in one domain (code, data, media) is not treated as a licence in another.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                ForEach(Acknowledgements.contentEntries, id: \.title) { item in
                    entry(title: item.title, detail: item.detail, link: item.link)
                }
                entry(title: ExerciseDBProviderClient.defaultAttribution,
                      detail: String(localized: "Optional exercise metadata. Provider terms apply; media downloads are separate."),
                      link: ExerciseDBProviderClient.defaultDocumentation)
                ForEach(Self.bundledLicenses) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        entry(title: item.title, detail: item.detail, link: item.link)
                        NavigationLink {
                            LicenseTextView(title: item.title, resource: item.resource)
                        } label: {
                            Text(verbatim: item.fileLabel).font(StrandFont.caption)
                        }
                    }
                }
                entry(title: Acknowledgements.mediaEntry.title, detail: Acknowledgements.mediaEntry.detail)
                Section {
                    Text("NOOP Forge builds on NOOP by ryanbr and its contributors. These people's fixes and features were taken into NOOP Forge directly, from their own forks or their pull requests. ATTRIBUTION.md lists the sources.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                    ForEach(Self.contributors) { person in
                        entry(title: person.handle, detail: person.work)
                    }
                    Link(Self.attributionURL.absoluteString, destination: Self.attributionURL)
                        .font(StrandFont.caption)
                } header: {
                    Text("People whose work NOOP Forge adopted")
                }
            }
            .forgeListBackground()
            .navigationTitle(Text("Acknowledgements"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) } }
        }
    }

    /// The people credited in ATTRIBUTION.md ("NOOP Forge: work adopted from other people"). The list itself is
    /// `Acknowledgements.contributors` in StrandCore, which the Android screen reads too: add new people there.
    static let contributors: [Contributor] = Acknowledgements.contributors.map {
        Contributor(handle: $0.handle, work: $0.work)
    }

    /// Libraries, models and ported code inside the app whose licence asks for its text to travel with every
    /// copy (`Acknowledgements.bundledLicenses` in StrandCore). Each text ships verbatim in
    /// `Strand/Resources/ThirdParty/` and opens from its row.
    static let bundledLicenses: [BundledLicense] = Acknowledgements.bundledLicenses.map {
        BundledLicense(title: $0.title, detail: $0.detail, link: $0.link, licenseName: $0.licenseName, resource: $0.resource)
    }

    struct BundledLicense: Identifiable {
        let title: String
        let detail: String
        let link: String
        let licenseName: String
        let resource: String
        var id: String { resource }
        /// "MIT · GRDB-LICENSE.txt": the licence and the bundled file, never translated.
        var fileLabel: String { licenseName + " · " + resource + ".txt" }
    }

    struct Contributor: Identifiable {
        let handle: String
        let work: String
        var id: String { handle }
    }

    private static let attributionURL = URL(string: Acknowledgements.attributionURL)!

    private func entry(title: String, detail: String, link: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(StrandFont.subhead.weight(.semibold))
            Text(detail).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            if let link, let url = URL(string: link) {
                Link(link, destination: url).font(StrandFont.caption)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One bundled licence text, shown verbatim.
private struct LicenseTextView: View {
    let title: String
    let resource: String

    private var text: String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let body = try? String(contentsOf: url, encoding: .utf8) else { return resource + ".txt" }
        return body
    }

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(Text(verbatim: title))
    }
}
