# NOOP Forge 13: testing build

This is the testing build of **NOOP Forge 13**, not a release yet. iPhone, Mac and **Android** now run on one
shared analysis core, so all three need testing. On iPhone and Mac it installs over NOOP Forge and keeps your
data. The full list of changes is in the
[release notes](https://github.com/DX23876/noop/blob/main/docs/fork/releases/v13.0.0.md).

NOOP Forge is an independent fork of NOOP by ryanbr, not the official app. Offline, on your device, no account,
no server.

> **Before you update:** make a backup (**Settings → Backup & Sync → Back up now**). This build recalculates your
> whole history once, and a backup is the way back if something looks wrong afterwards.

## Downloads

| | File | How |
|---|---|---|
| **iPhone / iPad** | `NOOP-ios-unsigned-v13.0.0.ipa` | AltStore or SideStore. Replaces the installed NOOP Forge |
| **iPhone + Watch + widgets** | `NOOP-ios-full-unsigned-v13.0.0.ipa` | Needs provisioning for every embedded target |
| **Mac** | `NOOP-macos-v13.0.0.zip` | Unzip, then **right-click, Open** (ad-hoc signed, Gatekeeper warns once). If it says *"damaged"*, run `xattr -dr com.apple.quarantine /Applications/NOOP.app` |
| **Android** | `NOOP-Forge-android-13.0.0-testing.apk` | Android 8 or later. Open the file on the phone and allow installing from this source |

To go back on iPhone or Mac, install the latest release again.

## What to test

### 1. The one recalculation (most important)

After the update NOOP scores every day with raw strap data again and rebuilds every derived value from the
stored inputs. This happens once.

| What to do | What should happen |
|---|---|
| Open NOOP and keep it open on the charger | The recalculation runs. With months of history it can take a while |
| Close NOOP halfway through, open it again | It continues where it stopped instead of starting over |
| When it has finished, close and open NOOP | It does **not** start again |
| Compare a few days you remember | Charge, Rest and sleep times look plausible. Your own entries (corrected bed and wake times, logged workouts, journal) are unchanged |

Please tell us roughly how long it took and how many months of history you have.

### 2. Effort, recalibrated

| What to do | What should happen |
|---|---|
| Look at a quiet day without a workout | Effort is clearly lower than before. Standing and walking around no longer add up to a moderate day |
| Look at a hard training day | Effort is higher than before. A brisk 30-minute walk lands around 32, an hour of hard cardio around 80 |
| **Settings → Profile → Max heart rate** | It says where the value comes from (formula, measured in workouts, or your own). An entered value always wins |
| Mark a detected workout as "not a workout" | That day's Effort does not count those minutes any more |
| Check today's Effort after a sync, and again the next day | Yesterday's value does not drop once it becomes history |
| **Settings → Lab → Strength in Effort** (optional) | Log a strength session (NOOP's logger or Hevy) and rate it afterwards: it adds to that day's Effort. Unrated sessions add nothing |

If you also wear the WHOOP app, a screenshot of WHOOP's Strain next to NOOP's Effort for the same day helps a
lot.

### 3. Sleep

| What to do | What should happen |
|---|---|
| Look at the last few nights | The start of the night is not pulled earlier by quiet spells before you fell asleep |
| Respiratory rate over two weeks | It varies from night to night instead of sitting near 14.1 again and again |
| A night where the strap lay on the table for a while | That time is not counted as sleep |
| A wrongly detected nap: its menu → **Delete nap** | It goes away after a confirmation, with a few seconds of undo. The main night keeps its numbers |

### 4. Sync and connection

| What to do | What should happen |
|---|---|
| Normal overnight sync | The next morning everything is there, without gaps |
| Turn Bluetooth off during a sync, wait a minute, turn it on | NOOP reconnects by itself and the sync finishes. No data is missing afterwards |
| Sync with the strap off your wrist | No message telling you to charge the strap |

### 5. WHOOP MG only: ECG

| What to do | What should happen |
|---|---|
| Take an ECG reading | It records to the end, the result is shown and saved |
| Sync afterwards | Nothing unusual. Please send the strap log of that day |

### 6. Android

The Android app is new for almost everyone, and in this build it runs entirely on the shared core: there is no
separate Android database any more. Everything it stores and every score it shows comes from the same code as the
iPhone. It stays labelled as testing until testers on different phones have confirmed these, each with a strap log
from that day (**More → Settings → Diagnostics → Share strap log**):

| | What | How you can tell |
|---|---|---|
| 1 | **Updating over an older Android NOOP** (ryanbr's app or an earlier Forge build) | The first start shows *Updating your data* for a moment, then the app restarts and your history is there |
| 2 | **Restoring an old Android backup** (a `.noopbak` from ryanbr's app or an earlier Forge build) | **Settings → Data & Backup → Import** accepts it; after the restart your history is there |
| 3 | **Pairing** | More → Strap shows your strap as connected |
| 4 | **Live heart rate** | Today shows a heart rate card marked live while you wear the strap |
| 5 | **Overnight sync** | The next morning Today has Charge and Rest, and Sleep shows last night. The strap only clears its memory once the data is safely stored |
| 6 | **Reconnect** | Walk out of range for a few minutes, come back: the strap connects again by itself |
| 7 | **Backups** | **Settings → Data & Backup**: Export, Import and Automatic backups are the only backup buttons, and an exported file restores on another phone |
| 8 | **Imports** | A WHOOP export, Apple Health export or another wearable's export reads the same days and values as on an iPhone |

Beyond that, have a look around: Today, Trends, Training (exercise library, live strength workout), Sleep, the
Coach, Goals and More → Health & Body. If a number differs from what an iPhone shows for the same data, or a
page does not open, say which page and what you saw. More in the
[Android testing guide](https://github.com/DX23876/noop/blob/main/docs/fork/android/TESTING.md).

### 7. Other things worth a look

- **Apple Health:** resting heart rate, HRV, SpO₂ and respiratory rate of a night appear inside that night,
  not at the moment you woke up.
- **Momentum:** the week's sleep debt shows as one card, not as a note and an action at the same time.
- **Habit patterns** (journal): fewer rows marked as clear; the ones left should be the real ones.
- **AgeLess** (Lab, WHOOP 4.0): you now get an age, or a line that names what is missing.
- **Body fat and lean mass** from a scale that writes to Apple Health show on the Body page and in Energy.
- **Widgets:** with a sideload signer that cannot share data, the widget says so instead of showing empty rings.

## How to report

Open an issue on [DX23876/noop](https://github.com/DX23876/noop/issues/new/choose) with:

- your phone model and system version (iOS or Android), and your strap (4.0, 5.0 or MG)
- what you did and what you saw, with a screenshot where it helps
- the strap log of that day (iPhone: **Settings → Diagnostics**; Android: **More → Settings → Diagnostics → Share strap log**)

**Also tell us when everything worked.** That counts as much as a bug. Thank you for testing ❤️

