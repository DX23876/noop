#if os(iOS)
import SwiftUI
import StrandCore
import StrandAnalytics

/// The packs on this iPhone and the ones to download.
struct FoodPacksSection: View {
    let packs: FoodPacksModel

    var body: some View {
        Section("On this iPhone") {
            if packs.installed.isEmpty {
                Text("No country downloaded yet.").foregroundStyle(ForgeColor.secondary)
            }
            ForEach(packs.installed, id: \.country) { pack in
                LabeledContent {
                    if let update = packs.update(for: pack) {
                        Button("Update") { Task { await packs.download(update) } }.disabled(packs.downloading != nil)
                    }
                } label: {
                    Text(name(pack.country))
                    Text("\(pack.rows.formatted(.number.locale(AppLanguage.activeLocale))) products")
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { Task { await packs.remove(pack) } }
                }
            }
        }
        Section {
            if packs.manifestFailed {
                Text("The list of countries could not be loaded.").foregroundStyle(ForgeColor.secondary)
            }
            ForEach(packs.offered, id: \.country) { pack in
                Button { Task { await packs.download(pack) } } label: {
                    LabeledContent {
                        if packs.downloading == pack.country {
                            ProgressView(value: packs.progress).frame(width: 64)
                        } else {
                            Image(systemName: "arrow.down.circle").foregroundStyle(ForgeColor.accent)
                        }
                    } label: {
                        Text(name(pack.country)).foregroundStyle(ForgeColor.text)
                        Text("\(pack.rows.formatted(.number.locale(AppLanguage.activeLocale))) products · \(Int64(pack.bytes).formatted(.byteCount(style: .file)))")
                    }
                }
                .disabled(packs.downloading != nil)
            }
            if let failure = packs.failure {
                Text(failure).foregroundStyle(ForgeColor.effortInk)
            }
        } header: {
            Text("Download")
        } footer: {
            Text("A download is a public file from the NOOP Forge release on GitHub. It carries nothing about you.")
        }
    }

    private func name(_ tag: String) -> String { FoodCountries.name(forTag: tag, locale: AppLanguage.activeLocale) }
}
#endif
