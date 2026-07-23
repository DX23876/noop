# NOOP AI · Design-Spezifikation, Heute-Screen

Beschreibt **Aussehen und Bewegung**, nicht Verhalten/Daten. Für Funktion siehe `feature-spec.md`.
Visuelle Referenz: `noop-heute-ausgebaut.html` (verbindlich bei Widerspruch zum Text).

---

## 0. Grundregeln (gelten für den ganzen Screen)

1. Jeder Wert erscheint genau einmal. Steht er in einem Ring, steht er nicht zusätzlich in einer Kachel.
2. Keine leeren Kacheln — ohne Daten wird nichts gerendert.
3. Große Zahlen sind immer in einer einzigen neutralen Textfarbe (`ink`). Akzentfarbe sitzt im Icon-Badge und im dezenten Hintergrundschimmer, nie im Zahlentext.
4. Ring-Familienfarben (Charge=Grün, Effort=Blau, Rest=Violett) sind reserviert. Keine andere UI-Farbe darf mit ihnen kollidieren oder in ihrer Nähe verwechselbar sein.
5. Ein Element pro Screen ist deutlich größer als der Rest — hier: die drei Ringe.
6. Alle Zahlen `.monospacedDigit()`.
7. Dark und Light Mode über Farb-Tokens, nie Hex im Code.

---

## 1. Kopfzeile

```
Guten Morgen, Marv          [Status] [Akku] [Coach]
Donnerstag, 23. Juli
```

- Name/Datum linksbündig, drei kleine runde Elemente rechts, 30×30pt, 8pt Abstand zueinander.
- **Status-Chip:** im Ruhezustand reines Icon (Blitz/Bett/Pflaster/Palme je nach Zustand), keine Farbe, keine Umrandung — identisch zu Akku- und Coach-Chip. Antippen: weitet sich per Animation (~0,22s) nach links auf ca. 118pt, zeigt den Zustandsnamen als Text, und ein dezenter Farbring erscheint (eine einzige Warnfarbe für alle drei Ausnahmezustände, nicht vier verschiedene — Begründung siehe Abschnitt 6). Zweites Antippen öffnet das Sheet. Antippen außerhalb schließt die Aufweitung wieder.
- **Akku-Chip:** Icon-only, Strap-Ladestand. Kein Zahlenwert nötig im Ruhezustand.
- **Coach-Chip:** Kreisförmiger Avatar mit Gradient (Charge→Rest-Farbverlauf), Notification-Punkt oben rechts, nur sichtbar bei neuer proaktiver Nachricht.

---

## 2. Drei Ringe

- Gleich groß, 92×92pt, nebeneinander mit `space-around`.
- Track in gedämpfter Neutralfarbe, Fortschritt in der jeweiligen Familienfarbe, `stroke-linecap: round`.
- Optionaler sanfter Glow dahinter (radialer Farbverlauf der Charge-Farbe, ~16% Deckkraft, reicht ca. 18pt über den Container hinaus) — das ist der "lebendiger"-Akzent, siehe Abschnitt 6.
- Label darunter: Caps, 10pt, Sekundärfarbe.

---

## 3. Basiskarte + Notification-Karten

### Basiskarte
- Liegt fest im Hintergrund der Kartenzone (~150pt Höhe), niemals wegwischbar.
- Enthält: Tag-Pille (gefüllt, mit kleinem Punkt davor, z. B. "● Push") + Aussagetext.
- Randfarbe und Tag-Farbe wechseln je nach Aktivitätsstatus zwischen Charge-Grün (aktiv) und der Warnfarbe (alle drei Ausnahmezustände) — siehe Feature-Spec 1 für die Logik dahinter.
- Dezenter diagonaler Farbverlauf im Hintergrund (~10% Deckkraft), passend zur aktuellen Randfarbe.

### Notification-Karten
- Liegen über der Basiskarte, gestapelt. Oberste Karte ist die einzige mit voller Deckkraft und Interaktion; weitere Karten dahinter leicht verkleinert (96%), nach unten versetzt (+9pt), reduzierte Deckkraft (~55%), nicht interaktiv.
- Wegzieh-Geste: horizontal, jede Richtung gleich behandelt (keine unterschiedliche Bedeutung links/rechts). Ab ±90pt Auslenkung: Karte fliegt mit Rotation weiter in Zugrichtung und verblasst, danach entfernt; darunter liegende Karte rückt nach.
- Unter ±90pt: Karte federt beim Loslassen zurück in Ausgangsposition.
- Punktindikator unter der Kartenzone zeigt Kartenanzahl, aktive Karte hervorgehoben.

---

## 4. Vitalwerte-Raster

