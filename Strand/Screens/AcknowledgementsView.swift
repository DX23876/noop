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
                entry(title: "MuscleMap body geometry",
                      detail: "Used for the Exercise Library's muscle picker. melihcolpan / repository contributors, MIT licence.",
                      link: "https://github.com/melihcolpan/MuscleMap")
                entry(title: "react-native-body-highlighter body geometry",
                      detail: "Used for the Strength screen's muscle load map. Copyright (c) 2022 ELABBASSI Hicham, MIT licence.",
                      link: "https://github.com/HichamELBSI/react-native-body-highlighter")
                entry(title: "ExerciseDB v1 exercise data",
                      detail: "Exercise names, body parts, equipment, targets, muscle groups and instructions via hasaneyldrm/exercises-dataset. MIT licence.",
                      link: "https://github.com/hasaneyldrm/exercises-dataset")
                entry(title: ExerciseDBProviderClient.defaultAttribution,
                      detail: String(localized: "Optional exercise metadata. Provider terms apply; media downloads are separate."),
                      link: ExerciseDBProviderClient.defaultDocumentation)
                entry(title: "Exercise media (images and animations)",
                      detail: "© Gym visual — gymvisual.com. Not licensed to NOOP: cloning the exercises-dataset repository is not a licence to its media. NOOP never bundles these files; downloading them is an explicit, disclosed, opt-in action, and the credit line appears under every animation.")
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

    /// The people credited in ATTRIBUTION.md ("NOOP Forge: work adopted from other people"). Keep both in
    /// sync by hand when the fork adopts someone's work. Handles and summaries are not translated, like the
    /// third-party entries above.
    static let contributors: [Contributor] = [
        Contributor(handle: "@UtkuDenizAltiok", work: "Deleted-nights list, sync reminder, SDNN guard, wind-down sleep need, skin temperature once and in your unit, translations"),
        Contributor(handle: "@ayiskakov", work: "Offload data-loss fixes, Bluetooth power-off teardown, deep-sleep onset hold, delete versus re-score"),
        Contributor(handle: "@kavemang", work: "Sleep marks through Shortcuts, DST tests, gravity witness, workout edits shown before the rescore"),
        Contributor(handle: "@Iskrata", work: "Absolute skin temperature on import, beat-to-beat intervals and nightly vitals in Apple Health"),
        Contributor(handle: "@gdorgian", work: "Liquid clocks stand down when still, a short last sleep stretch is kept"),
        Contributor(handle: "@mohamedchnafy-ds", work: "Weekly sets per muscle (idea), recent naps for the coach"),
        Contributor(handle: "@JohanStefanes", work: "5/MG one-shot buzz without RUN_ALARM"),
        Contributor(handle: "@christophersarmiento", work: "Strap model stamped only after a scan accepts it"),
        Contributor(handle: "@goodgord", work: "No sleep merge across a data gap"),
        Contributor(handle: "@spidervirus", work: "No startup zero heart rate"),
        Contributor(handle: "@fadkeprasad", work: "Power-saving cadence for automatic syncs"),
        Contributor(handle: "@paradix86", work: "Italian WHOOP exports"),
        Contributor(handle: "@msff", work: "Mac menu-bar redraws"),
        Contributor(handle: "@andynilson", work: "Charge and Effort translations"),
        Contributor(handle: "@shajidahmed", work: "Config read-back check"),
        Contributor(handle: "@abhilashvadnala", work: "Day cycle on an early bedtime"),
        Contributor(handle: "@reinmaker", work: "Split-night consistency"),
        Contributor(handle: "@Billytheking954", work: "Restore rollback through the WAL"),
        Contributor(handle: "@J-Gur", work: "Health Connect permissions"),
        Contributor(handle: "@rntcruz23", work: "Connect failure message"),
        Contributor(handle: "@bartmuskala", work: "Maximum heart rate resolver"),
        Contributor(handle: "bogaczcyprien-svg, aansun, denismanulov", work: "Respiratory-rate grid, off-wrist sleep cut, an offload data-loss path"),
        Contributor(handle: "meta1971, OpenStrap", work: "5/MG SET_CLOCK sub-seconds, MG ECG reading"),
    ]

    struct Contributor: Identifiable {
        let handle: String
        let work: String
        var id: String { handle }
    }

    private static let attributionURL = URL(string: "https://github.com/DX23876/noop/blob/main/ATTRIBUTION.md")!

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
