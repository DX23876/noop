# Android Momentum presentation

References: `Strand/Screens/MomentumCard.swift`, `MomentumView.swift` and Today's `momentumSection`.
The job is a compact current priority on Today and the complete ranked feed one tap away. Swift owns
eligibility, ranking, wording, dwell, snoozing and progress; Compose presents the returned facts.

The compact card opens the full page. Hiding the current message uses the core's logical-day rule and
refreshes from the core only after success. The full page distinguishes loading, read failure and an
honestly empty feed, and offers retry after failure. Text wraps with system font size. Forge tokens own
spacing, type, colors and hit targets; the headline and explanatory text carry meaning without color.

The goal action opens the real Goals page. Charge breakdown, Coach plans and live-session actions stay
hidden until those destinations can be served by this host, following MomentumView.availableDestinations.
A demo arm64 API 35 emulator run verifies Today and More entry points, the full feed, the Goals action,
back navigation, and hiding the leading message across a process restart. Screens were inspected at
normal and 130 percent system font size; the scene subtitle uses scene ink for contrast. Loading was
observed during refresh; malformed bridge replies are covered by two parser tests. Empty/read-failure
rendering, more screen sizes and physical-device acceptance remain pending. Core, Room, preferences and
DataStore were restored from the pre-test snapshot and every file hash was checked afterward. The
original system font scale was restored too. The logical-day polling uses a cheap core clock read, so
Android does not duplicate the 04:00 rollover rule. Analysis migration required: no; this is host
presentation and bookkeeping over the shared model.
