# Reporting a problem on NOOP Forge for Android

NOOP Forge for Android is a released platform since 13.0 (28 November 2026), on the same shared core as the
iPhone and Mac apps. It is a young Android app, though, and it has met far fewer phones and straps than the
Apple apps. A report that says what happened and carries the strap log is the most useful thing you can give
the project: NOOP runs entirely on your phone, there is no server to look at, so everything a fix needs has
to be in the report.

## Install

1. On the [releases page](https://github.com/DX23876/noop_forge/releases), download the Android APK from
   the newest release.
2. Open it on the phone and allow installing from this source when Android asks.
3. Open NOOP Forge, accept the terms and go through the setup. It pairs your strap on the way.

Android 8 or later and a WHOOP 4.0, 5.0 or MG. Everything stays on the phone: no account, no server. The
[install guide](https://dx23876.github.io/forge/install/) on the project website has the same steps with
pictures. Android status and architecture: [`../../ANDROID.md`](../../ANDROID.md).

## What a useful report contains

- **The NOOP version** (Settings → About) and the phone: maker, model and Android version.
- **The strap model** (WHOOP 4.0, 5.0 or MG).
- **What you did, what you expected and what happened instead**, and roughly when it happened, so the right
  part of the log can be found.
- **The strap log**, which is the single most helpful attachment. Settings → **Help & Diagnostics** →
  **Share strap log**. Do it soon after the problem, while the relevant part is still in the log. The strap's
  serial number and Bluetooth addresses are masked, but have a quick look before you post it publicly.

Where to send it:

- **Inside the app:** Settings → Project → **Report a problem**. It can attach a log that you review first,
  and it can reach you with an answer. Nothing is sent until you press send; the switch **Send things from
  this device** (same page) stops it entirely.
- **On GitHub:** the **Android bug report** form of the
  [issue tracker](https://github.com/DX23876/noop_forge/issues/new/choose). Attach the strap log to the issue.
  For a bug that is not Android-specific the general bug form works as well.
- **Questions and "is this normal?":** [Discussions](https://github.com/DX23876/noop_forge/discussions).

Also say when something worked. "Pairing, live heart rate and the overnight sync worked on a Pixel 8 with a
WHOOP MG" is information the project does not have for most phones.

### The four things that matter most

If you are unsure what to look at, these four decide whether the app works on your phone. Each one can be
read from the app:

| | What | How you can tell |
|---|---|---|
| 1 | **Pairing** | More → Strap shows your strap as connected |
| 2 | **Live heart rate** | Today shows a heart rate card marked live while you wear the strap |
| 3 | **Overnight sync** | The next morning Today has Charge and Rest, and Sleep shows last night |
| 4 | **Reconnect** | Walk out of range for a few minutes, come back: the strap connects again by itself |

Many phone makers stop background apps aggressively. If the strap drops overnight, check the settings
**Keep connected in the background** and **Keep NOOP alive overnight** (Settings → Strap) and your phone's
own battery and auto-start settings before reporting; if it still drops, the strap log of that night is what
is needed.

## History is kept until the core stored it

The strap deletes a chunk of its history only after the app's shared core has saved it. This is always on. It
has not yet been verified on a real strap: please send the strap log of the first morning after a night with
the app. A line containing `holding ack` means the app could not save that chunk in time, so the strap keeps
it and sends it again. Nothing is lost.

## If something goes wrong

- **Settings → About → Classic screens** switches the app back to the earlier screens if a new one does not
  work for you; say which screen in your report.
- **Export backup** (Settings → Data & Backup) saves everything as a `.noopbak` file before you try something
  risky. Importing a large backup (a phone with months of history) can take many minutes; keep the app open
  until it finishes.
- A crash or a strap that will not connect: describe what you did and attach the strap log, as above.
- Never connect the strap to the official WHOOP app to "fix" it: on WHOOP 5.0 and MG that can update the
  firmware, and the update cannot be undone. See the [FAQ](../../FAQ.md#should-i-update-my-whoop-50-or-mg-firmware).
