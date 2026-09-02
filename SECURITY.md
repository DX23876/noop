# Security Policy

## Scope

NOOP is an offline-by-default, on-device app. It operates no servers, accounts,
cloud sync, or telemetry, so the usual hosted-service attack surface does not apply.
What remains is local or explicitly user-configured:

- **Bluetooth Low Energy** — the link to your WHOOP strap.
- **Local SQLite database** — every reading is stored on your own device.
- **File imports** — WHOOP CSV exports and Apple Health ZIP files you choose to open.
- **AI Coach (optional, off by default)** — sends a compact summary only when asked,
  with credentials you supply, to the provider you choose.
- **Self-hosted push (Experimental, Android, off by default)** — sends versioned batches
  one way to a user-owned endpoint after offload; it never reads records back and never
  participates in strap sync. A receiver can only narrow the fixed stream registry it accepts.
  See [`docs/PUSH_PROTOCOL.md`](docs/PUSH_PROTOCOL.md).
- **Oura history import (compile-time optional)** — pulls from Oura using a developer
  application and grant supplied by the user; it is absent from default builds.

A useful security report is one that lets data leave the device without the corresponding opt-in,
lets a malicious strap or crafted import file corrupt the database or run code, or
otherwise breaks the offline-by-default or one-way-export guarantees the app makes.

## Reporting a vulnerability

NOOP is maintained anonymously and has no security contact email. **Report
security issues through GitHub's Private Vulnerability Reporting** — Security →
Report a vulnerability. That keeps proof-of-concept details out of public view
until a fix ships, and needs no email address on either side.

One advisory per finding is easiest to triage; group them only if they share a
root cause.

A public issue is fine as a fallback — for anything low-risk, or if private
reporting is unavailable to you. If a public report would put users at immediate
risk before a fix can ship, open it with a short, non-exploitable summary (what
is affected and how severe) and hold the proof-of-concept until a fix is released.

Please include, as far as you can without putting anyone at risk:

- A description of the issue and the guarantee it breaks
- Steps to reproduce
- The potential impact
- A suggested fix, if you have one

Because there is no staffed inbox, response times depend on maintainer
availability — there is no guaranteed SLA. Confirmed issues are prioritised for
the next release.

## Supported versions

Only the latest release receives fixes. NOOP ships from source; if you build your
own copy, rebuild from the latest tag to pick up security fixes.

## Out of scope

- Vulnerabilities that require physical access to an already-unlocked device
- Issues in third-party dependencies — please report those upstream (see
  [`NOTICE`](NOTICE) for the bundled libraries and their licences)
- The WHOOP strap firmware itself, which NOOP does not ship or modify
- The user's own API key being misused after they have entered it (the key is
  stored in the platform keystore; protecting the device account is the user's job)
