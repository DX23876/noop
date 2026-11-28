# Training Load – Umbau- und Erweiterungsplan

Stand: 2026-09-24 · Branch: `claude/training-load-optimization-cfb32e` · Status: **beschlossen; P1–P6 und P8 (als Messinstrument) umgesetzt** (offen: Jahresvergleich, P7; Laufzeitprüfung des Backfills und P8-Validierung am echten iPhone-Datensatz) · **Phase 2 beschlossen 2026-11-28** (§8), Schritt 1 umgesetzt

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
| Q34 | Methode trainingsbasierte VO₂max | ACSM-Gleichungen + %HRR ≙ %VO₂R, Durchschnitt pro Einheit, Steigung flach angenommen und benannt; Höhe erfassen als späterer Ausbau |
| Q35 | Welche Einheiten | Laufen > 8 km/h, Gehen 3–6 km/h, ≥ 20 min, mit Distanz, gemessener Pulsverlauf, 40–85 % HRR |
| Q36 | Anzeige/Speicherung | beim Lesen berechnet, Wochen-Median, Schalter Einstellungen › Experimentell (aus), kein Nachweis |
| Q37 | Validierungsregel | ≥ 8 Wochen-Paare mit Apple (±7 Tage), MAE ≤ 3,5 ml/kg/min, Richtung ≥ 70 %; synthetisch mehrere Werte wiederfinden |

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

---

## 8. Phase 2 (2026-11-28): Rat statt Rückblick

Beschlossen in fünf Grilling-Runden am 2026-11-28 (43 Fragen, Q1 bis Q43). Leitfrage: Wie sagt die
Trainingsbelastung jedem Menschen morgens in einem Satz, was die Woche verlangt hat, ob es für das eigene Ziel
genug war und was heute sinnvoll ist? Für schwere wie leichte Menschen, Einsteiger wie Trainierte, mit und
ohne Coach, mit und ohne Ernährungslog.

### 8.1 Befunde im Code

| # | Art | Befund |
|---|---|---|
| 1 | Fehler | Deutlich über üblich mit unklarem Leistungsnachweis bei guter Erholung hieß „unproduktiv“. Beim Gehen ist der Nachweis fast immer unklar. **Behoben in Schritt 1.** |
| 2 | Fehler | Unbekannte Erholung (weniger als vier Nächte mit Erholungswerten) zählte in der Zeile „deutlich über üblich“ wie angespannte; die Spalte ohne Nachweis las sie wie „hält“. **Behoben in Schritt 1.** |
| 3 | Lücke | Die Trainingsbelastung liest kein Ziel, keinen Ernährungsplan, kein Wochenziel. |
| 4 | Doppelt | Das Effort-Ziel auf Today kommt allein aus Charge (`CoupledView.optimalStrainRange`, Kotlin-Kopie in `CoupledLogic.kt`) und kennt die Woche nicht. Der Coach hat in seinen Anweisungen eine eigene Regel vom Readiness-Urteil zur Vorgabe, die Vorschlagsknöpfe (`CoachSuggestions`) eigene Charge-Grenzen. Drei Regeln für eine Aussage. |
| 5 | Lücke | Cardio-Nachweis nur aus frischem Apple-VO₂max oder Schlägen pro Kilometer in der häufigsten Sportart; erkannte Gehrunden ohne GPS haben keinen. |
| 6 | Lücke | Übungen mit Körpergewicht haben keine geschätzte Maximalkraft und fallen aus dem Kraftnachweis. |
| 7 | Lücke | Bewertungen der Härte fließen nur in Session Load und den Zyklusvergleich. Bei erkannten Einheiten kommt die Bewertungsmitteilung vermutlich zu spät (Fenster 30 Minuten plus 15 Minuten Kulanz), auf echten Daten fehlen Bewertungen fast ganz. |
| 8 | Lücke | Die Pulserholung nach hartem Ende wird je Einheit gemessen, die Trainingsbelastung liest sie nicht. |
| 9 | Lücke | Das Krankheitssignal (`IllnessSignalEngine`) liest weder Urteil noch Spielraum. |
| 10 | Hinweis | Der Kopf von `TrainingLoad.swift` nannte für Cardio noch Edwards. **Behoben in Schritt 1.** |

