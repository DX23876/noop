# Trainingspläne — Übersetzungen einspielen

Die Planliste, die Planseite, der Assistent, die fertigen Pläne und die Blockanzeige bringen **105 neue
Katalog-Keys** mit. Dieses Dokument listet sie mit vorbereiteter deutscher Fassung und beschreibt den
Ablauf.

## Warum das ein eigener Schritt ist

Katalog-Keys entstehen bei der **String-Extraktion**, und die läuft nur in einem Build aus **Xcode.app**
— nicht bei `xcodebuild` auf der Kommandozeile, auch nicht mit `SWIFT_EMIT_LOC_STRINGS=YES` (geprüft).
Solange die Keys fehlen, greift zur Laufzeit der englische Quelltext als Fallback: die Oberfläche
funktioniert, ist aber teilweise englisch, und `i18n-coverage.yml` meldet die fehlenden Keys.

Die Android-Seite derselben Arbeit ist bereits vollständig übersetzt (neun Sprachen in
`android/app/src/main/res/values*/strings.xml`); dort gibt es keine Extraktion, die Keys stehen im XML.

## Ablauf

1. Projekt einmal in **Xcode.app** bauen (Schema `NOOPiOS` oder `Strand`). Danach stehen die neuen Keys
   in `Strand/Resources/Localizable.xcstrings`.
2. Die deutschen Fassungen unten eintragen (Xcode: String Catalog öffnen, Sprache `de`).
3. `python3 Tools/i18n_audit.py --ci origin/main` laufen lassen und nach dem **Beendigungscode** urteilen,
   nicht nach der letzten Zeile.
4. **Wichtig:** der Build reformatiert `.xcstrings` regelmäßig, ohne dass sich Inhalt ändert. Vor dem
   Commit prüfen und reine Formatierungsänderungen an nicht betroffenen Katalogen mit `git checkout`
   verwerfen.

## Platzhalter

Die Interpolationen stehen so, wie sie im Quelltext lauten. Im Katalog werden daraus positionsbasierte
Platzhalter (`%lld` für Ganzzahlen, `%@` für Strings) — **Reihenfolge und Anzahl müssen in der
Übersetzung erhalten bleiben**, sonst schlägt die Format-Prüfung des Audits an.

---

## Planliste und Planseite

| Englisch | Deutsch |
|---|---|
| `Plans` | `Pläne` |
| `My plan` | `Mein Plan` |
| `New plan` | `Neuer Plan` |
| `Empty plan` | `Leerer Plan` |
| `Edit plan` | `Plan bearbeiten` |
| `Duplicate plan` | `Plan kopieren` |
| `Delete plan` | `Plan löschen` |
| `Delete this plan?` | `Diesen Plan löschen?` |
| `Its routines and its week go with it. Workouts you have logged stay in your history.` | `Seine Routinen und seine Woche gehen mit. Aufgezeichnete Einheiten bleiben in deinem Verlauf.` |
| `Following` | `Aktiv` |
| `Being followed` | `Wird verfolgt` |
| `Follow this plan` | `Diesem Plan folgen` |
| `Let this plan rest` | `Plan ruhen lassen` |
| `This plan is in your week, on Today and in the quick start.` | `Dieser Plan steht in deiner Woche, auf Heute und im Schnellstart.` |
| `Resting. Nothing from this plan can be started until you take it up.` | `Ruht. Aus diesem Plan lässt sich nichts starten, solange du ihn nicht aktivierst.` |
| `\(replaced.title) goes back to resting.` | `\(replaced.title) ruht dann wieder.` |
| `One strength plan is followed at a time, and one plan of another kind can run beside it.` | `Es läuft ein Kraftplan zur Zeit, daneben kann ein Plan anderer Art laufen.` |
| `Kind` | `Art` |
| `No routines yet.` | `Noch keine Routinen.` |
| `No day` | `Kein Tag` |
| `\(days) days a week` | `\(days) Tage pro Woche` |
| `Goes into \(programTitle).` | `Gehört zu \(programTitle).` |
| `The plan could not be saved.` | `Der Plan konnte nicht gespeichert werden.` |
| `The plan could not be deleted.` | `Der Plan konnte nicht gelöscht werden.` |

## Wochenvorgaben

