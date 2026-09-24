# Training Load – Umbau- und Erweiterungsplan

Stand: 2026-09-24 · Branch: `claude/training-load-optimization-cfb32e` · Status: **beschlossen; P1–P6 umgesetzt** (offen: Jahresvergleich, P7, P8; Laufzeitprüfung des Backfills am echten iPhone-Datensatz)

Dieser Plan fasst die Untersuchung von Training Load zusammen (Code-Review, Messung gegen die echte
`StrandAnalytics`-Logik, Abgleich mit dem Polar-Whitepaper) und die in vier Grilling-Runden getroffenen
Entscheidungen (§5). Daraus folgen einzelne, je für sich lieferbare Pakete (§4), einschließlich der
Langzeit-Historie über Monate und Jahre, für die Lastwerte dauerhaft gespeichert werden müssen (§3).

---

## 1. Ausgangslage – was gemessen wurde

Alle Zahlen stammen aus einem temporären Test gegen die echten Funktionen (danach entfernt).

| # | Befund | Messung | Schwere |
|---|---|---|---|
| B1 | **Zwei Einstufungssysteme auf einem Screen.** Hero/Pille/Ring lesen die persönlichen Bänder (`TrainingLoadLanes.relativeStatus`: ±15/30 %, ab 8 Wochen Median ± MAD). 8-Wochen-Streifen und Überlastungswarnung lesen `TrainingStatusModel` mit 0,8/1,0/1,3. `TrainingStatusModel.statement()` (9-Fall-Matrix + Tests) wird seit dem Redesign `8e0ea74b9` nirgends mehr gezeigt. | −17 %: Hero „Below usual“, Streifen *maintaining*; +8 %: *usual* vs *productive*; +32 %: *Well above* vs *overreaching* | hoch |
| B2 | **Polar-Schwellen passen nach der Entkopplung nicht mehr.** Polar rechnet Tolerance über die letzten 28 Tage *inklusive* akuter Woche (gekoppelt). NOOP hat am 13.09. entkoppelt, die Schwellen aber behalten. Gekoppelt = 4u/(u+3). | Polar 1,3 ≙ entkoppelt **1,44**; Polar 0,8 ≙ **0,75** | hoch |
| B3 | **Kein Schutz bei geringer Last.** Polar zeigt unter WHO-Mindestaktivität „Productive“ statt „Overreaching“ und verlangt ≥ 3 Einheiten in 28 Tagen. NOOP hat nichts davon. | 1 → 2 lockere Einheiten/Woche = Verhältnis 2,0 → *overreaching* / „Well above usual“ | hoch |
| B4 | **Der unvollständige heutige Tag zählt voll mit.** | Tägliches Training: morgens −14 %, abends 0 %. *Korrektur bei der Umsetzung:* Bei Training jeden 2. Tag schwankt die Prozentzahl auch mit Tagesabschluss um ±14 % (3 oder 4 Einheiten in 7 Tagen); dort halten der breitere „Usual“-Bereich und die Hysterese die Stufe stabil (Test `testAlternateDayTrainingKeepsOneBand`) | hoch |
| B5 | **Das Lastsignal in Readiness ist praktisch blind.** Gekoppelte Fenster, log-Effort, `compactMap` staucht Kalendertage. Der Coach bekommt nur diese Zahl (`AICoach.readinessBlock`). | Last ×0,5 → 0,89; ×2 → 1,10; ×3 → 1,16 – immer Flag *good* | hoch |
| B6 | **„Effort over time“ (CTL/ATL/TSB) rechnet auf log-Effort.** Außerdem ist der Cache-Kommentar falsch: Bei τ = 42 hat Tag −42 noch 37 % Gewicht. | 14 Tage doppelte Last: ATL +12 % (Effort) statt +86 % (TRIMP) | mittel |
| B7 | **Effort (Tages-Strain) bewertet Zonen nach %HRR mit Edwards-Gewichten**, lockere Belastung zählt null. Die Cardio-Lane ist davon *nicht* betroffen (`edwardsTrainingLoad` = klassisches Edwards auf %HRmax). Zwei Rechenwege heißen also beide „Edwards“ und rechnen verschieden. | 60 min bei 118 bpm: Effort-Gewicht 0, Cardio-Lane 120 TRIMP | mittel |
| B8 | **Die Cardio-Lane ist eine Stufenfunktion**, Polar rechnet mit stetiger Banister-TRIMP. Ohne Profil gilt HRmax = 190 für alle. | 1 bpm an einer Zonengrenze = eine ganze Gewichtsstufe | niedrig–mittel |
| B9 | **Langzeit ist nicht darstellbar.** Cardio-TRIMP wird bei jedem Öffnen aus Roh-HR berechnet (Budget 300 Einheiten). Training Load liest 150 Tage. `hrSample` wird nie gelöscht (~52 MB/Tag), die Backup-Wiederherstellung endet bei 2 GB. | siehe §3 | hoch (strukturell) |
| B10 | **VO₂max-Quelle kann veraltet sein und als Nachweis zirkulär.** Apple gewinnt ab 4 Messungen in 8 Wochen, egal wie alt die letzte ist. NOOPs Schätzung ist entweder Nes 2011 (Aktivitätsindex aus Effort → die Last fließt selbst ein) oder Uth 2004 (nur Ruhepuls). | Nes: 3 Tage × Effort 45 → 5 Tage × Effort 75 = **+2,0 ml/kg/min** bei gleichem Ruhepuls (Schwelle 1,5 → „steigt“). Uth: Ruhepuls 55 → 52 = +2,9 | hoch |