Auf echten Daten (Kopie vom 2026-11-27, nur gelesen): Die meisten Einheiten sind erkannte Gehrunden ohne
Strecke; der Strap speichert Schritte etwa jede Sekunde, die Schrittfrequenz pro Minute ist also vorhanden; gut
die Hälfte der erkannten Gehrunden endet hart genug für die Pulserholung; GPS-Aufzeichnungen tragen
Kilometerabschnitte mit Zeit und Höhe, sind aber selten.

### 8.2 Grundregeln

1. Fehlt ein Nachweis, ist das kein Misserfolg. „Unbekannt“ wird nie wie „schlecht“ gelesen.
2. Zwei Fragen, getrennt beantwortet: „zu viel?“ gegen das eigene Übliche, „genug?“ gegen das eigene Ziel oder
   die WHO-Empfehlung. Nie eine gemeinsame Zahl.
3. Eine Quelle für den Morgen im Kern. Today, Effort-Ziel, Trainingstab, Coach und Mitteilung zeigen nur sie.
4. Intensität am eigenen Herz: Anteil der Spanne zwischen Ruhe- und Maximalpuls. Wo der Puls nichts aussagt,
   zählen Dauer und Bewertung, offen benannt.
5. Alltagseinheiten (Minuten, Sätze, Tage); Belastungspunkte bleiben in der Tiefe.
6. Fehlende Daten machen den Rat nie mutiger und aus einem normalen Tag keine Pause.

### 8.3 Bausteine

**A Ehrliches Urteil.** Tabelle korrigiert (Schritt 1). Neue Wörter: Produktiv „Bringt Fortschritt“, Erhaltend
„Hält dein Niveau“, Unproduktiv „Kein Fortschritt sichtbar“, Überlastend „Auf Dauer zu viel“, Abbauend „Form
lässt nach“, Erholend „Erholungsphase“, dazu ein Satz je Ziel („Trägt dein Abnehmen“). Erfolg je Ziel:

| Ziel | Cardio gilt als Erfolg | Kraft gilt als Erfolg | „Genug“ |
|---|---|---|---|
| Abnehmen | Zielminuten in mindestens drei der letzten vier Wochen, Erholung nicht angespannt | Maximalkraft höchstens 5 % unter dem Stand von vor sechs Wochen | 250 bis 300 Minuten, zwei Krafttage |
| Zunehmen, Muskelaufbau | WHO-Minimum gehalten | Maximalkraft steigt | 150 Minuten, zwei bis drei Krafttage |
| Halten | Leistung wie bisher | wie bisher | WHO |
| Ausdauer, Laufen, Fitness | VO₂max, Puls bei gleicher Belastung oder Pulserholung besser | wie bisher | Wochenziel des Ziels |
| Kraft, harte Sätze | WHO-Minimum gehalten | Maximalkraft, bei Körpergewicht Wiederholungen | Zielsätze oder Zielminuten |
| Regelmäßigkeit, Aktivität | Einheiten, Minuten oder aktive Tage gegen das Ziel | | das Ziel |
| nur Beweggrund oder kein Ziel | WHO-Minuten, Ruhepuls als Hintergrund | wie bisher | WHO |

Das Ziel kommt automatisch aus Ernährungsplan und Gewichtsziel, Trainingsziele gelten für ihre Spur; ein
Schwerpunkt (Abnehmen, Fitness, Kraft, Gesundheit) ist wählbar. Gewicht ist nie Cardio-Nachweis. Bewertungen
heben ein unklares Urteil auf „Hält dein Niveau“ (mindestens vier vergleichbare bewertete Einheiten, über sechs
Wochen mindestens ein Punkt leichter), nie allein auf Fortschritt. Ein neues Ziel bekommt zwei Wochen nur eine
Beschreibung. Hinweis „Pensum oder Defizit prüfen“ bei mehr als 5 % Kraftverlust, mehr als 1 % Gewichtsverlust
pro Woche und angespannter Erholung, nie als medizinische Aussage.

