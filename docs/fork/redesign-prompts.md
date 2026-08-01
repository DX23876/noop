# Übergabe an Claude Code

Alles, was du brauchst, um ohne diesen Chat weiterzuarbeiten.

---

## 1. Was ins Repo gehört

| Datei aus dem Chat | Ziel im Repo | Wozu |
|---|---|---|
| `noop-redesign-briefing.md` | `docs/redesign-briefing.md` | Screen-Specs, Bugliste, Farb- und Typo-Werte |
| `noop-ringe-kacheln.html` | `docs/design/mockup-today.html` | visuelle Referenz für den Heute-Screen |
| diese Datei | `docs/redesign-prompts.md` | die Prompt-Folge unten |

Die HTML-Datei kann Claude Code lesen — sie ist die verbindliche Referenz, wenn Beschreibung und Bild auseinandergehen.

---

## 2. Block für deine bestehende CLAUDE.md

Unten anhängen, nichts ersetzen:

```markdown
## Redesign (laufend)

**Fork-Regel, gilt vor allen anderen:** Eigener Code lebt in neuen Dateien.
Upstream-Dateien werden nicht an Ort und Stelle umgeschrieben — das ist der
Grund, warum die Merges konfliktfrei sind. Neue Screens entstehen unter
StrandiOS/Redesign/, umgeschaltet wird über RootTabView und einen
Settings-Schalter. Packages/StrandDesign gehört dem Upstream und wird nicht
angefasst; eigene Farben kommen aus einem Fork-eigenen Set darüber.

**Designregeln:**
1. Ein Wert, ein Ort. Jede Kennzahl erscheint pro Screen genau einmal.
2. Keine leeren Kacheln. Ohne Daten wird nichts gerendert.
3. Farbe kodiert Familie: Grün = Charge und Vitalwerte, Blau = Effort,
   Violett = Rest/Schlaf, Gelb = Langfrist. Sonst keine.
4. Größe kodiert Wichtigkeit. Ein Element pro Screen ist deutlich größer.
5. Tabs sind Orte, keine Aktionen. Der Coach hängt an Inhalten.
6. Einheiten klein, in Sekundärfarbe, genau einmal pro Wert.
7. Alle Zahlen mit .monospacedDigit().
8. Alle Charts über Swift Charts.

Details: docs/redesign-briefing.md · Visuelle Referenz: docs/design/
Beschlüsse werden in docs/decisions.md festgehalten, nicht nur im Chat.
```

---

## 3. Prompt-Folge

### Prompt 1 · Analyse

Steht schon im Chat. Erzeugt `docs/ui-inventory.md` und `docs/ui-findings.md`.
Vorher `git fetch upstream`.

### Prompt 2 · Entscheidung über die Merge-Risiken

> Lies `docs/ui-findings.md`, Abschnitt Merge-Risiko. Für jede Upstream-Datei,
> die ein Redesign anfassen müsste, brauche ich einen Vorschlag mit genau einer
> von drei Optionen:
>
> **A – Additiv umgehen:** neuer Screen als neue Datei, Umschaltung über
> RootTabView. Bevorzugt, wo immer möglich.
> **B – Änderung akzeptieren:** die Upstream-Datei wird geändert. Nur wenn A
> nachweislich nicht geht. Schreib dazu, welcher Merge-Aufwand künftig entsteht.
> **C – Verzicht:** die Änderung ist den Aufwand nicht wert.
>
> Ergebnis als Tabelle in `docs/decisions.md`, mit einer Zeile Begründung pro
> Eintrag. Noch kein Code.

### Prompt 3 · Bugfixes

> Behebe die Formatierungsfehler aus `docs/ui-findings.md`, Abschnitt 4.
> Bekannt sind: doppelte Einheit in der Charge-Messwerttabelle, aneinander-
> gehängte Skalen bei Effort, „sleep debt" als Name für zwei verschiedene Größen.
> Ein Commit pro Fehler. Falls ein Fix eine Upstream-Datei betrifft, halte dich
> an die Entscheidung aus `docs/decisions.md`.

### Prompt 4 · Fahrgestell

> Lege `StrandiOS/Redesign/` an: ein Farb-Set mit Dark- und Light-Varianten
> gemäß `docs/redesign-briefing.md`, Abschnitt 2, aufbauend auf StrandDesign
> statt es zu ersetzen. Dazu eine Typo-Datei mit den definierten Rollen und
> einen Settings-Schalter „Neues Design", der in RootTabView zwischen alt und
> neu umschaltet. Der Schalter zeigt zunächst auf die bestehenden Screens —
> es ändert sich also noch nichts sichtbar.

### Prompt 5 · Screens, einzeln

Reihenfolge: Heute → Metrik-Detail → Mehr → Schlaf → Trends.

> Baue [Screen] als neue Datei unter `StrandiOS/Redesign/`. Vorlage:
> `docs/redesign-briefing.md`, Abschnitt [N], und `docs/design/mockup-today.html`
> als visuelle Referenz. Halte dich an die Regeln in CLAUDE.md.
> Zeig mir die Struktur als Liste der Views, bevor du Code schreibst.
> Der alte Screen bleibt unangetastet liegen.

Nach jedem Screen: auf dem Gerät prüfen, hell und dunkel, dann committen.

---

## 4. Entscheidungslog

`docs/decisions.md` anlegen und bei jeder Grundsatzentscheidung eine Zeile ergänzen:

```
| Datum | Entscheidung | Warum |
```

Das ist der Ersatz für diesen Chat. Ohne das diskutierst du in drei Wochen
dieselbe Frage nochmal — und Claude Code kann dir nicht widersprechen, weil es
den ersten Durchgang nicht kennt.

Erste Einträge, die schon feststehen:

| Datum | Entscheidung | Warum |
|---|---|---|
| 2026-07-23 | Redesign additiv, neue Dateien statt Umbau | Erhält die konfliktfreien Upstream-Merges |
| 2026-07-23 | Voll mergen statt cherry-picken | Funktioniert bisher, solange additiv gearbeitet wird |
| 2026-07-23 | StrandDesign bleibt unangetastet | Upstream-Paket; eigenes Farb-Set liegt darüber |
| 2026-07-23 | Drei Ringe oben, Kacheln darunter | Gewünschtes Layout, siehe Mockup |
| 2026-07-23 | Coach an Inhalten, kein eigener Tab | Tabs sind Orte, der Coach ist eine Aktion |

---

## 5. Prüfliste vor jedem Commit

- [ ] Läuft in Dark und Light
- [ ] Keine Kachel ohne Daten sichtbar
- [ ] Keine Kennzahl doppelt auf einem Screen
- [ ] Keine Upstream-Datei angefasst, die nicht in `docs/decisions.md` steht
- [ ] Neue Strings haben DE-Übersetzung (der i18n-Audit prüft das)
- [ ] Auf dem echten iPhone getestet, nicht nur im Simulator
