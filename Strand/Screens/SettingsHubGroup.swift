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
                    // Array(...): EnumeratedSequence only conforms to RandomAccessCollection from
                    // iOS 26, and ForEach over it crashes on iOS 17/18 when the conformance is missing.
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
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
