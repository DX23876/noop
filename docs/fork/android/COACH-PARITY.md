# Coach: iOS → Android, 1:1

Inventory of the iOS coach (`Strand/Screens/Coach*.swift`, `CoachSettingsView.swift`, `CoachEntry.swift`,
`DashboardCoachCard.swift`), compared with Android, made 2026-10-28 before porting further. Every row is one
thing a person can see or do on iPhone. Status: ✅ on Android through the shared coach, 🟡 partly, ❌ missing.
The logic behind every row already runs in the shared Swift coach in `NoopCore`; what is missing is the Android
screen and its `coach.*` operation in `CoreCoach.swift`.

## Chat (`CoachView`)

| iOS | Android | Note |
|---|---|---|
| Header row: coach avatar (breathing while writing), name, "Your coach" / "Thinking…" | ✅ | avatar and name follow the identity |
| Header: plan book with "waiting" dot, New chat, overflow (history, goal, settings, goal setup) | ✅ | goal entry opens Goals & journey; no separate goal setup sheet |
| Empty state: portrait, "Hi, I'm …", what the coach reads, suggestion cloud | ✅ | |
| Question bubble (accent, tight sender corner), long-press Copy, Share, Edit and ask again | ✅ | |
| Reply without bubble beside avatar, Markdown, streaming word by word with caret | 🟡 | Markdown and the caret while it is written; the text arrives in polled chunks rather than word by word |
| Reply long-press: Copy, Share, Regenerate, Look at this more closely | ✅ | plus Save to journal |
| Charts in chat (`plot_metric`), cards in chat (`show_card`) | ✅ | |
| Evidence chain under a reply (tools used, local context) | ✅ | wording in the shared `CoachChatLabels.swift` |
| Memory receipt (what this reply saved, undo) | ✅ | confirm, edit, forget |
| "The coach got in touch" label on brief, nudge, weekly review | ✅ | |
| Action row: Review draft goal, Review routine, Review workout, Schedule a session | 🟡 | Breathe, Live Session, Schedule a session; the three review chips wait for their drafts on Android |
| Time separators | ✅ | |
| Typing indicator | ✅ | |
| Error banner with Retry (wait seconds), consent-off banner | ✅ | |
| Card follow-up chips | 🟡 | shown when the engine has them; Android has no card read that opens the chat yet |
| Composer: glass capsule, mic, send/stop | ✅ | stays at the bottom above the keyboard while the transcript scrolls |
| First-use sheet, goal onboarding sheet | 🟡 | first-use note; no goal onboarding |

## Settings (`CoachSettingsView`)

| iOS | Android | Note |
|---|---|---|
| Connection & model: provider, key, custom URL and header, model picker, Custom model, check connection, forget key, reconnect | 🟡 | provider, key, URL, model, test connection; Update key and Disconnect sit in the chat's menu |
| Background models (summary, card analysis, deep analysis) per role | ✅ | typed model names, no picker per role |
| Quick presets | ✅ | their titles are not in the iOS catalogue, so they read in English on both |
| Coach identity: name, avatar (Svea, Marv, symbol, own photo), voice | ✅ | |
| Emoji in replies | ✅ | |
| Reply length | ✅ | |
| Proactive messages level | ✅ | |
| Coaching style (persona) | ✅ | |
| Coach instructions (system prompt) | ✅ | the editor reads and writes the shared coach's (`coach.prompt`) |
| Morning suggestion on Today | ✅ | switch and Today card through `coach.morning`, state by the shared `MorningSuggestionState` |
| Morning brief with time | ✅ | written by the shared coach (`coach.brief`) |
| Daily check-in (fixed time or after waking) | ✅ | wake time learned at every launch by the shared rule (`CoachCheckInWake`); no snooze or skip action on the notification |
| Plan reminders | ✅ | without the weekly-goal line iOS adds |
| Goal & Journey (`CoachGoalView`, `CoachGoalJourneyView`, setup review) | ✅ | goals, journey and past goals; the setup review chip waits for drafts on Android |
| Memory: facts list with category, edit, expiry, source, add fact, forget all, summarise past chats | ✅ | |
| Semantic memory switch and status | ❌ | no embedding model on Android (plan decision) |
| Privacy & data: Enable AI Coach, privacy level, data access purposes (8 switches), share patterns & Lab Book, let the coach use my data | ✅ | Enable AI Coach is Android's own switch (`NoopPrefs.coachEnabled`) |
| How Coach works (`CoachInfoView`) | ✅ | without the two paragraphs on the iPhone's on-device search |
| Usage: last question, today, this session | ✅ | |
| Coach on Today: show coach, avatar, banner, floating button, position, lock | 🟡 | the card follows the master switch; no separate Today switch, no floating button |

## Elsewhere

| iOS | Android | Note |
|---|---|---|
| Coach history (`CoachHistoryView`) | ✅ | |
| Plan book (`CoachPlanView`) | ✅ | with time, move-day and swap |
| Today launcher sheet (`CoachLauncherSheet`), Today coach card (`DashboardCoachCard`) | ✅ | the card's sentence is Momentum's (`MomentumCopy.stateDetail`); portrait follows the identity |