Das funktioniert bereits gut und bleibt: drei getrennte Einheiten, keine Mischzahl; entkoppelte Fenster;
„unbekannt ≠ Ruhetag“; Anpassung getrennt von der Last; persönliche MAD-Bänder; Wartezeiten vor
„detraining“; die Überlastungswarnung ist bewusst keine Diagnose.

---

## 2. Zielbild

```
                ┌──────────────────────── gespeichert (neu) ────────────────────────┐
Roh-HR / HK-Minuten-HR ──► Session-Load-Ledger (Cardio, pro Einheit: TRIMP, Methode,
                           Quelle, Abdeckung, HRmax/Ruhepuls von damals, Fingerprint)
                └───────────────────────────────────────────────────────────────────┘
                                         │  + Sätze (dauerhaft) + sRPE (dauerhaft)
                                         ▼
               LaneSeries (rein, StrandAnalytics): Tagesreihe je Lane
               Wert | Ruhetag (0) | unbekannt (nil)
                                         │
                                         ▼
               LaneEngine (rein, StrandAnalytics) – EINE Einstufung
               Band · Low-Load-Schutz · Hysterese · Tagesabschluss · Urteil (Q27)
               Spielraum · Prognose · Langzeit-Aggregation
                                         │
     ┌──────────────┬───────────────┬────┴─────────┬──────────────┬───────────────┐
 Training Load   Strength/Cardio  Readiness-     Verlauf        Coach-Tool     VO₂max-
 (Hero, Streifen, Screens         Lastsignal     (Monate/Jahre) training_load  Resolver
  Warnung, Satz)                                                               (app-weit)
```

Grundsätze:
1. **Eine Rechenlogik, viele Anzeigen.** Keine Oberfläche stuft eine Last selbst ein.
2. **Teure oder vergängliche Rohdaten werden einmal in Werte übersetzt und gespeichert**, zusammen mit
   Methode und Eingaben.
3. **Einheiten bleiben getrennt**, auch im Verlauf: Lanes stehen nebeneinander, nie summiert.
4. **Herkunft ist sichtbar**: Band-Trace, Apple-Minuten, Durchschnittspuls (geschätzt).
5. **Kein Urteil ohne Leistungsnachweis**, und kein Nachweis, der die Last selbst mitrechnet.

---

## 3. Langzeitdaten – was vorhanden ist und was fehlt