**B Nie leer.** „Genug?“ ab dem ersten Tag nach WHO (150 bis 300 Minuten moderat oder 75 bis 150 hoch, hohe
doppelt, zwei Krafttage; moderat 40 bis 59 % der Pulsspanne, hoch ab 60 %), je Ziel angehoben, WHO als
Untergrenze. Alltagsminuten über 40 % außerhalb von Einheiten zählen schon jetzt, nur mit Schritten im selben
Zeitraum; Effort bleibt dabei unverändert, der zweite Effort-Schritt übernimmt später dieselbe Minutenregel.
Der Zielwert erscheint unter „Deine Woche“, ein eigenes Wochenziel geht vor. Profileinstellung „Mein Puls zeigt
meine Belastung nicht richtig“ (Standard aus, nennt nie ein Medikament). Einheiten ohne Puls erscheinen als
„ohne Puls“ und zählen mit Bewertung ab 4 als moderat. Randfälle: unter 18 kein Erwachsenenziel, ab 65 Hinweis
auf Gleichgewicht und Kraft, Schwimmen nach Dauer und Bewertung, Schwangerschaft auf der Erklärseite benannt,
Rollstuhl vorerst über Pulsminuten.

**C Rat am Morgen.** Vier Lagen: Gas geben, Normal, Locker, Schonen (Push, Steady, Easy, Rest), mit Grund,
Angeboten und Effort-Ziel. Die erste Regel, die greift, entscheidet: (1) Krankheitssignal oder Zielpause wegen
Krankheit oder Schmerz: Schonen; (2) angespannte Erholung bei einer Spur deutlich über üblich: Schonen; (3)
Charge unter 34: Locker; (4) eine Spur deutlich über üblich: Locker für diese Spur; (5) Plan für heute, bei
Charge 34 bis 66 kürzer oder lockerer; (6) Woche hinter dem Ziel bei Charge ab 67, Erholung nicht angespannt:
Gas geben; (7) sonst Normal. Das Effort-Ziel bleibt das Band aus Charge, gedeckelt durch Regel 1 bis 4. Der Rat
steht fest, sobald Charge da ist („wartet auf die Nacht“ davor, „ohne Nacht“ ohne Messung, dann nie Gas geben),
nach einer Einheit „Erledigt“ mit Restspielraum. Mitteilung nur auf Wunsch. „Trotzdem trainieren“ geht immer.

**D Angebote.** Spielraum in Minuten der eigenen typischen Einheit (Median der Belastung pro Minute dieser
Sportart) und harten Sätzen für Muskelgruppen mit Luft; abgerundet auf 5 Minuten, keines unter 10, Startangebot
30 Minuten zügiges Gehen. „Was wäre wenn“ zeigt die Woche danach. Die nächste harte Einheit lässt sich auf Tippen
verschieben.

**E Bessere Nachweise.** Leiter: frischer Apple-VO₂max, Puls bei gleicher Schrittfrequenz (Schritt 4),
Pulserholung im Verlauf (Schritt 4), Puls bei gleichem Tempo aus GPS (später), Schläge pro Kilometer, Bewertung
bei gleicher Belastung (schwach). Ruhepuls nur Hintergrund. Prüfregel, vorher im Code festgelegt: Ein
künstlicher Test erkennt mehrere eingebaute Veränderungen; über mindestens acht Wochenvergleiche zeigt der Wert
in mindestens 70 % der Fälle in dieselbe Richtung wie ein unabhängiger Wert (Apple-VO₂max, GPS-Tempo-Puls oder
Ruhepuls), beim Owner und bei einem Tester. Bis dahin nur im Labor. Gewichtsverlust senkt den Puls bei gleicher
Belastung; das heißt „Alltagsfitness“, nicht VO₂max.

