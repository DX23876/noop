# Design & architecture decisions

The durable record of redesign decisions, so a question settled once isn't re-litigated later. One row
per decision. Supersedes any conflicting rows in `redesign-prompts.md` (the original handoff doc, kept
for its screen specs but written against an upstream-close fork whose assumptions no longer hold).

| Date | Decision | Why |
|---|---|---|
| 2026-07-23 | iOS/macOS-only; stop necessarily tracking upstream | Android target dropped; the fork is 779 commits ahead / 0 behind and diverges freely now |
| 2026-07-23 | Cross-platform parity contract (byte-identical analytics, FNV-1a hashing, Room/GRDB agreement) is **retired** | No Android reimplementation to stay in sync with. Offline / no-server / no-account / anonymous constraints are separate and still binding |
| 2026-07-23 | Redesign evolves existing shared screens + Palette **in place** (not additive new files under StrandiOS/Redesign/) | StrandDesign is already forked (gold→blue); screens are shared Strand/ code; LiquidTodayView already implements the mockup's core. Additive files would duplicate shared logic and stand up a second redesign |
| 2026-07-23 | Briefing palette (green Charge / blue Effort / violet Rest / gold Longterm) ships as a **new selectable `ChartStyle` ("Signature"), defaulted on** | Reuses the frozen-token re-theme pattern; leaves the 6 existing chart styles intact; only recolors data encodings, never chrome |
| 2026-07-23 | Languages: **EN (source), DE, FR, ES** | Usage is multilingual; English stays the source-of-truth locale |
| 2026-07-23 | Effort ring max is **user-selectable 0–21 or 0–100** | Already built (`EffortScale`, Settings picker); ring must reflect the chosen scale, not just the printed number |
| 2026-07-23 | System surface (WidgetKit, Live Activity/Dynamic Island, App Intents-Siri) pulled into scope | iOS strength unblocked by dropping Android parity |
| 2026-07-23 | iOS 26 Liquid Glass as a consistent design language (`glassEffect`, nav-zoom, Material) | Builds on the existing Liquid layer; applied during screen cleanups |
| 2026-07-23 | On-device Foundation Models coach — **deferred** | Svea stays on the current local engine (`Strand/AI/AICoach.swift`) for now; revisit later |
| 2026-07-23 | Accelerate/vDSP analytics rewrite — **deferred** | Validated physiological math; a rewrite must re-prove against the artifact. Left untouched to keep risk low |
