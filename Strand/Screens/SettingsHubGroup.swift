import SwiftUI
import StrandDesign

struct SettingsHubGroup: View {
    let title: LocalizedStringKey
    let pages: [SettingsPage]
    var captions: [SettingsPage: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(title).strandOverline()
            NoopCard(padding: 0, cornerRadius: NoopMetrics.groupedRadius) {
                VStack(spacing: 0) {
                    ForEach(pages.enumerated(), id: \.element.id) { index, page in
                        SettingsHubRow(page: page, caption: captions[page])
                        if index < pages.count - 1 {
                            Divider()
                                .overlay(StrandPalette.hairline)
                                .padding(.leading, NoopMetrics.space6)
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: NoopMetrics.groupedRadius))
            }
        }
    }
}
