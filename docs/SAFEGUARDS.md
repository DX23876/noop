# GitHub and release safeguards

NOOP previously experienced an automated GitHub suspension that was reversed on appeal. This fork
therefore keeps repository automation deliberate, bounded, and auditable without pretending GitHub
Actions is disabled.

## Current policy

1. **No promotional bulk activity.** Donation or crypto addresses belong only in canonical project
   pages, never in repeated issue, PR, or comment replies.
2. **No mass-identical comments.** Batch maintenance should vary wording where a human response is
   appropriate and avoid bursts that look automated or inauthentic.
3. **Throttle API operations.** Prefer bounded reads and a small number of intentional writes. Do not
   create a stream of tiny commits, releases, issues, or comments when one grouped operation works.
4. **Batch releases.** Release meaningful groups of changes rather than drip-shipping. The maintainer
   helper `Tools/release.sh` retains its cadence guard for scripted releases.
5. **GitHub Actions is enabled and scoped.** Current workflows live in `.github/workflows/`.
   Package/i18n/source checks run on their declared triggers; app and release builds are manual or
   release-scoped. Release workflows receive `contents: write` only where they must create assets or
   update `altstore-source.json`.
6. **Pin and review automation.** Changes to action versions, permissions, release assets, or bot
   pushes deserve the same review as application code. Avoid unnecessary third-party actions.
7. **Do not evade enforcement.** If GitHub restricts the repository or account again, stop automated
   writes and appeal through GitHub Support. Do not create replacement accounts or bypass controls.

## Release-specific checks

- Publish this fork only under the `v<VERSION>-dx` namespace.
- Dispatch `publish-ios-release.yml` from `main` with a version already present in `project.yml`
  and `docs/fork/releases/v<VERSION>.md`.
- Verify that both iOS IPAs and the macOS ZIP exist before treating a release as complete.
- Verify the release is public/latest and that the workflow's manifest-only commit placed the new
  version at the top of `altstore-source.json`.

See [build and release instructions](BUILD.md#publish-an-unsigned-apple-release) and the
[fork CI guide](FORK_GUIDE.md#ci-actually-runs-here).