| Lane | Rohdaten | Reicht zurück bis | Dauerhaft? | Problem für Langzeit |
|---|---|---|---|---|
| Kraft | Sätze (native Tabellen v61+, Hevy, Importe) | ganze Historie | ja | keines – beim Lesen günstig |
| Session Load | `trainingSessionRating` (v62) + Dauer | erste Bewertung | ja | Bewertungsquote |
| Cardio | Band-HR (`hrSample`, ab 2026-07-13); Apple-Minuten-HR (`workoutHeartRateBucket`, bis 10 J.); `workout.avgHr` | Band: Wochen; Apple: Jahre, lückenhaft | Rohdaten ja, **Last nein** | wird bei jedem Öffnen neu berechnet; lässt sich nicht mehr berechnen, falls Roh-HR je gelöscht wird |
| VO₂max | `appleDaily.vo2max`, NOOP-Wochenschätzung | Jahre | ja | Quellenwahl (B10) |
| e1RM | aus Sätzen | ganze Historie | ja | keines |

**Warum die Cardio-Last gespeichert wird:** Leistung (tausende Einheiten statt Budget 300), Speicher und
Backup (Roh-HR wächst um ~19 GB/Jahr, die Wiederherstellung endet bei 2 GB; eine künftige Löschregel für
Roh-HR darf keine Trainingshistorie kosten), historische Richtigkeit (HRmax und Ruhepuls von damals),
Nachvollziehbarkeit.

**Quellen-Rangfolge pro Einheit** (nie zusammengestückelt): Band-Trace → Apple-Minuten-HR →
*nur für den Verlauf*: Schätzung aus Durchschnittspuls (Banister 1991, markiert) → sonst unbekannt.

---

## 4. Pakete

Jedes Paket ist ein Commit auf diesem Branch. Der Push auf `main` erfolgt erst nach Freigabe (Q10).
Jedes beantwortet `Analysis migration required`. App-Target-Swift wird für **Strand und NOOPiOS**
gebaut (Q26). Kein Kotlin-Zwilling (Apple-only-Fork), das wird jeweils vermerkt.

Reihenfolge (Q9): **P1 → P3 → P2 → P5 → P4 → P6**, später P7, P8 und der Jahresvergleich.

### P1 – Eine Einstufung für den ganzen Screen + VO₂max-Resolver

Geliefert in zwei Commits: **P1a** (Einstufung, Schutzregeln, Urteil, Kopfsatz, Streifen, Warnung) und **P1b** (VO₂max-Resolver, Cardio-Nachweis).
Nachtrag zu P1a (Q32, Q33): Nicht bewertbare Tage fallen aus beiden Fenstern heraus, solange ≥ 5 von 7 und ≥ ¾ der Basis bekannt sind (Session Load bleibt „ganz oder gar nicht“); der persönliche Bereich hat die Grenzen „deutlich höher“ zwischen +15 % und +44 %, „unter üblich“ frühestens bei −10 %.

- `LaneEngine` in `StrandAnalytics`: Bänder, Low-Load-Schutz, Tagesabschluss, Hysterese, Urteilstabelle.
  `TrainingLoadLanes.relativeStatus` wandert ins Package.
- **Bänder** (Q11, Q21): bis 8 Wochen Below < −25 % · Usual −25…+15 % · Above +15…+44 % · Well above > +44 %
  (Außengrenzen aus Polar, auf entkoppelte Fenster umgerechnet; +15 % ist NOOPs eigene Wahl). Ab 8 Wochen
  persönlich (Median ± MAD der Wochensummen), „Well above“ aber spätestens ab +44 %.
- **Low-Load-Schutz** (Q3, Q22): kein Band unter 3 Einheiten in der 28-Tage-Basis. Unter 150
  Cardio-Minuten pro Woche bzw. 2 Krafttagen pro Woche (Mittel der Basis) höchstens „Above“.
- **Tagesabschluss** (Q2): Das Fenster endet heute nur, wenn heute schon Last angefallen ist, sonst gestern.
- **Hysterese** (Q8): Ein Band wird erst verlassen, wenn die Grenze um ≥ 5 Prozentpunkte überschritten ist.
- **Eine Skala** (Q1): Hero, Streifen und Warnung zeigen Bänder. Urteile gibt es nur im Kopfsatz
  (Tabelle Q27), `statement()` wird darauf neu aufgebaut und wieder angezeigt.
