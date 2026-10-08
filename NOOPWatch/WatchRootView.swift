import SwiftUI
import StrandDesign

// MARK: - WatchRootView — the vertical page deck
//
// The watchOS 10 layout: one NavigationStack around a vertical page TabView, so the Digital Crown (or a
// vertical swipe) moves between full-screen pages and each page puts its title in the system bar next to
// the clock instead of spending a row of the face on it. The glance (today's synced scores) comes first,
// then the three on-watch active features. Every page paints the same near-black canvas with a soft wash
// of its own domain colour at the top, so the page you are on is recognisable before you read anything.
// The phone stays the brain for the SCORES on the glance; Breathe / Workout / Intervals run on the watch's
// own sensors + haptics.
struct WatchRootView: View {
    enum Page: Hashable { case glance, breathe, workout, intervals }

    @State private var page: Page

    init(initialPage: Page = .glance) {
        _page = State(initialValue: initialPage)
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                WatchGlanceView()
                    .navigationTitle("Today")
                    .containerBackground(Self.wash(StrandPalette.chargeColor), for: .tabView)
                    .tag(Page.glance)
                WatchBreatheView()
                    .navigationTitle("Breathe")
                    .containerBackground(Self.wash(StrandPalette.restColor), for: .tabView)
                    .tag(Page.breathe)
                WatchWorkoutView()
                    .navigationTitle("Workout")
                    .containerBackground(Self.wash(StrandPalette.effortColor), for: .tabView)
                    .tag(Page.workout)
                WatchIntervalView()
                    .navigationTitle("Intervals")
                    .containerBackground(Self.wash(StrandPalette.effortColor), for: .tabView)
                    .tag(Page.intervals)
            }
            .tabViewStyle(.verticalPage)
        }
    }

    /// The page background: the domain colour fading into the canvas within the top third, so content
    /// below always sits on the plain near-black surface the design tokens were tuned for.
    private static func wash(_ tint: Color) -> LinearGradient {
        LinearGradient(stops: [.init(color: tint.opacity(0.30), location: 0),
                               .init(color: StrandPalette.surfaceBase, location: 0.45)],
                       startPoint: .top, endPoint: .bottom)
    }
}
