# Momentum — Übersetzungen einspielen

Die Momentum-Kachel und das Momentum-Dashboard bringen **55 neue Katalog-Keys** mit. Dieses Dokument
listet sie mit vorbereiteter deutscher Fassung und beschreibt den Ablauf.

## Warum das ein eigener Schritt ist

Katalog-Keys entstehen bei der **String-Extraktion**, und die läuft nur in einem Build aus **Xcode.app**
— nicht bei `xcodebuild` auf der Kommandozeile. Solange die Keys nicht angelegt sind, greift zur
Laufzeit der englische Quelltext als Fallback: die Oberfläche funktioniert, ist aber teilweise englisch.

`i18n-coverage.yml` prüft diff-bezogen (`Tools/i18n_audit.py --ci <base>`), meldet die neuen Keys also
erst, wenn sie im Katalog stehen.

## Ablauf

1. Projekt einmal in **Xcode.app** bauen (Schema `NOOPiOS` oder `Strand`). Danach stehen die neuen
   Keys in `Strand/Resources/Localizable.xcstrings`.
2. Die deutschen Fassungen unten eintragen (Xcode: String Catalog öffnen, Sprache `de`).
3. `python3 Tools/i18n_audit.py --ci HEAD` laufen lassen.
4. **Wichtig:** der Build reformatiert `.xcstrings` regelmäßig, ohne dass sich Inhalt ändert. Vor dem
   Commit prüfen und die reinen Formatierungsänderungen an nicht betroffenen Katalogen mit
   `git checkout` verwerfen.

## Platzhalter

Die Interpolationen unten stehen so, wie sie im Quelltext lauten. Im Katalog werden daraus
positionsbasierte Platzhalter (`%lld` für Ganzzahlen, `%@` für Strings) — **Reihenfolge und Anzahl
müssen in der Übersetzung erhalten bleiben**, sonst schlägt die Format-Prüfung des Audits an.

---

## Meldungen — Überschriften

| Englisch | Deutsch |
|---|---|
| `\(remaining) steps to your goal` | `Noch \(remaining) Schritte bis zum Ziel` |
| `Step goal reached` | `Schrittziel erreicht` |
| `Quieter day than usual` | `Ruhigerer Tag als sonst` |
| `You're short on sleep this week` | `Diese Woche fehlt dir Schlaf` |
| `One session short of your week` | `Ein Training fehlt dir für die Woche` |
| `\(missing) sessions short of your week` | `Dir fehlen \(missing) Trainings für die Woche` |
| `\(planned) is still open` | `\(planned) steht noch aus` |
| `\(run) straining days in a row` | `\(run) belastende Tage in Folge` |
| `Today looks like a good training day` | `Heute sieht nach einem guten Trainingstag aus` |
| `\(days) days in a row` | `\(days) Tage in Folge` |
| `Next up: \(m.value)` | `Als Nächstes: \(m.value)` |
| `Your HRV has been above baseline for \(run.days) days` | `Deine HRV liegt seit \(run.days) Tagen über der Basislinie` |
| `Your HRV has been below baseline for \(run.days) days` | `Deine HRV liegt seit \(run.days) Tagen unter der Basislinie` |
| `HRV \(abs(pct))% over baseline` | `HRV \(abs(pct)) % über Basislinie` |
| `HRV \(abs(pct))% under baseline` | `HRV \(abs(pct)) % unter Basislinie` |

## Meldungen — Detailzeilen

| Englisch | Deutsch |
|---|---|
| `You're at \(steps) of \(goal) today.` | `Du bist heute bei \(steps) von \(goal).` |
| `\(steps) steps today, past your goal of \(goal).` | `\(steps) Schritte heute — über deinem Ziel von \(goal).` |
| `About \(behind) steps below your normal day.` | `Etwa \(behind) Schritte unter deinem normalen Tag.` |
| `You're tracking below your normal daily movement.` | `Du liegst unter deiner üblichen Alltagsbewegung.` |
| `About \(durationText(owed)) behind your nightly need.` | `Etwa \(durationText(owed)) hinter deinem Schlafbedarf.` |
| `You've done \(done) of \(planned) this week.` | `Du hast diese Woche \(done) von \(planned) geschafft.` |
| `You planned it for today and nothing has been recorded yet.` | `Du hattest es für heute geplant, erfasst ist noch nichts.` |
| `Load has been high without a real break.` | `Die Belastung war hoch, ohne echte Pause.` |
| `Recovery is high and this week's load is still moderate.` | `Deine Erholung ist hoch und die Wochenlast noch moderat.` |
| `You've hit your goal \(days) days running.` | `Du hast dein Ziel \(days) Tage in Folge erreicht.` |
| `The next waypoint on \(m.goal).` | `Der nächste Meilenstein bei \(m.goal).` |
| `Your recovery is trending in the right direction.` | `Deine Erholung entwickelt sich in die richtige Richtung.` |
| `Your body is carrying something — load, sleep debt or illness.` | `Dein Körper trägt etwas mit sich — Belastung, Schlafdefizit oder eine Infektion.` |