- **Überlastungswarnung**: „Well above“ an 3 Wochenenden in Folge **und** nachlassende Leistung **und**
  angespannte Erholung.
- **VO₂max-Resolver, app-weit** (Q28, Q30): NOOP-Schätzung als Hauptwert, darunter „Apple Watch zuletzt:
  X · vor N Wochen“. Gilt für Training Load, Cardio, Metric Explorer, Fitness Age und Coach.
- **Cardio-Nachweis** (Q29): Apple-VO₂max nur, wenn frisch (≥ 4 Messungen in 8 Wochen und die letzte
  ≤ 14 Tage alt) → sonst Herzfrequenz-Effizienz der Hauptsportart → sonst kein Nachweis. NOOPs
  VO₂max-Schätzung zählt nie als Nachweis.
- Demo-Modus-Override an die neuen Bänder anpassen; `decisions.md` richtigstellen („Polar unverändert“).
- **Migration: nein** (Anzeige wird beim Lesen berechnet).

### P2 – Readiness und Coach (Q6, Q18)
Geliefert: Readiness liest `Repository.readinessLoadContext` (aus denselben `LaneEngine`-Readings und Lesetagen wie der Screen, nach jedem Refresh neu gelesen). „Deutlich höher“ plus ein schlechtes Erholungssignal ergibt weiterhin *run down* (vorher: ACWR-Spike). Monotonie = `TrainingLoad.distribution` der Lane, Warnung ab 2,0 nur bei mindestens „wie üblich“. Coach-Tool `get_training_load` (Consent-Gruppe *workouts*); der Readiness-Block zeigt eine Zeile pro Lane statt der ACWR.
- Das Readiness-Lastsignal liest die `LaneEngine`: *watch*, sobald Kraft **oder** Cardio „Well above usual“
  steht und der Low-Load-Schutz nicht greift. Ohne Lane-Kontext entfällt das Signal. Session Load
  zählt nicht.
- Monotonie in Readiness und in `TrainingLoad.distribution` einheitlich definieren.
- Coach-Tool `training_load` (Lanes, Band, Urteil, Abdeckung; ab P6 auch Spielraum und Prognose);
  die ACWR-Zeile in `readinessBlock()` wird ersetzt. Nur sichtbar, wenn der Coach eingeschaltet ist.
- **Migration: nein** (die Readiness-Stufe wird nirgends gespeichert, geprüft).

### P3 – Session-Load-Ledger für Cardio (Q5, Q15, Q16, Q17)
```
trainingSessionLoad (Migration v70 + Test)
  sessionKey TEXT, method TEXT, methodVersion INT, startTs INT, endTs INT, trimp REAL,
  hrSource TEXT (noop_band | healthkit_workout | avg_hr), coveredMinutes INT, possibleMinutes INT,
  hrmaxUsed REAL, restingHrUsed REAL NULL, inputFingerprint TEXT, computedAtTs INT
  PRIMARY KEY (sessionKey, method, methodVersion) · INDEX (startTs)
```
- Schreiben nach Import, nach Band-Einheiten und nach der Workout-Erkennung. Nachberechnen in kleinen
  Portionen bei offener App **und** nachts über `RescoreBackgroundScheduler`, die neuesten Einheiten zuerst,
  fortsetzbar mit eigenem Cursor.
- `cardioLoads(for:)` liest zuerst das Ledger. Das Budget von 300 gilt nur noch für das Nachberechnen.
- HRmax von damals bleibt gespeichert. Nach einer HRmax-Änderung gibt es unter „Methode“ einen Button
  „Historie neu berechnen“, der nur dort wirkt, wo Rohdaten liegen (Q15).
- Bei Formelwechsel wird ersetzt, wo Rohdaten vorhanden sind. Die alte Zeile bleibt nur dort, wo Rohdaten
  fehlen, markiert (Q16).
- Gleichheitstest: Ledger-Ergebnis = heutiges On-Read-Ergebnis.
- **Migration:** Schema ja; Analyse nein (gleiches Ergebnis).