| Englisch | Deutsch |
|---|---|
| `What this plan asks of a week` | `Was dieser Plan von einer Woche verlangt` |
| `These belong to the plan and leave with it.` | `Sie gehören zum Plan und gehen mit ihm.` |
| `\(sessionsPerWeek) sessions a week` | `\(sessionsPerWeek) Einheiten pro Woche` |
| `\(sessions) sessions a week` | `\(sessions) Einheiten pro Woche` |
| `\(built.routines.count) sessions a week` | `\(built.routines.count) Einheiten pro Woche` |
| `No session target` | `Kein Ziel für Einheiten` |
| `\(cardioMinutes) cardio minutes a week` | `\(cardioMinutes) Ausdauerminuten pro Woche` |
| `\(minutes) cardio minutes a week` | `\(minutes) Ausdauerminuten pro Woche` |
| `No cardio target` | `Kein Ausdauerziel` |

## Block

| Englisch | Deutsch |
|---|---|
| `Block` | `Block` |
| `Run for a set number of weeks` | `Über eine feste Zahl Wochen laufen` |
| `Lighter final week` | `Letzte Woche leichter` |
| `A lighter week every few weeks` | `Alle paar Wochen eine leichtere` |
| `Without a block the plan simply runs on.` | `Ohne Block läuft der Plan einfach weiter.` |
| `A lighter week keeps \(Int((block.deloadFactor * 100).rounded())) % of the load. The plan reports when its last week is behind you, and changes nothing by itself.` | `Eine leichtere Woche behält \(Int((block.deloadFactor * 100).rounded())) % der Last. Der Plan meldet sich, wenn seine letzte Woche vorbei ist, und ändert von allein nichts.` |
| `Week \(state.week) of \(state.weeks)` | `Woche \(state.week) von \(state.weeks)` |
| `Block week \(state.week) of \(state.weeks).` | `Blockwoche \(state.week) von \(state.weeks).` |
| `\(block.weeks) week block` | `Block über \(block.weeks) Wochen` |
| `Block finished` | `Block beendet` |
| `Its block has finished.` | `Sein Block ist beendet.` |
| `Nothing has changed by itself. Run it again, build the next one, or follow another plan.` | `Von allein hat sich nichts geändert. Wiederhole ihn, bau den nächsten oder folge einem anderen Plan.` |
| `A lighter week: this week's sessions are prescribed at \(Int((state.loadFactor * 100).rounded())) % of their load.` | `Eine leichtere Woche: die Einheiten dieser Woche stehen bei \(Int((state.loadFactor * 100).rounded())) % ihrer Last.` |
| `Lighter week in week \(next).` | `Leichtere Woche in Woche \(next).` |
| `Prescriptions over the block` | `Vorgaben über den Block` |
| `Only what you earn` | `Nur was du dir verdienst` |
| `A weight step each week` | `Ein Gewichtsschritt pro Woche` |
| `A set more each week` | `Ein Satz mehr pro Woche` |
| `This block so far` | `Dieser Block bisher` |
| `Earlier blocks` | `Frühere Blöcke` |
| `Finished` | `Durchgelaufen` |
| `Stopped early` | `Früher beendet` |
| `\(TrainingPreferences.formattedVolume(report.loadKg)) moved` | `\(TrainingPreferences.formattedVolume(report.loadKg)) bewegt` |
| `\(report.unpricedWorkSets) sets carried no weight to count.` | `\(report.unpricedWorkSets) Sätze trugen kein Gewicht zum Zählen.` |
| `\(delta.workSets) work sets more than the block before` | `\(delta.workSets) Arbeitssätze mehr als im Block davor` |
| `\(-delta.workSets) work sets fewer than the block before` | `\(-delta.workSets) Arbeitssätze weniger als im Block davor` |
| `\(TrainingPreferences.formattedVolume(delta.loadKg)) more moved` | `\(TrainingPreferences.formattedVolume(delta.loadKg)) mehr bewegt` |
| `\(TrainingPreferences.formattedVolume(-delta.loadKg)) less moved` | `\(TrainingPreferences.formattedVolume(-delta.loadKg)) weniger bewegt` |

## Assistent und fertige Pläne

