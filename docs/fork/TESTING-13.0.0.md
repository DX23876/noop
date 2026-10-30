# Testing NOOP Forge 13

This is the testing build of NOOP Forge 13, not a release yet: iPhone, Mac and Android now run on one shared core, so all three need testing. It installs over NOOP Forge and keeps your data. The
full list of changes is in the [release notes](releases/v13.0.0.md). Thank you for trying it before everyone
else does.

**Before you update:** make a backup (**Settings → Backup & Sync → Back up now**). This build recalculates your whole
history once, and a backup is the way back if something looks wrong afterwards.

## Install

- **iPhone (AltStore or SideStore):** `NOOP-ios-unsigned-v13.0.0.ipa` from the
  [testing release](https://github.com/DX23876/noop/releases/tag/testing-latest). It replaces the installed
  NOOP Forge.
- **Mac:** `NOOP-macos-v13.0.0.zip`, unzip, then right-click, Open.
- **Android:** still in its own testing round, see [`android/TESTING.md`](android/TESTING.md).

## 1. The one recalculation (most important)

After the update NOOP scores every day with raw strap data again and rebuilds every derived value from the
stored inputs. This happens once.

| What to do | What should happen |
|---|---|
| Open NOOP and keep it open on the charger | The recalculation runs. On a phone with months of history it can take a long while |
| Close NOOP halfway through, open it again | It continues where it stopped instead of starting over |
| When it has finished, close and open NOOP | It does **not** start again |
| Compare a few days you remember | Charge, Rest and sleep times look plausible. Your own entries (corrected bed and wake times, logged workouts, journal) are unchanged |

Please tell us roughly how long it took and how many months of history you have.

## 2. Effort, recalibrated

| What to do | What should happen |
|---|---|
| Look at a quiet day without a workout | Effort is clearly lower than before. Standing and walking around no longer add up to a moderate day |
| Look at a hard training day | Effort is higher than before. A brisk 30-minute walk lands around 32, an hour of hard cardio around 80 |
| **Settings → Profile → Max heart rate** | It says where the value comes from (formula, measured in workouts, or your own). An entered value always wins |
| Mark a detected workout as "not a workout" | That day's Effort does not count those minutes any more |
| Check today's Effort after a sync, and again the next day | Yesterday's value does not drop once it becomes history |
| **Settings → Lab → Strength in Effort** (optional) | With it on, a rated strength session adds to its day's Effort. Without a rating nothing changes |

If you also wear the WHOOP app, a screenshot of WHOOP's Strain next to NOOP's Effort for the same day helps a
lot.

## 3. Sleep

| What to do | What should happen |
|---|---|
| Look at the last few nights | The start of the night is not pulled earlier by quiet spells before you fell asleep |
| Respiratory rate over two weeks | It varies from night to night instead of sitting near 14.1 again and again |
| A night where the strap lay on the table for a while | That time is not counted as sleep |
| A wrongly detected nap: its menu → **Delete nap** | It goes away after a confirmation, with a few seconds of undo. The main night keeps its numbers |

## 4. Sync and connection

| What to do | What should happen |
|---|---|
| Normal overnight sync | The next morning everything is there, without gaps |
| Turn Bluetooth off during a sync, wait a minute, turn it on | NOOP reconnects by itself and the sync finishes. No data is missing afterwards |
| Sync with the strap off your wrist | No message telling you to charge the strap |

## 5. WHOOP MG only: ECG

| What to do | What should happen |
|---|---|
| Take an ECG reading | It records to the end, the result is shown and saved |
| Sync afterwards | Nothing unusual. Please send the strap log of that day |

## 6. Other things worth a look

- **Apple Health:** resting heart rate, HRV, SpO₂ and respiratory rate of a night appear inside that night,
  not at the moment you woke up.
- **Momentum:** the week's sleep debt shows as one card, not as a note and an action at the same time.
- **Habit patterns** (journal): fewer rows marked as clear; the ones left should be the real ones.
- **AgeLess** (Lab, WHOOP 4.0): you now get an age, or a line that names what is missing.
- **Body fat and lean mass** from a scale that writes to Apple Health show on the Body page and in Energy.
- **Widgets:** with a sideload signer that cannot share data, the widget says so instead of showing empty rings.

## Reporting

Open an issue on [DX23876/noop](https://github.com/DX23876/noop/issues) with:

- iPhone model, iOS version, strap (4.0, 5.0 or MG)
- what you did and what you saw, a screenshot where it helps
- the strap log of that day (**Settings → Diagnostics**)

Also tell us when everything worked: that counts as much as a bug.