### P4 – Cardio-Lane auf Banister (Q4, Q13, Q14)
Geliefert als Analyse-Rezept **AI-9** (die Rezeptversion heißt seit diesem Stand „AI-n“ und liegt unter `noopai:analysisRecipeVersion`, damit sie nie mit einem späteren upstream-Zähler kollidiert). Ruhepuls: Median ±3 Tage, sonst ±30 Tage, sonst alle gelesenen Tage, sonst 60. Ledger-Methode `banister-hrr`; die Migration füllt das Ledger über die ganze Historie und bewertet keinen Tag neu (Effort unverändert). Alte `edwards-hrmax`-Zeilen bleiben stehen, werden aber nicht mehr gelesen – zwei Skalen dürfen in einer Lane nicht gemischt werden (präzisiert Q16). Durchschnittspuls-Schätzungen werden als `avg_hr` gespeichert und nur im Verlauf als heller Aufsatz gezeigt. Die klassische %HRmax-Edwards-Funktion ist entfernt; „Edwards“ bezeichnet damit nur noch den Effort-Rechenweg (B7). Nebenbei behoben: Der Ledger-Nachlauf endete nie, solange eine frische, nicht bepreisbare Einheit existierte.
- Banister-TRIMP (stetig, mit Ruhepuls = Median `restingHr` ±3 Tage). b = 1,92 (männlich), 1,67 (weiblich),
  **1,795 (nonbinary / Standard)**. Effort bleibt unverändert; sein %HRR-Rechenweg bekommt einen
  eigenen Namen statt „Edwards“.
- Schätzung aus Durchschnittspuls für alte Workouts ohne Trace, **nur im Verlauf**, markiert als
  „geschätzt“. Die aktuelle Einstufung nutzt nur gemessene Verläufe.
- Umstellung über `method`/`methodVersion`, Neuberechnung durch den P3-Mechanismus.
- **Migration: ja** – `currentAnalysisRecipeVersion` hochsetzen, Regressionstests, Hinweis in den Release Notes.

### P5 – Verlauf (Q7, Q19, Q20, Q23, Q24)
Geliefert: `TrainingHistory` (StrandAnalytics) + `TrainingHistoryView`. Langzeitniveau = Mittel der bekannten Tageslast über 42 Tage × erfasste Tage der Periode (mind. 21 bekannte Tage). Band je Periode = `LaneEngine`-Reading am letzten erfassten Tag. Noch nicht bepreiste Cardio-Einheiten zählen als unbekannt (schraffiert), bis der P3-Backfill sie erreicht. Die Karte „Effort over time“ ist entfernt; `TrainingLoadEngine`/`evaluateWithTrainingLoad` bleiben im Package, werden in der App aber nicht mehr gelesen.
- Eigener Screen **Verlauf**, erreichbar aus Training Load, Trends (anstelle der Karte „Effort over time“,
  die entfällt), Kraft und Cardio, jeweils auf die passende Lane gefiltert.
- Zeiträume 3 M · 1 J · 5 J · Alles plus **Sprung zu einem Datum**. Auflösung Tage bis 3 M, Wochen bis 2 J,
  darüber Monate.
- Pro Lane (Kraft, Cardio, Session Load): Balken pro Periode mit schraffierten Lücken, Langzeitniveau
  (42-Tage-Linie derselben Lane), Band-Verlauf als Farbstreifen, Anpassung darüber (e1RM der 3 meisttrainierten
  Übungen, austauschbar und gespeichert; VO₂max aus dem Resolver). Bei Session Load steht die
  Bewertungsquote dabei.
- **Migration: nein.**