| Englisch | Deutsch |
|---|---|
| `Build a plan` | `Plan bauen` |
| `Build` | `Bauen` |
| `Ready-made plans` | `Fertige Pläne` |
| `A new plan rests until you follow it.` | `Ein neuer Plan ruht, bis du ihm folgst.` |
| `Start from scratch or from a template, then change exercises, sets, rest and progression to fit you.` | `Von null anfangen oder aus einer Vorlage, dann Übungen, Sätze, Pausen und Steigerung passend machen.` |
| `The sessions are spread through the week, with rest days between them where the number allows.` | `Die Einheiten liegen über die Woche verteilt, mit Ruhetagen dazwischen, wo die Zahl es zulässt.` |
| `Experience` | `Erfahrung` |
| `New to this` | `Ganz neu` |
| `A while` | `Eine Weile` |
| `Years` | `Jahre` |
| `Lean towards` | `Schwerpunkt` |
| `Size` | `Muskelaufbau` |
| `A lean adds to the plan rather than taking anything out.` | `Ein Schwerpunkt fügt dem Plan etwas hinzu, statt etwas wegzunehmen.` |
| `Only the equipment I have` | `Nur meine vorhandenen Geräte` |
| `Every exercise in the library can be used.` | `Jede Übung der Bibliothek darf vorkommen.` |
| `You have not said what equipment you have, under Settings, Training, so everything is used.` | `Unter Einstellungen, Training steht nicht, welche Geräte du hast, also wird alles genutzt.` |
| `\(available.count) kinds of equipment from Settings, Training.` | `\(available.count) Gerätearten aus Einstellungen, Training.` |
| `Save and follow this plan` | `Speichern und diesem Plan folgen` |
| `Start over` | `Von vorn` |
| `Saved on its own, a plan rests until you take it up. Everything in it can be edited afterwards.` | `Nur gespeichert ruht ein Plan, bis du ihn aktivierst. Alles darin lässt sich danach ändern.` |
| `A plan you pick here rests until you follow it, and everything in it can be edited.` | `Ein Plan von hier ruht, bis du ihm folgst, und alles darin lässt sich ändern.` |
| `No plan could be built from the equipment you have. Add more under Settings, Training.` | `Aus deinen Geräten ließ sich kein Plan bauen. Ergänze sie unter Einstellungen, Training.` |
| `\(template.daysPerWeek) days a week` | `\(template.daysPerWeek) Tage pro Woche` |
| `Needs \(missing)` | `Braucht \(missing)` |
| `\(work.count) × \(reps)` | `\(work.count) × \(reps)` |
| `\(work.count) × \(seconds) s` | `\(work.count) × \(seconds) s` |

## Wochenrückmeldung

| Englisch | Deutsch |
|---|---|
| `A week of this plan` | `Eine Woche mit diesem Plan` |
| `Time a session` | `Zeit je Einheit` |
| `\(low) to \(high) min` | `\(low) bis \(high) Min` |
| `About \(SessionEstimate.minutes(routine)) minutes, with the rests as set.` | `Etwa \(SessionEstimate.minutes(routine)) Minuten, mit den eingestellten Pausen.` |
| `Nothing for \(Self.regionName(region)) this week.` | `Nichts für \(Self.regionName(region)) in dieser Woche.` |
| `\(Self.regionName(region)): \(Int(weekly.rounded())) sets a week, against your own recent average of \(Int(usual.rounded())). That is a big step up, which is fine if you meant it.` | `\(Self.regionName(region)): \(Int(weekly.rounded())) Sätze pro Woche, gegen deinen eigenen Schnitt von \(Int(usual.rounded())). Das ist ein großer Sprung, völlig in Ordnung wenn du ihn willst.` |
| `\(Self.dayName(first)) and \(Self.dayName(second)) both lean on your legs.` | `\(Self.dayName(first)) und \(Self.dayName(second)) gehen beide auf die Beine.` |
| `\(title) comes to about \(minutes) minutes, more than the \(asked) you asked for.` | `\(title) kommt auf etwa \(minutes) Minuten, mehr als die \(asked) die du wolltest.` |
| `One session` | `Eine Einheit` |

## Einheit als Routine

| Englisch | Deutsch |
|---|---|
| `Keep this as a routine` | `Als Routine behalten` |
| `What you did becomes the prescription: the same exercises, sets, weights and repetitions. Sets you did not complete are left out.` | `Was du gemacht hast wird die Vorgabe: dieselben Übungen, Sätze, Gewichte und Wiederholungen. Nicht beendete Sätze bleiben draußen.` |
| `Saved as a routine` | `Als Routine gespeichert` |

## Coach

Nur sichtbar, wenn der Coach eingeschaltet und eingerichtet ist.

| Englisch | Deutsch |
|---|---|
| `This plan` | `Dieser Plan` |
| `Plan: \(current.displayName). Sessions a week: \(review.weeklySessionCount). Sets a week by region: \(week).` | `Plan: \(current.displayName). Einheiten pro Woche: \(review.weeklySessionCount). Sätze pro Woche je Region: \(week).` |
| `Minutes a session: \(low) to \(high).` | `Minuten je Einheit: \(low) bis \(high).` |
| `Does this plan fit what I have been training lately?` | `Passt dieser Plan zu dem, was ich zuletzt trainiert habe?` |
| `What would you change about this plan?` | `Was würdest du an diesem Plan ändern?` |
| `What should the next block look like?` | `Wie sollte der nächste Block aussehen?` |
