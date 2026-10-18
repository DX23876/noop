# Live Strength Workouts and Tracker Sources

NOOP uses one active-workout lifecycle for routine and freestyle sessions. A durable draft is written after each meaningful edit, resumed after interruption or relaunch and removed after successful completion. Drafts do not become completed history until at least one set is completed.

One physiology provider is selected for a workout. A NOOP band, Apple Watch workout session or another assigned tracker may supply heart rate; NOOP does not splice competing heart-rate segments into one apparently continuous measurement. HealthKit and tracker components may enrich duration and physiology, while the native set log remains the detailed strength source.

On iPhone and Apple Watch, the workout lifecycle covers start, pause, resume, background execution, interruption and completion. Heart-rate samples remain in their physiological store and are linked by session identity; they are not copied into every set or routine. Completion stores source, coverage and pause intervals and presents average and peak heart rate only when available.

Pausing the whole workout also pauses an active rest or timed-set timer and cancels its notification. The draft records that the workout owned this pause, so Resume restarts only that timer; a timer paused manually stays paused. This ownership survives relaunch and is cleared whenever the wearer manually resumes, cancels or replaces the timer.

Logging remains fully usable without heart rate, a network connection or downloaded media. A missing tracker lowers physiological coverage but never removes sets, notes or progression history.

**Analysis migration required: no.** Timer ownership is active-session lifecycle state; completed-set meaning and historical analysis are unchanged.

## Running workout and Lock Screen readout

The running logger and iOS Live Activity now resolve the next open set through the same session flow used by hands-free logging, including superset order. Both show the exercise, set number and available target values. The logger highlights the next set in the table and emphasizes its completion control. Weight and repetitions are typed into compact fields with the system number pad instead of plus and minus buttons, which stay available to VoiceOver as the adjustable action. A previous column shows the matching working set of the last session; tapping it copies those numbers into the set. Each exercise carries a rest chip that sets its rest after each set on a wheel for the rest of the session. The Live Activity offers set completion only when the set has values suitable for an unseen action; it checks the session and set identities again when the intent runs. Rest controls adjust by 15 seconds or skip the exact timer shown when tapped. The Lock Screen rest clock stays at zero after its deadline until the session moves on. [Hevy's public Live Activity guide](https://www.hevyapp.com/features/live-activity/) and [previous-values guide](https://www.hevyapp.com/features/track-exercises/) informed the choice of glanceable details and set context; no Hevy code or assets are included.

**Analysis migration required: no.** These are active-session controls and presentation changes; stored workout values and historical analysis are unchanged.
