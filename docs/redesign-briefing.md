# NOOP · Redesign-Briefing

Für die Umsetzung in Claude Code. Reihenfolge der Abschnitte = empfohlene Reihenfolge der PRs.

---

## 0. Grundregeln

Diese vier Regeln entscheiden im Zweifel jede Detailfrage:

1. **Ein Wert, ein Ort.** Jede Kennzahl erscheint auf einem Screen genau einmal. Steht sie oben in einem Ring, steht sie nicht nochmal in einer Kachel.
2. **Keine leeren Kacheln.** Ohne Daten wird die Kachel nicht gerendert — kein „—", kein Platzhalter.
3. **Farbe kodiert Familie, nicht Metrik.** Grün = Charge und alles, was in sie einfließt. Blau = Effort. Violett = Rest/Schlaf. Gelb = Langfristwerte. Sonst keine Farben.
4. **Größe kodiert Wichtigkeit.** Auf jedem Screen ist genau ein Element deutlich größer als der Rest.

---

## 1. Bugs und Textfehler (zuerst, unabhängig vom Design)

Alles direkt aus den Screenshots:

| Ort | Problem |
|---|---|
| Charge → Readings | `85 % %` — Einheit doppelt angehängt |
| Effort → Readings | `3.5 /21 /100` — zwei Skalen hintereinander gerendert |
| Metrik-Detail Header | Eyebrow `CHARGE` direkt über Titel `Charge` — dieselbe Information zweimal |
| Trends → Charge 90 Tage | Datenlücke 1. Juni – 13. Juli wird als leerer Raum gezeichnet, ohne Hinweis |
| Trends → Charge-Balken | Der Rot→Grün-Verlauf ist bei jedem Balken identisch, kodiert also nichts. Entweder Farbe an den Wert koppeln oder einfarbig |
| Sleep | „Sleep debt 49m" (letzte Nacht) und „≈22h 34m" (14 Nächte) heißen beide gleich. Zwei Begriffe: **Defizit letzte Nacht** / **Schlafkonto** |
| Sleep | „Sleep performance 86" und Kachel „Rest 86 %" sind derselbe Wert unter zwei Namen |
| Sleep → Night detail | „Consistency 0 %" in Rot, ohne Erklärung, was 0 % bedeutet. Entweder Rechenfehler oder fehlender Hilfetext |
| More | Sektion „INSIGHTS" enthält einen Eintrag namens „Insights" |
| Metrik-Detail | Segmented Control mit acht Fenstern (W/2W/3W/M/3M/6M/1Y/ALL) ist auf 390 pt zu eng. Auf vier reduzieren: W / M / 6M / ALL |
| Global | App ist englisch, Nutzung deutsch. Eine Sprache festlegen und durchziehen |

---

## 2. Design-Tokens

Als Asset-Katalog anlegen, nicht als feste Hex-Werte im Code. Jede Farbe braucht beide Varianten, sonst funktioniert Light Mode nicht.

### Farben

| Token | Dark | Light | Bedeutung |
|---|---|---|---|
| `bg` | `#000000` | `#F5F5F3` | Hintergrund |
| `tile` | `#121514` | `#FFFFFF` | Kachelfläche |
| `tileAlt` | `#191D1B` | `#FAFAF8` | Kachel, zweite Ebene |
| `line` | `#262B29` | `#E4E4E0` | Rahmen, Trenner |
| `ink` | `#FFFFFF` | `#0A0C0B` | Primärtext |
| `inkSecondary` | `#9AA09D` | `#5E6562` | Sekundärtext |
| `inkTertiary` | `#69706D` | `#8A908D` | Labels, Einheiten |
| `charge` | `#31E39C` | `#0C8F62` | Charge + Vitalwerte |
| `effort` | `#3AA0FF` | `#0A63B8` | Effort |
| `rest` | `#8C7BFF` | `#5546C4` | Rest / Schlaf |
| `longterm` | `#F0B441` | `#B07908` | Fitness-Alter, Warnungen |

Die hellen Varianten sind bewusst dunkler und weniger gesättigt — Neonfarben sind auf Weiß nicht lesbar.

### Typografie

