# Live workout background test

Background behaviour cannot be proven in CI or the simulator: iOS only suspends, throttles or terminates
apps like this on a real device. This protocol checks that a cardio workout keeps recording while NOOP is
not in front, using the Workouts & GPS trace.

## Before

1. Install a Debug build on the iPhone and pair the strap.
2. Settings → Test Centre → enable **Workouts & GPS**.
3. Optional, iOS 26+: allow NOOP to share workouts in Health (Settings → Health → Data Access & Devices →
   NOOP). Without it the workout still records; the trace shows `systemSession result=notAuthorized`.

## Walk (about 20 minutes, outdoors)

| Minute | Action |
|---|---|
| 0 | Start **Walking** from Workouts or the quick action. Confirm the live screen shows time, heart rate and a growing distance. |
| 2 | Minimize the workout (chevron). The bar above the tab bar shows the elapsed time. |
| 3 | Open Apple Music or Podcasts and start playback. Stay there for 5 minutes. |
| 8 | Lock the phone for 5 minutes and keep walking. |
| 13 | Open the Camera app, take a photo, stay 1 minute. |
| 14 | Return to NOOP, pause for 1 minute, lock the phone, resume from the lock screen after unlocking. |
| 16 | Force-quit NOOP from the app switcher, reopen it after 30 seconds. The workout must be restored. |
| 20 | End the workout. |

## Pass criteria

- The saved route is continuous: no straight-line jump across the minutes spent in other apps or locked.
- Distance is close to the distance walked (compare with Apple Maps or a Watch).
- Heart-rate samples cover the background minutes: the Workouts trace shows no `gap stream=hr` longer
  than a few seconds outside the pause.
- The trace contains, in order: `session event=start`, `systemSession result=…`, `source metric=heartRate`,
  `source metric=location`, `appState event=background`, `appState event=foreground`,
  `session event=restored … routePoints=N` with N > 0 after the force-quit, and `session event=end`.
- No `location event=paused by=system` line appears.

After a force-quit the route recorded until the last journal write (at most 10 seconds) survives; heart rate
recorded by the strap during the minutes NOOP was not running is read back from the strap after the next
sync.

Report the exported strap log together with the result.
