# Scope & non-goals

NOOP exists to give you **your own strap data, offline and on-device**. That mission sets hard limits
on what belongs in the app. This page names the WHOOP-app features that stay **out of scope** — and the
local equivalents that stay **in scope** — so a parity proposal has a standing answer before a PR is
opened. It does not change the constraints stated in [AGENTS.md](../AGENTS.md), the
[Contributing guide](CONTRIBUTING.md), or the [Disclaimer](../DISCLAIMER.md); it maps them onto specific
features so the boundary is discoverable.

## The constraints this follows from

NOOP is **offline-first, on-device, and anonymous**: no NOOP server, account, cloud sync, or telemetry,
and **not a medical device** (see the [Disclaimer](../DISCLAIMER.md#5-not-a-medical-device)). The
user-controlled exceptions are narrow: Coach requests go directly to the configured provider, a
source-built Oura lane imports data from the user's own account, an opt-in Hevy lane imports the user's
own strength training from theirs, an explicit download fetches the optional exercise media pack or
exercise definitions from a source the user picks, the update checker reads public GitHub release
metadata manually or, when enabled, at most once per day, and the in-app Project page (Roadmap, Problems,
Wishes) reads two public files from this repository while it is open (`docs/roadmap.json`, `docs/app-feed.json`). The Android
app (released with 13.0) adds the default-off Experimental self-hosted push from #1314; it exists on
Android only, there is no such export on iPhone, iPad or Mac. These are hard boundaries, not permission to
add general cloud features. The food log adds one more, default off: after the wearer chooses, branded
products come either from Open Food Facts' public search (search words and barcodes only, no account) or
from country packs downloaded as public files from this repository's `food-packs` release; with no choice
nothing leaves the phone (decision 2026-11-08).

**Sending things from this device.** The Project page can also send, but only when the person acts: a vote
on a roadmap item, a wish, a problem report (optionally with a redacted log they review first) and, from
Help build it, a short recording of raw wrist motion for a sport detector. Nothing is sent at install, in
the background or by default, the project hosts no account for it (a random device key with no identity
only stops a second vote), and the one switch **Send things from this device** turns every one of these
off, the donation included. This is a feedback channel, not health-data sync: apart from a motion recording the person chose to
donate, it carries no scores, sleep or database. It exists on every platform, and the strap log of a problem report leaves only
after the person has seen what it contains.

Each exception shares one shape, which is what makes it an exception rather than a precedent: the
user's own account or an explicit action, their own credential, no hosted copy of the user's health data, and default off or not sent until the user acts. The media pack, the project feed
and the update check need no account, but keep the rest: inbound only, no health data sent. The
self-hosted push is the one continuous outbound stream, one way to an endpoint the user owns and
configures, Android only and Experimental. The Hevy lane adds an outbound write in the app, a training
routine the coach drafted, and it is gated the same way every irreversible action here is: a review screen
showing exactly what would change, and a button the person has to press.

## Out of scope

These are features of the WHOOP app that conflict with the constraints
above. They are out of scope **unless the project deliberately changes its scope** in a tracked issue.

| Feature (WHOOP parity) | Why it's out of scope | Ref |
|---|---|---|
| Possible-arrhythmia / diagnostic-style alerts | A medical-device-style claim. NOOP is explicitly **not a medical device** and must not tell a user they may have a health condition. | #752 |
| Community feeds, team chat, social graph, leaderboards, cloud messaging | Require a **server, accounts, and an identity** — the opposite of anonymous and offline. | #755 |
| Cloud- or account-dependent coaching / notification parity | Requires cloud identity and server sync. NOOP's coach is strictly bring-your-own-key and on-device. | — |
| Anything requiring telemetry, server sync, user identity, or medical claims | Fails a hard constraint directly. | — |

## In scope — the local, non-diagnostic equivalents

The point of a boundary is to say what *is* welcome. These stay in scope because they run entirely
on-device from NOOP's own data and make no medical claim.

- **Local rhythm instrumentation.** Surfacing RR/IBI or beat-to-beat variability for the user's own
  curiosity is fine **only** as **default-off instrumentation** with explicit **non-diagnostic** wording
  — never an alert, never a health warning, never "possible arrhythmia" language, and never feeding a
  downstream gate. This mirrors the physiological-signal rule in
  [AGENTS.md](../AGENTS.md): an unproven derivation lands as instrumentation, not a shipped feature.
- **Local notifications from NOOP's own metrics** — charge, alarm, sync state — computed on-device.
- **Local export / import / reporting** — your data leaves only when *you* export it.
- **Offline insights and explainers** that need no cloud identity.

## Proposing a scope change

Scope changes are deliberate, not incidental. If you believe one of the out-of-scope areas should move,
open an issue that names the constraint it touches and how it would be satisfied — don't open the PR
first. A "WHOOP has it" argument, on its own, is not a reason: NOOP is a clean-room, offline-first, anonymous
tool, not a WHOOP clone.