SF Pro, `.rounded` nur für Zahlen. Alle Zahlen mit `.monospacedDigit()`, sonst springen sie beim Live-Update.

| Rolle | Größe / Gewicht | Verwendung |
|---|---|---|
| Hero | 52–62 pt / 740, tracking −0.04 em | die eine große Zahl pro Screen |
| Ringwert | 25 pt / 740 | Zahl im Ring |
| Kachelwert | 27 pt / 700 | Kachel-Hauptzahl |
| Titel | 24 pt / 720 | Screen-Überschrift |
| Body | 15 pt / 560 | Empfehlungssatz, Fließtext |
| Label | 10 pt / 750, tracking 0.11 em, Caps | Kachel- und Sektionslabels |
| Fußnote | 11–12 pt / 560 | Deltas, Einheiten, Zeitangaben |

Einheiten (`%`, `ms`, `bpm`) immer kleiner und in `inkTertiary` — sie sind nie die Information.

### Geometrie

- Radius: Kachel 20, Hero/Ringcontainer 24, Pille 999, Listenblock 16
- Abstand: 10 zwischen Kacheln, 22 zwischen Sektionen, 16 Rand
- Rahmen: 1 px `line` auf jeder Kachel, keine Schatten

---

## 3. Navigation

Tabs bleiben bei vier. Tabs sind **Orte**, keine Aktionen — deshalb kein Coach-Tab.

```
Heute      – der Tag: drei Ringe, Empfehlung, Vitalkacheln
Trends     – Verläufe und Wochenrückblick
Schlaf     – letzte Nacht und Schlafkonto
Mehr       – alles andere
```

**Der Coach** wird an Inhalte gehängt, nicht in die Navigation:
- Knopf „Svea fragen" unter dem Empfehlungssatz auf *Heute*
- derselbe Knopf in jedem Metrik-Detail, vorbelegt mit dieser Metrik
- kein eigener Tab, kein FAB

---

## 4. Screen: Heute

```
┌──────────────────────────────────┐
│ Guten Morgen, Marv    [🔋 45 %]  │   Strap-Akku als Pille,
│ Donnerstag, 23. Juli             │   ab 15 % gelb, sonst still
├──────────────────────────────────┤
│   ( 85 )    ( 2,7 )    ( 87 )    │   drei Ringe, gleich groß
│  ERHOLUNG  BELASTUNG   SCHLAF    │
├──────────────────────────────────┤
│ Heute ist viel drin.             │
│ [ S  Svea fragen ]               │
├──────────────────────────────────┤
│ VITALWERTE        Alle Analysen ›│
│ ┌────────┐ ┌────────┐            │
│ │ HRV    │ │ Ruhe-  │            │
│ │ 45 ms  │ │ puls   │            │
│ └────────┘ └────────┘            │
│ ┌────────┐ ┌────────┐            │
│ │ Atmung │ │ Fitness│            │
│ └────────┘ └────────┘            │
│ ┌──────────────────────┐         │
│ │ Aktivität         ›  │         │
│ └──────────────────────┘         │
└──────────────────────────────────┘
```

**Entfällt gegenüber heute:** Live-Puls-Graph, Stress, Vitality, Blutsauerstoff, Gewicht, Kalorien, Schritte, „Recovery Vitals", „Your Cards", „Data Sources". Alles wandert nach *Trends* oder *Mehr*.

**Offene Entscheidung:** Der Belastungsring braucht ein Maximum. Effort läuft laut Detailscreen auf einer 0–21-Skala — entweder 21 als Ringmaximum setzen oder ein persönliches Tagesziel definieren. Ohne Bezugsgröße ist der Ring Dekoration.

---

## 5. Screen: Trends

Struktur bleibt, drei Eingriffe:

1. **Wochenrückblick oben behalten** — die drei Ringkarten mit Wochen-Delta funktionieren gut, das ist der beste Teil der aktuellen App.
2. **Die zwei Insight-Sätze darunter behalten**, aber auf maximal zwei begrenzen. Danach „Svea fragen".
3. **Charts vereinheitlichen.** Alle Verlaufscharts auf Swift Charts umstellen, gleiche Achsenlogik, gleiche Höhe, gleiche Farbregel (Familie). Datenlücken explizit als Lücke beschriften („keine Daten, 1.–13. Juni"), nicht als leere Fläche.

---

## 6. Screen: Schlaf

Reihenfolge umdrehen — aktuell steht der Score oben und das Wichtigste unten.

```
Schlaf-Score 86            ← bleibt oben, gute Lösung
Letzte Nacht: 02:19 → 09:20
Schlafkonto: −22 h 34 m    ← hoch, direkt unter den Score
Phasen (Deep/REM/Light)
Nachtdetail (Kacheln)
Verlauf 30 Tage
Sleep marks / Nickerchen   ← nach unten, sind Eingaben, keine Info
```

Begriffe trennen: **Defizit letzte Nacht** (49 m) vs. **Schlafkonto** (−22 h 34 m). Und „Rest" und „Sleep performance" auf einen Namen zusammenführen.

---

## 7. Screen: Mehr

Aktuell rund 26 Einträge, viele mit Namen, die nicht sagen, was sie tun: „What Moves You", „Intelligence", „Explore", „Compare", „Insights", „Rhythm", „Lab Book".

Regel: **Jeder Eintrag heißt nach dem, was der Nutzer dort bekommt.** Wenn sich zwei Namen nicht klar trennen lassen, sind es vermutlich zwei Ansichten derselben Funktion und gehören zusammengelegt.

Vorschlag für die Gruppierung:

```
ANALYSE     Korrelationen · Wochenrückblick · Vergleich
KÖRPER      Live-Puls · Workouts · Stress · Atmung · Intervalle
DATEN       Quellen · Apple Health · Mi Band · Backup · Export
APP         Wecker · Automationen · Siri · Einstellungen
```

„Coach" verschwindet hier — er sitzt jetzt an den Inhalten.

---

## 8. Metrik-Detailscreen (ein Template für alle)

Ein einziges wiederverwendbares View, parametrisiert über die Metrik:

```
‹ Zurück        Charge
[ W ][ M ][ 6M ][ ALL ]        ← vier Fenster, nicht acht
        85 %
    Stand 23. Juli

[Verlaufschart, Swift Charts, scrubbable]

Ø 73 %   Min 46 %   Max 90 %   Δ +23 %

[ S  Svea zu Charge fragen ]

Messwerte (Tabelle)
Was korreliert (Pearson r)
```

Einheit genau einmal — am Hero-Wert. In der Tabelle nur die Zahl.

---

## 9. iOS-spezifisch

- **Swift Charts** für alle Verläufe. Ersetzt die selbstgezeichneten Pfade, bringt Scrubbing und VoiceOver mit.
- **Semantische Farben im Asset-Katalog**, kein Hex im Code. Light Mode kommt dann automatisch.
- **`.navigationTransition(.zoom)`** für Kachel → Detail (iOS 18+). Macht die Tiefenstruktur begreifbar.
- **WidgetKit**: Sperrbildschirm-Widget mit Erholung, Home-Screen-Widget mit den drei Ringen.
- **Live Activity** für Trainings mit Live-Puls. Auf dem iPhone 13 Pro Max erscheint sie auf dem Sperrbildschirm (kein Dynamic Island — das gibt es erst ab dem 14 Pro).
- **App Intents** für „Wie ist meine Erholung?" per Siri.
- **Dynamic Type** testen: die Hero-Zahlen bei 62 pt brechen bei großen Textgrößen. `.minimumScaleFactor(0.7)` und Layout-Test bei XXL.
- **Safe Area** respektieren, Statusleiste nicht selbst zeichnen.

---

## 10. Reihenfolge

1. Bugs aus Abschnitt 1
2. Farb- und Typo-Tokens anlegen, alte Hex-Werte ersetzen
3. Heute-Screen neu bauen (größter sichtbarer Effekt)
4. Metrik-Detail-Template, alle Einzelscreens darauf umstellen
5. Mehr-Tab aufräumen und umbenennen
6. Schlaf-Reihenfolge
7. Charts auf Swift Charts
8. Widgets, Live Activity, Siri
