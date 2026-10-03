# Today: Momentum day switching and sync header overflow

Analysis migration required: no. These changes correct transient presentation and layout. Stored daily values, scoring inputs, baselines and analysis recipes are unchanged.

## Reproduction and cause

The reported Liquid Today screenshots show today's Charge/Momentum starting at 80, then a swipe to yesterday showing a Charge of 51 while Momentum retains 80. Returning to today reverses the mismatch.

An isolated task-invalidation replay using the actual `TodayView.MomentumKey` and Liquid Today's key getter reproduced both transitions:

```text
offset=1, hero=51, momentum=80, matches=false
offset=0, hero=80, momentum=51, matches=false
```

The selection changes before `load()` commits its asynchronous snapshot. Momentum's separate task observes selection and repository changes, so it can run against the previous snapshot. The snapshot commit was absent from its invalidation key. The existing generation/cancellation guard already rejects superseded loads; changing the day-to-row lookup is unnecessary.

The second report shows the whole scroll content clipped horizontally during sync, including the title and lower cards. A minimized SwiftUI render of the existing header layout reproduced this: offered width 320, idle width 320, syncing width 355. The fixed-size title and measured trailing-control padding impose a minimum width larger than the viewport when the sync control expands. The defect does not require a network request; changing only the control width reproduces it.

## Changes

- Momentum observes the generation of the successfully committed snapshot. The feed waits for the current load key, and the card only displays a feed produced for the committed generation. This also prevents an old feed from appearing between the snapshot commit and the next task execution.
- `AdaptiveHeaderLayout` keeps the title and individual controls within the offered width. When necessary, controls move below the title and wrap. The same view instances remain mounted while sync expands, preserving their animation/task state. The old asynchronous width-preference feedback loop is removed.
- Merged with the Liquid Today redesign of 2 October: its accessibility-size rule (the date needs the full width at accessibility text sizes) is kept as `AdaptiveHeaderLayout(stacksControls:)`, which places the controls below the title instead of measuring the control cluster and padding around it.
- Existing design tokens supply layout spacing. No UI strings or permissions are added.

## Validation

- The task-invalidation replay after the change reports 51/51 and 80/80.
- `LiquidMomentumRefreshTests` covers repeated navigation and snapshot commits with unchanged repository sequence.
- `AdaptiveHeaderLayoutTests` covers widths 288–398, five/six controls, compact/expanded sync, containment, overlap and a wide desktop header.
- The actual new SwiftUI layout was rendered at widths 288, 320, 361 and 398 with six controls in idle/sync states. All eight renders retained exactly the offered width. The 320-point sync render was visually inspected.
- macOS `Strand` build with the full `StrandTests` run: 3762 tests, 0 failures (3 skipped). iOS `NOOPiOS` simulator build: succeeded.

These are deterministic scheduling/layout reproductions and local builds, not a live test on the reporting iPhone. The rendering harness uses representative title/control content and the production layout. Real Bluetooth sync and provider traffic are not required for either reproduction.

## Dynamic Island / status-bar overlap

The scrolled screenshot additionally shows card text behind the status bar and Dynamic Island. This is distinct from the horizontal overflow. The tab root hides the navigation bar; Liquid Today has a full-bleed backdrop but no cover above scrolling content in the top system area.

The iOS scroll view now overlays the theme's opaque base surface in the device-reported top safe-area region. It neither intercepts gestures nor exposes an accessibility element. The inset comes from GeometryReader, not a hardcoded notch/Island height. This preserves the existing scroll content inset and pull-to-refresh behavior.

An isolated SwiftUI fixture with a supplied safe area and contrasting scroll-under content reproduced visible content in the top region. Before/after renders at top insets 0, 20, 47, 59 and 62 verify that the overlay covers the top region when present, leaves a zero-inset layout unchanged, and does not cover content below the inset. At 59 points, the sampled top pixel changes from content red to backdrop black. Both fixture images are retained under `artifacts/qa/today-2026-10-03`. A real-device scroll/rotation check remains necessary to verify the device's reported insets in the app's navigation host.

## Coach entry simplification

At the user's request, the redundant Coach avatar beside the profile button is removed from Liquid Today's header. Its now-unused settings toggle is removed as well. The independently configured Coach banner and floating button remain available. The legacy header-icon preference key remains only in the existing migration for compatibility; no current screen reads it. No preference or analysis migration is required.