## Meldungen — Handlungszeilen

| Englisch | Deutsch |
|---|---|
| `About \(walkMinutes(remaining)) min of walking would do it.` | `Etwa \(walkMinutes(remaining)) Min. Gehen würden reichen.` |
| `Turning in \(bedtimeShiftMinutes(owed)) min earlier tonight would start closing it.` | `Heute \(bedtimeShiftMinutes(owed)) Min. früher ins Bett würde anfangen, das aufzuholen.` |
| `Today is the last day to close it.` | `Heute ist der letzte Tag dafür.` |
| `\(daysLeft) days left.` | `Noch \(daysLeft) Tage.` |
| `An easy day would serve you better than another hard one.` | `Ein lockerer Tag bringt dir mehr als ein weiterer harter.` |
| `A harder session is well supported today.` | `Eine härtere Einheit ist heute gut abgedeckt.` |
| `Start it, or move it in your plan.` | `Starte es oder verschiebe es in deinem Plan.` |
| `Rest is the session today.` | `Ruhe ist heute die Einheit.` |
| `Keep it easy and short.` | `Halte es locker und kurz.` |
| `Moderate work is well judged.` | `Moderate Belastung ist gut gewählt.` |
| `A harder session fits today.` | `Eine härtere Einheit passt heute.` |
| `A good day to push.` | `Ein guter Tag, um Gas zu geben.` |

## Aktionen und Chrome

| Englisch | Deutsch |
|---|---|
| `Momentum` | `Momentum` *(Produktname — unübersetzt lassen)* |
| `See what shaped it` | `Sieh, was dahintersteckt` |
| `View goal` | `Ziel ansehen` |
| `Open plan` | `Plan öffnen` |
| `Start a session` | `Sitzung starten` |
| `Hide this message for today` | `Diese Meldung für heute ausblenden` |
| `Hidden in Momentum for today. It can come back tomorrow.` | `In Momentum für heute ausgeblendet. Morgen kann sie wiederkommen.` |
| `Nothing to flag right now` | `Gerade gibt es nichts zu melden` |
| `Momentum stays quiet when there's nothing worth acting on. Wear the strap and log your day, and it fills in.` | `Momentum bleibt still, solange es nichts zu tun gibt. Trag den Strap und log deinen Tag, dann füllt es sich.` |
| `Working out what matters` | `Wird gerade ermittelt` |
| `Open Today once and this fills in.` | `Öffne einmal „Heute", dann füllt sich das hier.` |
| `Daily step goal` | `Tagesschrittziel` |

## Dauern

Diese drei bilden zusammen die lesbare Dauer („5 h 39 min"). Der Fall unter einer Stunde ist eigen,
damit im Deutschen nicht „0 h 45 min" steht.

| Englisch | Deutsch |
|---|---|
| `\(minutes) min` | `\(minutes) Min.` |
| `\(h) h` | `\(h) Std.` |
| `\(h) h \(m) min` | `\(h) Std. \(m) Min.` |

## Dashboard-Gruppen

| Englisch | Deutsch |
|---|---|
| `Right now` | `Jetzt wichtig` |
| `Running out of time` | `Läuft ab` |
| `Your goals` | `Deine Ziele` |
| `Training and recovery` | `Training und Erholung` |
| `Progress` | `Fortschritt` *(existiert bereits im Katalog)* |
| `Worth noting` | `Bemerkenswert` |
| `What matters most for you right now` | `Was für dich gerade am wichtigsten ist` |