### P6 – Erweiterungen (Q25), in dieser Reihenfolge
Geliefert: Spielraum (Bisektion gegen `relativeLoad` + `LaneEngine.thresholds`, abgerundet) und Prognose (`LaneEngine` mit Hysterese über fortgeschriebene Ruhetage, max. 21 Tage) als Karte „Spielraum heute“ und im Coach-Tool; Bewertungsquote auch auf der Session-Load-Kachel (Erinnerung nach der Einheit bestand bereits); `estimate_session_effort` ordnet eine geplante Einheit gegen den Cardio-Spielraum ein; Band pro Muskelgruppe auf dem Kraft-Screen; Mitteilung in den Automationen, standardmäßig aus, einmal pro Hochphase.
1. Wochen-Spielraum (persönliche Obergrenze − letzte 6 Tage)
2. Prognose (Fortschreiben mit Ruhetagen: „wieder im üblichen Bereich am …“)
3. Bewertungsquote Session Load + Erinnerung nach der Einheit
4. Coach prüft geplante Einheiten gegen den Spielraum
5. Kraft-Band pro Muskelgruppe
6. Mitteilung beim Überschreiten der Obergrenze (standardmäßig aus, nur mit eingeschaltetem Coach bzw.
   ausdrücklich aktiviert)

**Migration: nein.**

### Später
- **Jahresvergleich** im Verlauf (dieses gegen letztes Jahr, kumuliert).
- **P7 Aufbewahrung von Roh-HR** (Größe, 2-GB-Backup-Grenze). Braucht P3.
- **P8 Trainingsbasierter NOOP-VO₂max** (Q31) aus Läufen und Gehstrecken, über das Verhältnis von Puls zu
  Tempo. Zuerst nur messen und protokollieren bzw. experimentell (standardmäßig aus). Als Nachweis erst,
  wenn gezeigt ist, dass er veränderten Eingaben folgt (CLAUDE.md-Regel zu abgeleiteten Signalen).

---

## 5. Beschlossene Entscheidungen

| # | Frage | Entscheidung |
|---|---|---|
| Q1 | Skala | Last überall relativ (Below / Usual / Above / Well above). Urteile nur im Kopfsatz |
| Q2 | Laufender Tag | Fenster endet heute nur mit Last, sonst gestern |
| Q3 | Wenig Training | ≥ 3 Einheiten in 28 Tagen; unter WHO-Mindestmenge höchstens „Above“ |
| Q4 | Cardio-Formel | Banister fest für die Lane, Effort unverändert |
| Q5 | Speicherung | Ledger nur für Cardio |
| Q6 | Readiness | Lastsignal auf Lanes umstellen, kein Dauer-*good* |
| Q7 | Trends-Karte | entfällt, Link zum Verlauf |
| Q8 | Grenzstabilität | 5 Prozentpunkte Hysterese |
| Q9 | Reihenfolge | P1 → P3 → P2 → P5 → P4 → P6 |
| Q10 | Lieferung | ein Commit pro Paket auf dem Branch, Push auf main nach Freigabe |
| Q11 | Bänder bis 8 Wochen | −25 % / +15 % / +44 % |
| Q12 | Urteile | für beide Lanes gleich: Band + Nachweis + Erholung; ohne Nachweis nur Beschreibung |
| Q13 | Banister nonbinary | b = 1,795 |
| Q14 | Durchschnittspuls-Schätzung | ja, nur im Verlauf, markiert |
| Q15 | HRmax-Änderung | Historie bleibt; Neuberechnung per Button |
| Q16 | Formelwechsel | ersetzen, wo Rohdaten da sind, sonst alte Zeile markiert behalten |
| Q17 | Nachberechnen | Portionen bei offener App + nachts, neueste zuerst |
| Q18 | Readiness-Lanes | Kraft und Cardio |
| Q19 | Ort des Verlaufs | eigener Screen, Einstieg aus 4 Stellen, gefiltert |
| Q20 | Verlauf v1 | Zeiträume + Datumssprung, Balken, Langzeitniveau, Bänder, Anpassung; Jahresvergleich später |
| Q21 | Persönliche Bänder | „Well above“ spätestens ab +44 % |
| Q22 | WHO-Messung | Cardio-Minuten bzw. Krafttage pro Woche, ohne Pulsverlauf |
| Q23 | e1RM im Verlauf | Top 3 automatisch, austauschbar, gespeichert |
| Q24 | Lanes im Verlauf | Kraft, Cardio, Session Load (mit Bewertungsquote) |
| Q25 | Erweiterungen | Spielraum → Prognose → Bewertungsquote → Coach-Planprüfung → Muskelgruppen → Mitteilung |
| Q26 | Plattformen | iOS und macOS gemeinsam |
| Q27 | Urteilstabelle | siehe unten |
| Q28 | VO₂max-Anzeige | NOOP als Hauptwert, Apple mit Datum darunter |
| Q29 | Cardio-Nachweis | Apple frisch → Herzfrequenz-Effizienz → kein Nachweis; NOOP-Schätzung nie |
| Q30 | VO₂max-Resolver | app-weit, einer |
| Q31 | Trainingsbasierter NOOP-VO₂max | späteres Paket P8, erst nach Validierung als Nachweis |
| Q32 | Mindestbreite persönlicher Bereich | „deutlich höher“ frühestens +15 %, „unter üblich“ frühestens −10 % |
| Q33 | Unbekannte Tage im Vergleich | aus beiden Fenstern entfernen, solange ≥ 5/7 und ≥ ¾ der Basis bekannt; sonst kein Vergleich |