**F Coach.** Die App entscheidet, der Coach erklärt und plant. Effort-Ziel, Coach-Anweisungen und
Vorschlagsknöpfe lesen den Rat; das Readiness-Urteil bleibt seine Grundlage. Ist der Morgenbrief an, beginnt er
mit dem Rat, eine eigene Mitteilung entfällt. Geplante Einheit (vom Coach oder aus der Routine) und Angebote
stehen in einer Liste. Widerspricht der Plan, gewinnt der Rat; Tauschen oder Kürzen auf Tippen. Coach-Vorschläge
gegen den Rat werden markiert, nicht gesperrt. Ohne Schlüssel funktioniert alles außer Gespräch, geschriebenem
Brief und erstellten Wochenplänen.

**G Ernährung.** Ernährung erklärt das Urteil, entscheidet es nicht („gegessen über Plan“ statt „Cardio bringt
nichts“). Eine Sicherheitsregel: vollständige Tage mehr als 500 kcal unter Plan oder unter 1.200 kcal bei hoch
belasteter Woche: kein Gas geben, ruhiger Hinweis, nie Lob für wenig Essen. Food-Seite und Trainingsbelastung
lesen eine Kraftrechnung über sechs Wochen (heute rechnet `DietAdvice` über vier). Protein unter 80 % des Ziels
erscheint als möglicher Grund für sinkende Kraft. Nur vollständig markierte Tage zählen. Ohne Log kein
Unterschied, keine Aufforderung. Der Coach plant weiter keine Ernährung.

### 8.4 Entscheidungen

| Q | Entscheidung |
|---|---|
| Q1 | Tabellenkorrektur vorab mit den Review-Korrekturen der Energie- und Gewichtsseite |
| Q2 | Alltagssätze statt Fachwörter, dazu ein Satz je Ziel |
| Q3 | Ziel automatisch aus Plan und Gewichtsziel, Schwerpunkt wählbar |
| Q4 | Vier Lagen am Morgen |
| Q5 | Rat auf Today und oben im Trainingstab aus einer Quelle, dazu im Coach |
| Q6 | „Genug“ je Ziel, WHO als Untergrenze |
| Q7 | Profileinstellung für Puls, der die Belastung nicht zeigt |
| Q8 | Einheiten ohne Puls mit Bewertung ab 4 als moderat, markiert |
| Q9 | Mehrere Ziele für eine Spur: Schwerpunkt, sonst nächstes Zieldatum |
| Q10 | Kraft im Defizit gehalten bis 5 % Rückgang in sechs Wochen |
| Q11 | Bewertungen als Zünglein, nie allein Fortschritt |
| Q12 | Erkannte Einheiten: Bewertung bis drei Stunden nach dem Ende, sonst im Morgenrat, höchstens einmal |
| Q13 | Körpergewichtsübungen zählen über die Wiederholungen |
| Q14 | Effort-Ziel folgt dem Rat |
| Q15 | Rat fest für den Tag, nach einer Einheit „Erledigt“ |
| Q16 | Morgenmitteilung nur auf Wunsch |
| Q17 | Verschieben im Plan nur auf Tippen |
| Q18 | „Gas geben“ nur bei Charge ab 67, Erholung nicht angespannt, Woche hinter dem Ziel |
| Q19 | Zuerst Schrittfrequenz-Puls und Pulserholung, GPS-Tempo später |
| Q20 | Alltagsminuten für „genug“ jetzt, nur mit Schritten, Effort unverändert |
| Q21 | Randfälle wie in 8.3 B |
| Q22 | Regelreihenfolge wie in 8.3 C |
| Q23 | Die App entscheidet, der Coach erklärt |
| Q24 | Effort-Ziel, Coach-Anweisungen und Vorschlagsknöpfe lesen den Rat |
| Q25 | Eine Morgenmitteilung; mit Brief beginnt er mit dem Rat |
| Q26 | Geplante Einheit und Angebote in einer Liste |
| Q27 | Bei Widerspruch gewinnt der Rat |
| Q28 | Coach-Vorschläge gegen den Rat markiert, nicht gesperrt |
| Q29 | Ohne Schlüssel alles außer Gespräch, Brief und Wochenplänen |
| Q30 | Abnahme: eine Woche alt und neu nebeneinander auf dem iPhone des Owners, ein Tester ohne Coach auf Android |
| Q31 | Fünf Schritte (8.5), ab Schritt 2 ein eigener Zweig |
| Q32 | Namen der Lagen wie in 8.3 C |
| Q33 | „Genug“ erscheint unter „Deine Woche“, eigenes Wochenziel geht vor |
| Q34 | Gebaut in der echten App, iPhone zuerst, Android am Ende im Vergleich |
| Q35 | Prüfregel für neue Nachweise wie in 8.3 E |
| Q36 | Dieses Kapitel; je Schritt ein Eintrag in `decisions.md` |
| Q37 | Ernährung erklärt, entscheidet nicht |
| Q38 | Sicherheitsregel bei deutlich zu wenig Essen |
| Q39 | Eine Kraftrechnung über sechs Wochen für Food-Seite und Trainingsbelastung |
| Q40 | Protein unter 80 % als möglicher Grund für sinkende Kraft |
| Q41 | Nur vollständig markierte Tage |
| Q42 | Ohne Ernährungslog kein Unterschied, keine Aufforderung |
| Q43 | Der Coach plant keine Ernährung, nennt aber die Hinweise |

