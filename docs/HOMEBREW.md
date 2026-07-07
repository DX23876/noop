# Homebrew Cask (macOS)

macOS users install + auto-update NOOP with:

```bash
brew tap noopapp/noop
brew trust noopapp/noop    # required since Homebrew 6.0.0 (see note below)
brew install --cask noop
brew upgrade --cask noop   # later updates
```

The cask lives in the **`NoopApp/homebrew-noop`** tap on GitHub and points at the macOS `.zip`
attached to each release.

> **Why `brew trust`?** Since **Homebrew 6.0.0** (June 2026), non-official taps must be explicitly
> trusted before Homebrew will load their code — otherwise you'll see
> `Error: Refusing to load cask noopapp/noop/noop from untrusted tap`. Trust is a one-time,
> per-machine decision (publishers can't pre-trust their own tap — only Homebrew's official taps are
> trusted by default). Trust the whole tap with `brew trust noopapp/noop`, or just our cask with
> `brew trust --cask noopapp/noop/noop`. It's the Homebrew equivalent of the Gatekeeper
> right-click-Open below: you're vouching for code you can read — the cask is one short file in the
> public tap, and the app's full source is in this repo.

> **Unsigned-app note.** NOOP ships anonymously with no Apple Developer ID, so it isn't notarized.
> Homebrew can't strip the quarantine flag for an un-notarized app, so on **first launch** Gatekeeper
> blocks it. On **macOS 15 Sequoia and later**: try to open NOOP once, then **System Settings →
> Privacy & Security**, scroll down, and click **"Open Anyway"** next to NOOP. (On macOS 14 and
> earlier you can right-click NOOP in `/Applications` → **Open** → **Open**.) The cask's `caveats`
> says this. Updates after that are just `brew upgrade`.

## How it stays current

The cask is refreshed **as part of cutting each macOS release** — the last step of the release process
runs:

```bash
Tools/update-homebrew-cask.sh <version>     # e.g. Tools/update-homebrew-cask.sh 1.95
```

That script computes the release zip's SHA256, regenerates `Casks/noop.rb`, and pushes it to the tap.
There is **no GitHub Actions workflow / repo secret** — releases are cut by hand, so the cask update
rides along with them. Fewer secrets, nothing to fail, one less surface to keep anonymous.

## Requirements

- The tap repo **`NoopApp/homebrew-noop`** exists (public). ✅ done.
- The NoopApp PAT at `~/.config/noop/gh_token` (the same one used to push releases) has
  **Contents: Read and write** on `homebrew-noop`. The script reads the token from that file and
  supplies it through a transient git credential helper, so **the token never appears on a command
  line, in a remote URL, or in any output** (a clean remote URL is used for clone + push).

## Anonymity checklist

- Tap repo + commits under the anonymous **NoopApp** identity (the script commits as
  `NoopApp <thenoopapp@gmail.com>`).
- Token read from the local file only; never echoed. Scope it to the repos it needs and no more.
- The cask installs the **already-anonymized** release zip (scrubbed by `Tools/anonymize-macos-app.sh`
  at build time) — no new surface.