### Q27 – Urteilstabelle (Kraft: e1RM, Cardio: Nachweis nach Q29)

| Band ＼ Anpassung | steigt | unklar | fällt | kein Nachweis |
|---|---|---|---|---|
| **Below** | hält | hält → *detraining* ab 21 Tagen (Kraft) / 14 Tagen (Cardio) | *detraining* | „weniger als üblich“, ab 21/14 Tagen *detraining* |
| **Usual** | *productive* | hält | *unproductive* | „wie üblich“ |
| **Above** | *productive* | hält | *unproductive* | „mehr als üblich“ |
| **Well above** | Erholung gut → *productive*, sonst *overreaching* | Erholung gut → *unproductive*, sonst *overreaching* | *overreaching* | Erholung angespannt → *overreaching*, sonst „deutlich mehr als üblich“ |

Nach einer Hochphase gilt *recovering* statt *detraining*. Der Low-Load-Schutz deckelt auf „Above“.

### Abgeleitete Festlegungen
- **Herzfrequenz-Effizienz:** Die Hauptsportart ist die häufigste Ausdauersportart mit Distanz im
  8-Wochen-Fenster. Verglichen wird nur exakt dasselbe Sport-Label. Nötig sind ≥ 4 Einheiten und
  dieselbe Theil–Sen-Übereinstimmungsregel wie beim e1RM, plus eine Mindeständerung von 3 % über den
  Zeitraum (NOOPs eigene Wahl, im Screen so benannt).
- **Fitness Age** bleibt bei Nes mit Aktivitätsindex (dort so definiert).
- Coach-Tool und Mitteilung erscheinen nur mit eingeschaltetem Coach.
- Jede Entscheidung bekommt einen Eintrag in `decisions.md` mit „Analysis migration required“.

---

## 6. Verifikation (jedes Paket)

- `swift test` in `Packages/StrandAnalytics` bzw. `Packages/WhoopStore`.
- `xcodegen generate` + `xcodebuild` für **Strand** (macOS) und **NOOPiOS**. Für iOS muss vorher
  `Vendor/Nomic` im Worktree verlinkt sein.
- Nachberechnen und Verlauf am echten Datensatz prüfen (iPhone-DB-Pull): Laufzeit über 10 Jahre,
  Speicherzuwachs, Gleichheitstest P3.
- `doc_comment_lint` beachten; Build-Änderungen an `Localizable.xcstrings` vor Commits zurücksetzen,
  neue Strings per Xcode-Build.

## 7. Risiken

| Risiko | Gegenmaßnahme |
|---|---|
| Nachberechnen über Jahre bremst den Start | niedrige Priorität, Portionen, neueste zuerst, fortsetzbar |
| Ledger und On-Read laufen auseinander | Gleichheitstest in P3; Fingerprint mit Datenrevision |
| Neue Bänder und Urteile ändern gewohnte Anzeigen | Release Note; Methodenerklärung im Screen |
| Lückenhafte alte Apple-HR sieht aus wie wenig Training | Abdeckung pro Periode, schraffierte Lücken |
| Herzfrequenz-Effizienz verrauscht (Hitze, Gelände) | Mindeständerung 3 %, gleiche Sportart, Theil–Sen-Übereinstimmung, sonst kein Nachweis |