### 8.5 Reihenfolge

1. **Tabellenkorrektur** (Befund 1, 2, 10). Umgesetzt 2026-11-28. Analysis migration required: no.
2. **Urteil nach Ziel:** neue Wörter, Schwerpunkt, „genug?“ mit Alltagsminuten und „Deine Woche“,
   Körpergewichtsübungen, Bewertungsabfrage für erkannte Einheiten, Krankheitssignal, Ernährung als Erklärung mit
   einer Kraftrechnung. Eigener Zweig. Analysis migration required: wahrscheinlich yes, falls die Alltagsminuten
   als neue Tagesreihe gespeichert werden (Rebuild-Schritt im nächsten Rezept).
3. **Rat am Morgen:** eine Kette für Effort-Ziel, Coach und Vorschlagsknöpfe, Angebote, Plan anpassen,
   Mitteilung, Sicherheitsregel beim Essen; die Kotlin-Kopie des Effort-Ziels entfällt. Analysis migration
   required: no.
4. **Messinstrumente im Labor:** Puls bei gleicher Schrittfrequenz, Pulserholung, mit Prüfregel. Analysis
   migration required: no (Labor, Standard aus).
5. **Später:** Puls bei gleichem Tempo aus GPS; der zweite Effort-Schritt übernimmt die Minutenregel. Analysis
   migration required: yes.

Abnahme vor dem Release (Q30): kein „unproduktiv“ wegen fehlendem Nachweis, kein Widerspruch zwischen Ring,
Rat und Coach, auf jeder Karte eine Aussage.

### 8.6 Offen zu prüfen

- Welche Zelle der Urteilstabelle auf den echten Daten greift (braucht die Rechnung der App auf der Kopie).
- Warum die Bewertungsmitteilung bei erkannten Gehrunden nicht kommt (Erkennungszeit gegen das Fenster).
- Ob 5 % in sechs Wochen die richtige Grenze für „Kraft gehalten“ ist (Studien zu Krafttraining im Defizit).
- Ob die WHO-Minuten aus dem Strap nahe an den Trainingsminuten der Apple Watch liegen (eine Woche nebeneinander).

### 8.7 Nicht tun

Keine gemeinsame Zahl für Kraft und Cardio. Gewicht nie als Nachweis. Kein Körperfett von Waagen. Keine
medizinischen Aussagen. NOOPs eigener VO₂max bleibt kein Nachweis. Nichts sperren, nichts mahnen. Ernährung
entscheidet den Rat nie, außer der einen Sicherheitsregel. Keine Kotlin-Zwillinge.
