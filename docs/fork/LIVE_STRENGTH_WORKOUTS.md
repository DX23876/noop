# Live Strength Workouts and Tracker Sources

NOOP uses one active-workout lifecycle for routine and freestyle sessions. A durable draft is written after each meaningful edit, resumed after interruption or relaunch and removed after successful completion. Drafts do not become completed history until at least one set is completed.

One physiology provider is selected for a workout. A NOOP band, Apple Watch workout session or another assigned tracker may supply heart rate; NOOP does not splice competing heart-rate segments into one apparently continuous measurement. HealthKit and tracker components may enrich duration and physiology, while the native set log remains the detailed strength source.

On iPhone and Apple Watch, the workout lifecycle covers start, pause, resume, background execution, interruption and completion. Heart-rate samples remain in their physiological store and are linked by session identity; they are not copied into every set or routine. Completion stores source, coverage and pause intervals and presents average and peak heart rate only when available.

Pausing the whole workout also pauses an active rest or timed-set timer and cancels its notification. The draft records that the workout owned this pause, so Resume restarts only that timer; a timer paused manually stays paused. This ownership survives relaunch and is cleared whenever the wearer manually resumes, cancels or replaces the timer.

Logging remains fully usable without heart rate, a network connection or downloaded media. A missing tracker lowers physiological coverage but never removes sets, notes or progression history.

**Analysis migration required: no.** Timer ownership is active-session lifecycle state; completed-set meaning and historical analysis are unchanged.

## Running workout and Lock Screen readout

The running logger and iOS Live Activity now resolve the next open set through the same session flow used by hands-free logging, including superset order. Both show the exercise, set number and available target values. The logger highlights the next set in the table and emphasizes its completion control. Weight and repetitions are typed into compact fields with the system number pad instead of plus and minus buttons, which stay available to VoiceOver as the adjustable action. A previous column shows the matching working set of the last session; tapping it copies those numbers into the set. With the optional media pack installed, a still sits beside each exercise title and tapping it opens or closes the full demonstration, so the sets stay in view by default. Each exercise carries a rest chip that sets its rest after each set on a wheel for the rest of the session. The Live Activity offers set completion only when the set has values suitable for an unseen action; it checks the session and set identities again when the intent runs. Rest controls adjust by 15 seconds or skip the exact timer shown when tapped. Once a rest runs out the Lock Screen drops it and offers the next set; a suspended app cannot refresh it, so there the rest clock holds at zero until NOOP runs again. [Hevy's public Live Activity guide](https://www.hevyapp.com/features/live-activity/) and [previous-values guide](https://www.hevyapp.com/features/track-exercises/) informed the choice of glanceable details and set context; no Hevy code or assets are included.

**Analysis migration required: no.** These are active-session controls and presentation changes; stored workout values and historical analysis are unchanged.

## Hevy-style logger layout

The running logger opens on all exercises by default; a layout chosen before keeps its choice. One slim header row carries duration, volume, completed sets and, with a source, the live heart rate, which opens the full heart-rate view on a tap. Volume counts completed working sets with a load: warm-ups, plain bodyweight and assistance stay out, and a weighted bodyweight set counts its added load. In the list, finishing an exercise scrolls to the next one, except between exercises of one superset. Rest, note and progression sit in one row of small buttons; the note is written in its own sheet and shown under the exercise title. Set numbers sit in small boxes: every warm-up reads "W" and working sets count from one, on the Lock Screen too. The number pad carries the plate calculator while a weight is typed. Prefilled values read grey until they are typed, copied from the previous column or the set is completed; that state is kept beside the running draft so a relaunch keeps it. The exercise name opens the library's exercise page.

**Analysis migration required: no.** Presentation and active-session state only; stored workout values and historical analysis are unchanged.

## Adding and removing sets mid-session

An exercise without history starts with three working sets when added to a running session; Settings › Training changes the number from one to six. Each exercise card, the compact one included, carries a full-width Add set button, also once the exercise is complete, so an extra set after moving on needs no new exercise. A set goes by swiping its row to the left and tapping the revealed delete button, for "too tired for the third". The only set of an exercise cannot be removed, by swipe or from the set menu; an exercise with no sets left is removed as an exercise from its menu.

**Analysis migration required: no.** Session editing only; completed-set meaning and historical analysis are unchanged.

## One set number everywhere

The logger's set column, its previous column, the Lock Screen, the Watch and the strap and Watch notices name a set through one resolver: working sets count from one past the warm-ups, and a drop or rest-pause segment takes no number of its own. The previous column lines last session's sets up by that number, so a drop segment in the last session no longer shifts the sets after it. Copying a previous unilateral set keeps a side the last session has no number for. Typing a value, the suggested one included, makes it the lifter's own. The header's volume is rounded in the unit it is shown in. The end-of-rest haptic no longer depends on the rest dock, which the number pad's bar replaces while a value is typed.

**Analysis migration required: no.** Active-session readouts, haptics and Lock Screen state only; stored workout values and historical analysis are unchanged.