### Kachel-Grundform
- Radius 22pt, 1pt Rahmen in `line`-Farbe, Innenabstand 18pt (16pt bei 3er-Dichte).
- Icon-Badge oben links: 30pt Kreis (24pt bei 3er-Dichte), Farbverlauf aus der jeweiligen Metrik-Akzentfarbe (siehe Palette unten), zweifarbig (heller Ton → 15% abgedunkelter Ton, 135°-Winkel) für etwas Tiefe statt Flat-Color.
- Label darunter (Caps, 10pt), dann große Zahl (30pt bei 2er-, 20pt bei 3er-Dichte), immer in `ink`.
- Sparkline optional darunter (nur bei 2er-Dichte, bei 3er ausgeblendet — zu wenig Platz), dünne Linie in der Metrik-Akzentfarbe bei ~70% Deckkraft.
- "as of [Zeitpunkt]"-Zeile unten, Sekundärfarbe, 11pt.
- Hauchdünner Hintergrundschimmer: ganze Kachelfläche, Metrik-Akzentfarbe bei ~10% Deckkraft.

### Metrik-Akzentpalette (nur für Icon-Badge + Schimmer, nie für Zahlentext)

Eigene Palette, bewusst getrennt von den vier Ring-/Langfrist-Familienfarben, um Kollisionen zu vermeiden:

| Metrik | Farbe (Dark) | Farbe (Light) |
|---|---|---|
| HRV | `#FF4D6D` | `#E23A57` |
| Ruhepuls | `#FF8A3D` | `#DB6E1E` |
| Atmung | `#2DD4BF` | `#0E9E8F` |
| Blutsauerstoff | `#22B8E0` | `#0E8FB0` |
| Fitness-Alter | `#F0B441` | `#B07908` |
| Schritte/Aktivität | neutral (`ink-3`), kein Akzent | — |

Neue Metriken (siehe Feature-Spec 4, Erweiterbarkeit) brauchen jeweils eine eigene Farbe aus dieser Palette-Familie — warme/kühle Zwischentöne, die sich klar von Charge-Grün, Effort-Blau, Rest-Violett und Langfrist-Gold unterscheiden.

### Wide-Kachel (Aktivität)
- Volle Breite, horizontales Layout, kein Icon-Badge, keine Farbe — reine Navigationszeile zum Detail.

### Bearbeitungsmodus
- Auslöser: Long-Press auf eine beliebige Kachel, oder Tap auf "Bearbeiten"-Label über dem Raster.
- Alle Kacheln (außer der Wide-Kachel) wackeln leicht (±0,7° Rotation, alternierend, versetzte Verzögerung für organische Wirkung).
- "−"-Badge oben links auf jeder Kachel (außer Wide) zum Ausblenden.
- Drag zum Umsortieren (native Drag-Reorder-Logik).
- Dichte-Umschalter (2/3) oben in einer eigenen Leiste, "Fertig"-Knopf rechts daneben.
- Ausgeblendete Metriken sammeln sich unterhalb des Rasters in einer eigenen Tray-Zeile mit "+"-Wiederherstellen-Button.

---

## 5. Abstände (überarbeitet ggü. früheren Entwürfen — mehr Luft)

| Zwischen | Abstand |
|---|---|
| Statusleiste → Kopfzeile | Standard-Padding |
| Kopfzeile → Ringe | 2pt (bewusst eng, gehören optisch zusammen) |
| Ringe → Kartenzone | 24pt |
| Kartenzone → "Vitalwerte"-Überschrift | 26pt |
| Kacheln untereinander/nebeneinander | 16pt (war 10pt in früheren Entwürfen) |
| Innenabstand Kachel | 18pt (war 14pt) |

---

## 6. Entscheidungen, die bewusst von naheliegenden Alternativen abweichen

Damit diese Punkte nicht in einer späteren Session versehentlich zurückgedreht werden:

- **Eine Warnfarbe statt vier verschiedene** für die Ausnahmezustände (Krank/Verletzt/Pause) im Status-Chip. Vier unterschiedliche Farben wurden erwogen (Grün/Rot/Orange/Gelb analog zu Bevel), aber verworfen: Grün kollidiert mit Charge, Orange/Gelb mit dem Fitness-Alter-Gold. Das Icon selbst unterscheidet die drei Zustände, nicht die Farbe.
- **Farbe sitzt im Icon-Badge, nie in der großen Zahl.** Ursprünglich waren farbige Zahlen im Gespräch (Vorbild: NOOPs eigenes "Vital Signs"-Referenzbild). Verworfen aus demselben Kollisionsgrund — bei potenziell zehn oder mehr Vitalwerten reicht die Familienfarbenzahl nicht aus, und farbige Fließtext-Zahlen sind schwerer lesbar als ein kleines Badge.
- **Kein Vierer-Raster.** Bewusst auf 2/3 begrenzt, damit die große Zahl und die "as of"-Zeile immer noch lesbar bleiben.
- **Status-Chip bleibt bei jedem Zustand icon-only im Ruhezustand**, auch bei Verletzt/Krank — trotz des Sicherheitsarguments, den Zustand dauerhaft sichtbar zu halten. Diese Erinnerungsfunktion übernimmt stattdessen die Basiskarte (siehe Feature-Spec 2), die ohnehin immer sichtbar ist.
