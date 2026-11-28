# Muscle analytics methodology

NOOP uses one body renderer to answer three different questions about resistance training: how recent
work was distributed, how much recent training stimulus may remain, and where suitable exercises show
a clear strength trend. The three views share anatomy and input data, but their values are not added or
treated as interchangeable scores.

## Where it appears

The muscle analytics surface (`MuscleAnalyticsSurface`) is the **Muscles** page of the Strength page
(iPhone: Training › Strength › Muscles; the Mac shows it on its Strength page; Android has the same three
modes in `ForgeTrainingMuscles.kt`, with the shared figure). A control switches between **Balance**,
**Fatigue** and **Strength**, another between the front and the back of the body, and the figure can be
male or female (`training.bodyFigure`). Tapping a muscle opens its detail with the sessions and exercises
behind the value. The body geometry comes from the MIT-licensed MuscleMap package (credited on the page).
It needs no network, and the routine cards show small figures of the muscles a routine trains.

Beside it the Strength page keeps a separate load map over Hevy-style muscle groups with its own switch,
**Right now** (the default; what may still be on you) and **This week** (the calendar week against your
usual week). Tapping a group there lets the wearer say how recovered it feels, in four coarse answers;
that feeling can fit the personal decay time used by Muscle Fatigue. The feeling answer was not found on
Android. For exercises an import could not map, the Strength page lets the wearer choose primary and
secondary muscles once; the choice is kept as a mapping and never rewrites the original sets.

The older Lift Log screens are not reachable and are not part of this analysis.

## Shared input and coverage

All views read `resolvedStrengthHistory`, NOOP's de-duplicated strength history. It chooses one detailed
set log for each real workout and can use native NOOP, Hevy, Strong, FitNotes, Liftosaur and supported
file imports. Tracker and Apple Health records may enrich a session with physiology and duration; they
do not create another set list.

Reviewed exercise mappings connect each exercise to stable `TrainingMuscleCatalog` identifiers.
Primary muscles receive a weight of `1.0`, secondary muscles `0.5`, and stabilizers are descriptive
only. Warm-up sets remain in workout history but do not enter any of the three calculations. A set with
no reliable mapping stays unassigned and reduces the displayed mapping coverage. Missing RPE or RIR is
reported through coverage and handled by the existing stimulus or e1RM calculation; NOOP does not
invent a user rating.

The muscle views describe muscle groups over time. They do not compare the left and right side of a
muscle.

## Muscle Balance

**Question:** How was recent effective strength work distributed, and is that distribution unusual for
this wearer?

NOOP sums effective working-set stimulus over the previous 28 days. The set stimulus already accounts
for recorded effort and relative load where those inputs are available. It is credited fully to primary
muscles and by half to secondary muscles, then expressed as each muscle's share of all mapped work.

When NOOP has the complete preceding eight weeks, it calculates the muscle's share for each week and
uses the median as the personal reference. Median absolute deviation describes the wearer's ordinary
week-to-week variation. Until that history exists, the view says that the baseline is growing and shows
the current distribution without manufacturing a reference range.

Balance does not prescribe a universal ideal, diagnose an imbalance or imply that equal coloring is a
training goal. Exercise selection, anatomy, rehabilitation needs and sport goals can all make an uneven
distribution appropriate. A zero means no mapped effective work in the selected window; unknown work
is shown separately in coverage.

## Muscle Fatigue

**Question:** How much estimated stimulus from recent strength work may still remain for each muscle?

Each working set contributes its effective stimulus to primary and secondary muscles. The contribution
then decays exponentially with time. NOOP uses the existing muscle-stimulus recovery model: a personal
decay time is fitted when enough explicit muscle feedback exists, otherwise the documented muscle-group
default is used. The result is divided by the wearer's typical non-zero session stimulus for that muscle
and capped for display on the body map. The drilldown exposes the decay basis and contributing sessions.

This value is a model estimate. It does not measure tissue recovery, readiness, soreness, injury risk or
whether the muscle is safe to train. Sleep, nutrition, illness and many local factors are outside this
calculation.

## Muscle Strength

**Question:** For which muscles do suitable exercises provide a clear longitudinal strength signal?

Only e1RM-capable working sets with at most 12 repetitions are eligible. When RPE is present, NOOP uses
its existing RPE-to-RIR correction before estimating one-repetition maximum. At most one best e1RM point
per exercise and session enters the trend. An exercise needs at least four session points, and NOOP uses
the robust Theil-Sen slope plus its existing uncertainty check.

Every eligible exercise slope is divided by that exercise's own median e1RM. NOOP then combines the
normalized exercise evidence for a muscle with a robust weighted median: primary-muscle evidence has
weight `1.0` and secondary evidence `0.5`. This keeps a large barbell lift and a smaller isolation lift
on comparable relative scales. Their kilograms are never added. Timed, distance and repetitions-only
movements remain visible in history but cannot color the Strength map. If the evidence is sparse or its
direction is unclear, the muscle is shown as not assessable rather than as strong, weak or unchanged.

Muscle Strength is a trend in mapped exercise performance. It does not measure a muscle's isolated
force, size, symmetry, neural capacity or future performance.

## Storage and recalculation

The three views store no second workout, exercise or muscle database. They are derived at read time from
bounded windows of canonical history and may use only bounded in-memory caches. Corrections to exercise
mapping can therefore update past displays without mutating the original workout sets.

**Analysis migration required: no.** These views do not change stored daily analysis, source precedence
or the meaning of existing persisted values.
