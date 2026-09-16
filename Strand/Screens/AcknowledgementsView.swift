import SwiftUI
import StrandDesign

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
                entry(title: "MuscleMap body geometry",
                      detail: "Used for the Exercise Library's muscle picker. melihcolpan / repository contributors, MIT licence.",
                      link: "https://github.com/melihcolpan/MuscleMap")
                entry(title: "react-native-body-highlighter body geometry",
                      detail: "Used for the Strength screen's muscle load map. Copyright (c) 2022 ELABBASSI Hicham, MIT licence.",
                      link: "https://github.com/HichamELBSI/react-native-body-highlighter")
                entry(title: "ExerciseDB v1 exercise data",
                      detail: "Exercise names, body parts, equipment, targets, muscle groups and instructions via hasaneyldrm/exercises-dataset. MIT licence.",
                      link: "https://github.com/hasaneyldrm/exercises-dataset")
                entry(title: "Exercise media (images and animations)",
                      detail: "© Gym visual — gymvisual.com. Not licensed to NOOP: cloning the exercises-dataset repository is not a licence to its media. NOOP never bundles these files; downloading them is an explicit, disclosed, opt-in action, and the credit line appears under every animation.")
            }
            .navigationTitle(Text("Acknowledgements"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) } }
        }
    }

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
