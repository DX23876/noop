# Apple-Health-Workouts: Ø-Puls, Max-Puls, Effort und Schritte

Stand: 2026-09-30 · Status: **umgesetzt 2026-09-30 (Rezept AI-16, WhoopStore v73)**

**2026-09-26:** Upstream hat #2440 samt Nachbesserungen gemergt (zugehöriger Puls via
`predicateForObjects(from:)` + `notNoopAuthored`, Rückfall aufs Band `62e3666e7`, eine Quelle für die ganze
Zeile `ccab5db02`). Beim Sync durch `ba68fd8cd` ist das in der History, `collectWorkouts` blieb aber
bewusst fork-eigen (Nutzerentscheidung): Die Funktion wird als Nächstes nach diesem Plan gebaut. Upstreams
Zwei-Schwellen-Regel (Ø/Max ohne Mindestmenge, Effort ab 20 Samples über 10 Minuten) und „eine Quelle
beantwortet die ganze Zeile“ sind als Vorlage brauchbar.

Anlass: Upstream-PR [ryanbr/noop#2440](https://github.com/ryanbr/noop/pull/2440) von `@rodrigosa7`
(„Health: Calculate effort for Apple Health workouts“, zu Issue
[#2439](https://github.com/ryanbr/noop/issues/2439)). Der Autor hat gefragt, ob wir das in den Fork aufnehmen.
Antwort: ja, aber auf Fork-Art umgesetzt (Text unten, §6).

---

## 1. Das Problem

Apple-Health-Workouts (Apple Watch, Lauf-Apps, alles, was in Health landet) werden mit Sportart, Dauer,
Kalorien und Distanz importiert, aber **ohne Ø-Puls, Max-Puls und Effort**. In der Workout-Liste und im
Detail bleiben diese Felder leer. Das gilt auch im Fork: `StrandiOS/Health/HealthKitBridge.swift`
(`collectWorkouts`) legt jede Apple-Zeile mit `avgHr: nil, maxHr: nil, strain: nil, steps: nil` an.

## 2. Was der PR macht

1. Pro Workout eine zweite HealthKit-Abfrage auf Puls im **Zeitfenster** des Workouts
   (`predicateForSamples(withStart:end:)`), daraus Ø, Max und Effort (`StrainScorer.strain`, Profil nötig,
   ≥ 20 Samples über ≥ 10 Minuten).
2. Schritte pro Workout über `HKStatisticsQuery` (cumulativeSum).
3. `HKMetadataKeyWorkoutBrandName` als `notes`.

Issue #2439 fordert zusätzlich, **bereits importierte** Workouts nachträglich zu füllen. Das macht der PR
nicht, er wirkt nur auf das jeweils synchronisierte Zeitfenster.

## 3. Warum nicht 1:1 übernehmen (geprüfte Fakten)

| Fakt | Stelle | Folge |
|---|---|---|
| NOOP schreibt Band-Puls **hochaufgelöst nach Health zurück** | `HealthKitBridge.highResQuantityWriteIds` enthält `.heartRate` | Die Zeitfenster-Abfrage des PRs sammelt NOOPs eigene Band-Samples wieder ein und gibt sie als Apple-Puls aus. Widerspricht dem Issue („do not use unrelated HR data“) und der PR-Beschreibung |
| Der Fork speichert pro Apple-Workout schon den **zugehörigen** Puls | `workoutHeartRateBuckets(for:)`: `predicateForObjects(from: workout)` + `notNoopAuthored`, als Minuten-Buckets in `workoutHeartRateBucket` (v60) | Datengrundlage ist da, auch für alte Workouts; keine zweite Abfrage nötig |
| Die Cardio-Last nutzt schon diese Reihenfolge | `Repository.priceCardioSessions`: Band-Verlauf ≥ 70 % Abdeckung → sonst Apple-Minuten-Puls → sonst nichts; Ledger `trainingSessionLoad` | Effort und Cardio-Last einer Einheit sollten auf demselben Puls beruhen |
| Präzedenzfall Zeilen-Füllung | `IntelligenceEngine` (manuelle Workouts, 14 Tage) + `ManualWorkoutRescore.scored`: füllt Ø/Max/Effort aus **Band-Puls** | Eine Zeile aus Band-Puls zu füllen ist etabliert |
| Zwillinge werden nach **Reichhaltigkeit** aufgelöst | `WorkoutSource.richness` zählt `avgHr`, `maxHr`, `strain`; `collapseCrossSource`, `TrainingSessionFusion` (Haupteintrag) | Gefüllte Apple-Zeilen könnten anders gewinnen als heute: Quellen-Rangfolge würde kippen |
| Effort-Wochensummen aus Zeilen | `WorkoutsView` (`rows.compactMap(\.strain)`) | Wochensummen ändern sich |
| Energie-Fallback nutzt Ø-Puls | `WorkoutEnergyDisplay`, `EnergySeries` (`WorkoutEnergyEstimate`) | Kalorien-Schätzungen für Workouts ohne kcal ändern sich |
| Re-Sync überschreibt Felder | `WhoopStore.upsertWorkouts`: `ON CONFLICT … DO UPDATE SET notes = excluded.notes …` | Markenname als Notiz würde eigene Notizen ersetzen |
| NOOP schreibt **keine** Schritte zurück | `quantityWriteIds` / `highResQuantityWriteIds` ohne `.stepCount` | Schritt-Abfrage ist unkritisch, NOOP-eigene trotzdem ausschließen |

**Nutzen für Training Load:** Mit Ø-Puls bekommen Apple-Läufe Beats pro km. Herzfrequenz-Effizienz
(Cardio-Nachweis, P1b) und trainingsbasierte VO₂max (P8) hätten mehr Einheiten.

## 4. Offene Entscheidungen (Grilling Runde 1, noch unbeantwortet)

| # | Frage | Empfehlung |
|---|---|---|
| Q1 | Welche Felder? | Ø-Puls, Max-Puls, Effort, Schritte. **Keine** „Notizen“ (Markenname). Zonen bleiben beim Lesen berechnet |
| Q2 | Woher kommt der Puls einer Apple-Zeile? | Wie die Cardio-Last: Band-Verlauf bei ≥ 70 % Abdeckung, sonst Apples Workout-Puls, sonst leer. Nie gemischt. Größter Gewinn, weil das Band dauerhaft getragen wird und die Uhr selten |
| Q3 | Zählen gefüllte Werte bei Zwillingen mit? | Nein: Reichhaltigkeit nur aus dem, was die Quelle selbst mitbrachte. Welche Zeile ein Training vertritt, bleibt wie heute |
| Q4 | Auflösung des Apple-Pulses | Immer aus den gespeicherten Minuten-Buckets (neu wie alt), derselbe Verlauf wie Cardio-Last und Zonen. Max-Puls ist dann eine Minuten-Spitze |
| Q5 | Ab wann füllen, welche Formel? | Abdeckungsregel der Cardio-Last (≥ 10 gedeckte Minuten, ≥ 70 %); Effort mit der eingestellten Methode (Edwards / Banister-Experiment) und der Profil-HRmax wie bei Band-Workouts |
| Q6 | Upstream | Antwort an den Autor mit Hinweis auf das Quellen-Problem (§6); nichts direkt am PR posten ohne Freigabe |

Folgefragen (nächste Runde, hängen von Q2/Q4 ab):
- Nachfüllen bestehender Workouts: ganze Historie aus den Buckets, fortsetzbar wie der Ledger-Backfill?
- Schritte für alte Workouts brauchen HealthKit, also nur über den Voll-Import: reicht das?
- Wie wird die Puls-Quelle einer Zeile sichtbar (Band oder Apple), z. B. über das Ledger (`hrSource`)?

## 5. Umsetzungsskizze (bei Empfehlungen Q1–Q6)

- **Import** (`collectWorkouts`): Die Buckets werden schon pro Workout gelesen; daraus plus ggf. Band-Verlauf
  Ø/Max/Effort berechnen. Schritte per `HKStatisticsQuery` mit `predicateForObjects(from: workout)`-Fenster
  und `notNoopAuthored`.
- **Gemeinsame Logik**: eine reine Funktion (Package) „Zeile füllen aus einem HR-Verlauf“, genutzt von
  Import, Nachfüllung und bestehender Manual-Füllung, damit es nur eine Regel gibt.
- **Deduplizierung**: Reichhaltigkeit ignoriert gefüllte Felder (Kennzeichnung nötig, z. B. über die Quelle
  des Werts).
- **Nachfüllen**: fortsetzbarer Lauf über alle Apple-Zeilen mit Buckets bzw. Band-Abdeckung.
- **Analysis migration required: ja.** Gespeicherte Workout-Werte ändern sich, gelesen von Nachweis,
  Effort-Rückfallachse, P8-Instrument, Energie-Fallback und Wochensummen → Rezept hochsetzen, begrenzter
  fortsetzbarer Lauf, Regressionstests, Release-Note.
- Verifikation: macOS + iOS bauen, `swift test`, App-Tests, danach CI bis grün verfolgen.

## 6. Antwort an den PR-Autor (Discord, 2026-09-24)

> hey thanks, nice idea! yeah same gap in my fork, apple health workouts show up without avg hr, max hr and
> effort. i'll add it 👍
>
> gonna build it a bit differently tho: my fork already pulls each apple workout's own hr for the cardio load
> stuff, so i'll just fill those fields from that instead of doing a second healthkit query. stealing your
> step count idea too 😄
>
> small heads up for your pr: `predicateForSamples(withStart:end:)` grabs every hr sample in that time
> window, and since noop writes the strap hr back to apple health you can end up counting noop's own samples
> as the workout hr. `HKQuery.predicateForObjects(from: workout)` plus skipping noop authored samples fixes
> that

---

## 7. Entscheidungen (Grilling 2026-09-30)

Befunde vorab: `collectWorkouts` legt Apple-Zeilen weiter ohne Ø/Max/Effort/Schritte an; der Workout-Puls wird
schon richtig gelesen (`predicateForObjects(from:)` + `notNoopAuthored`, Minuten-Buckets). Buckets gibt es erst
seit 2026-08-17 (28 Workouts); über 1.500 Apple-Workouts seit 2022 haben keine. Jede Synchronisierung
überschreibt `avgHr`/`maxHr`/`strain`/`steps` einer Apple-Zeile mit dem, was Health liefert (`upsertWorkouts`,
`DO UPDATE SET avgHr = excluded.avgHr …`). Ein Anzeige-Abgleich (`reconcileWorkoutHrWithTrace`) füllt heute
schon Ø/Max einer importierten Zeile aus der Band-Kurve, nur beim Lesen, ohne Abdeckungsregel und ohne Effort.
Ledger-Zeilen der Trainingslast gelten nach 7 Tagen als endgültig und werden ohne Anstoß nicht neu gerechnet.
Band-Ruhepuls fehlt 2023–2025 fast ganz (WHOOP-Pause); Apples Ruhepuls deckt 755 von 792 Walk-Tagen, Median
gleich dem WHOOP-Wert an 365 gemeinsamen Tagen.

| # | Entscheidung |
|---|---|
| Q1 | Felder: Ø-Puls, Max-Puls, Effort, Schritte. Keine Notiz. Zonen bleiben beim Lesen berechnet |
| Q2 | Puls vom Band bei ≥ 70 % Abdeckung, sonst Apple-Workout-Puls, sonst leer. Nie gemischt |
| Q3 | Gefüllte Werte zählen bei Zwillingen nicht; welche Zeile ein Training vertritt, bleibt wie heute |
| Q4 | Apple-Puls immer aus den Minuten-Buckets; Max ist die höchste Minute |
| Q5 | Füllen ab ≥ 10 gedeckten Minuten und ≥ 70 % (Regel der Trainingslast); Effort mit eingestellter Methode und Profil-HFmax |
| Q6 | WHOOP-Kopien in Health bleiben unverändert in der Liste, werden nicht gefüllt, in der Prüfung für Kalorien-Etappe 4 ausgeschlossen |
| Q7 | Ruhepuls: Tageswert WHOOP/NOOP, sonst Apple ±3 Tage, sonst kein Effort. Ein alter Ruhepuls wird allgemein höchstens 14 Tage weitergetragen |
| Q8 | HFmax über die Jahre fest (Profilwert) |
| Q9 | Ganze Geschichte seit 2022 nachladen (Buckets, Schritte, Quell-App), fortsetzbar, nur iPhone, Rezeptstufe |
| Q10 | Detail zeigt die Pulsquelle (Band / Apple Watch) |
| Q11 | Gefüllte Werte in eigener Tabelle, wie die Kalorienherkunft |
| Q12 | Neueste zuerst, etwa 50 Workouts pro Durchlauf |
| Q13 | Trainingslast der Geschichte im selben Durchlauf neu, wo jetzt Puls vorliegt |
| Q14 | Nur im Fork |

## 8. Technischer Plan

**Warum eine eigene Tabelle statt der Workout-Spalten:** die Spalten gehören der Quelle und werden bei jedem
Abgleich neu geschrieben. Gefüllte Werte liegen in `workoutHeartRateFill` und werden beim Lesen **nach** der
Zwillings-Auflösung über die Zeile gelegt. Damit gilt Q3 von selbst, und kein Abgleich löscht sie.

- **StrandAnalytics** `WorkoutHeartRateFill`: eine reine Funktion für Q2/Q4/Q5 (Band vor Uhr, Abdeckung
  ≥ 10 Minuten und ≥ 70 %, Minuten-Buckets als Kurve, Effort über `StrainScorer.strain`) und die Ruhepuls-Regel
  Q7. Die Trainingslast nutzt dieselbe Abdeckungsregel.
- **WhoopStore** v73: Tabelle `workoutHeartRateFill` (Schlüssel wie `workout`: deviceId, startTs, sport;
  Ø, Max, Effort, Quelle, benutzter Ruhepuls, gedeckte und mögliche Minuten), Spalte `steps` in
  `workoutSourceMetadata`, Löschen der Trainingslast-Zeilen ohne Puls für einen Zeitraum (Q13).
- **App:** Füllen nach jeder Health-Synchronisierung für ihr Fenster und nach jedem Nachlade-Paket; Überlagerung
  in `workoutRows` vor dem Anzeige-Abgleich; Pulsquelle und Health-Schritte im Detail.
- **iOS:** Nachladen der Geschichte, neueste zuerst, 50 Workouts pro Paket, Cursor in UserDefaults, nach jeder
  erfolgreichen Synchronisierung einige Pakete. Danach werden die Trainingslast-Zeilen dieser Workouts ohne Puls
  gelöscht und neu gerechnet.
- **Rezept AI-16:** füllt alle gespeicherten Apple-Workouts einmal; keine Tageszeile wird neu bewertet.
