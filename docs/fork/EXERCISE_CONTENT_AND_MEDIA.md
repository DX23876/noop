# Exercise Content and Media

NOOP's canonical exercise catalogue owns exercise identity, measurement mode, equipment and muscle mapping. Provider names, translated aliases and imported exercise identifiers resolve into that catalogue; they do not form a second exercise database.

The shipped catalogue is ExerciseDB v1 via `hasaneyldrm/exercises-dataset`, pinned to one immutable revision and normalized into NOOP's own domain by `Tools/build_exercise_catalog.py`: 1,324 exercises with NOOP muscle ids, canonical equipment ids, measurement mode, load semantics, unique aliases, English instructions, attribution and content version. That repository's `LICENSE` and `NOTICE.md` place the exercise DATA under the MIT licence. The generator refuses to write a catalogue that fails validation, and `BundledExerciseCatalogTests` runs the same checks on the shipped file.

Instructions and media are separate provenance domains. Workout and routine rows store canonical exercise identifiers, never image or animation bytes. Exercise logging, routine editing and all analytics work without media.

Optional media is downloaded only after an explicit user action, directly from the disclosed external upstream source into private Application Support storage. Before download, NOOP shows the source, attribution, known rights status, approximate size and that the download creates no additional licence through NOOP. NOOP does not bundle, host, mirror or proxy the pack.

The provider is replaceable and centrally disableable: `ExerciseMediaProvider` hides the source from every view, `ExerciseMediaRegistry` resolves media by exercise and holds the withdrawal list, and `NoMediaProvider` makes "no media" an ordinary state.

A pack is transferred by a background session with progress, cancel and resume. Installation runs off the main actor and validates in order: SHA-256 of the archive against a published digest where one exists, every entry's path, the 200 MB limit, and enough free space to leave 50 MB on the device. Only then is the staged version activated atomically; a failure keeps the working version. The manifest stores provider, source, attribution, rights holder and status, the archive digest and every file with its size and digest — provenance, not a second exercise database.

Animated images play frame by frame, videos play muted and looping, and Reduce Motion holds the first frame. Downloaded files are excluded from backup and can be deleted. Failure falls back from animation to image, muscle information and finally text without blocking training.

