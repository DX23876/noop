# Android: Kern vollständig, App angeglichen, eine Testversion

## Implementation and validation cadence (owner decision, 2026-10-27)

Implement large, coherent feature packages and keep routine progress local. Use focused checks for new logic
or a concrete failure during implementation. Do not run the complete Apple/Android acceptance matrix after
each commit. Bundle `Tools/local-tests.sh`, emulator rounds and the final data comparison at a substantial
milestone or the final acceptance stage; the committed-tree gate is still required before any approved push.
The owner has not authorized a push or release.

## Context

Bisher war geplant, nach einer ersten Android-Testversion anhand des Tester-Feedbacks zu entscheiden, welche
Fork-Funktionen nach Android kommen (D20). Der Besitzer hat am 2026-10-26 anders entschieden: Erst kommt alles,
was rechnet oder speichert, in den gemeinsamen Swift-Kern. Dann wird die Android-App so weit wie möglich an iOS
angeglichen, und danach geht **eine** Testversion raus, die schon dem fertigen Stand entspricht. So testen die
Tester mehr Funktionen und liefern mehr Fehlerberichte.

Anlass für den Kurswechsel war ein Echtdaten-Vergleich am 2026-10-26:

- **Tagesrhythmus:** Der Android-Rechenweg liefert auf der iPhone-Datenbank exakt dieselben Werte wie iOS
  (40 von 40).
- **AgeLess:** Android liegt 0,25 bis 0,35 Jahre daneben. Die Android-Datenanbindung des Kerns
  (`Packages/NoopCoreJNI/Sources/NoopCore/CoreAnalysis.swift`, `StoreServices`) liefert für korrigierte Nächte,
  ausgeblendete Schlaffenster und Workouts, den Workout-Abgleich, die Energie und die AgeLess-Langeinheiten nur
  Platzhalter.

Vor der Testversion muss das gleich rechnen (D2).

## Entscheidungen (2026-10-26)

- **Vorhandene Android-Bildschirme** aus ryanbrs Code werden **eingebettet**, wie bei den Einstellungen:
  `HostedPalette` plus `LocalHostedChrome` geben Forge-Farben, Glaskarten und durchlaufenden Hintergrund. Ein
  Neubau ist das nicht.
- **Umfang:** Training komplett, Gesundheit und Körper (AgeLess, Tagesrhythmus, Energie-Plan, Körper, Momentum,
  Ziele), die Coach-Erweiterungen, EKG und GPS-Höhe.
- **Semantisches Gedächtnis des Coaches** bleibt für die Testversion draußen. Es braucht llama.cpp, dessen
  Android-Build ungeprüft ist; der Coach läuft ohne Gedächtnis weiter.
- **Nur eine Testversion**, am Ende.
- **Nur auf Apple, bleibt weg:** Apple Watch, Siri und Shortcuts, iOS-Widgets, HealthKit-Live. Der Import einer
  Apple-Health-Exportdatei bleibt.

## Grundregel

Alles, was Zahlen berechnet oder Werte speichert, gehört in den Kern (`Packages/StrandCore`, Android-Anbindung
`Packages/NoopCoreJNI`). Pro Plattform bleiben Oberfläche, Bluetooth-Transport, Health Connect bzw. HealthKit,
Benachrichtigungen, Widgets, Kamera und Netzwerkaufrufe. Jede Verschiebung folgt dem B3-Muster:
`Repository` behält dünne Weiterleitungen, die iOS-Tests bleiben, `Analysis migration required: no`, solange
Werte identisch bleiben.

## Schritt 0: Offene Arbeit sichern

Im Arbeitsbaum liegen noch unfertige Änderungen. Sie werden mit Phase 1.1 zusammen committet:

- `CoreAnalysis.Settings` mit `healthspan` und `rhythmAge`
- `CoreAnalysis.Profile` mit Taille, Schrittkalibrierung und `maxHR`
- `android/.../core/CoreFeatures.kt`
- der JNI-Pfad dazu
- `Tests/NoopCoreTests/RealDataLabPassTests.swift`

## Phase 1: Kern rechnet auf beiden Plattformen gleich

### 1.1 Datenanbindung der Tagesanalyse auf Android vollständig

Jeder Platzhalter in `CoreAnalysis.StoreServices` wird durch die gemeinsame Implementierung ersetzt:

- **Korrigierte Nächte:** `Repository.restageFromRaw` und `selfHealEditedStages` werden zu
  `StrandCore/EditedSleepHeal.swift`. Sie nutzen `SleepStagerV2`, `SleepStager`, `WakeMotionRefinement`,
  `OuraRespScale`, `StreamReadCap` und `DailyAnalysis.midnightLocal`, die schon in Paketen liegen. Die Signatur
  des Stagers speichert der `AnalysisHost`.
- **Ausgeblendete Schlaffenster und Workouts:** Sie kommen in `CoreAnalysis.Settings` als `"start:end"`-Listen.
  Kotlin liest sie aus Room (`WhoopRepository.dismissedSleeps`, `dismissedDetected`). Geparst wird mit
  `DismissedSleepSpans.windows` und `WorkoutSource.parseDismissedSpans`.
- **Workout-Zeilen:** Die Kette aus `Repository.workoutRows` zieht in den Kern: Duplikate, eingetragene Herzfrequenzen und
  den HR-Abgleich (`dedupCrossSource`, `overlayWorkoutFills`, `reconcileWorkoutHrWithTrace`), aufgebaut auf
  `StoreReader.rawWorkoutRows`.
- **AgeLess-Langeinheiten:** `agelessLongSessions` kommt mit `trainingSessions`, `cardioLoads` und
  `workoutElevations` in den Kern; vorhanden sind schon `TrainingSessionFusion`, `CardioLoadPricing` und
  `TrainingVO2max`.
- **Energie:** Der restliche Teil von `EnergySeries` (`energyPeakMETByDay`, `refreshWhoopEnergyModel`,
  `ensureEnergyHistoryCurrent`, `correctLegacyWorkoutEnergy`) und die Formelwahl aus `EnergyPlanStore`.
- **Weitere Platzhalter:** `fillCardioLoadLedger`, `fillRecordedWorkoutHeartRate`, `enteredVO2max`.

Geprüft wird mit `RealDataLabPassTests`, erweitert zu `RealDataParityTests`. Der Test lässt den Android-Weg
über einen Klon der iPhone-Datenbank laufen (`~/NoopRealData/work/`). Er bekommt das Profil und die
ausgeblendeten Listen aus den iPhone-Einstellungen und vergleicht jede abgeleitete Tabelle mit dem, was iOS
gespeichert hat. Das Ergebnis muss **0 Abweichungen** sein. Dazu kommt der B4-Snapshot-Vergleich für iOS
(davor und danach identisch).

### 1.2 Funktionsdaten in den Kern

Jeweils Logik und Speicher, ohne Oberfläche:

- **Training:** `LiftSessionEngine`, `LiftSessionPersistence`, `ResolvedStrengthHistory`,
  `StrengthDraftBuilder`, `TrainingPerformanceHistory` und `TrainingPreferences`. Die Pakete `StrandTraining`
  und `MuscleMap` bauen schon für Android.
- **Ziele:** die Auswertung (`GoalCatalog`, `GoalActions` und die Trackingseite) samt `GoalBackupBundle`.
  Foundation progress (2026-10-27): the existing Swift models/stores, period tracker, catalog,
  safety/volume gates, motivation, measured-input helpers and pure progress engine are shared sources.
  The new SQLite preference-image transaction preserves the Apple property-list formats, restores scoped
  store bindings before awaiting persistence, rejects stale writers and leaves the previous image intact
  on failure. The synchronous `GoalTrackingModel` refresh is now shared too, while Apple retains its
  asynchronous Repository adapter and notification delivery. The backup bridge derives `goals.bundle`
  from the exact archived SQLite snapshot; Apple settings are applied to a disposable restore candidate
  before the live swap, including recovery of a legacy WAL. The arm64 native build passes; the focused
  backup/model block and the additional snapshot-isolation test pass. This is not the completed Goals feature:
  data-reader integration, operations, Android screens and bundled native/app/device acceptance remain open.
  Analysis migration required: no; extraction preserves the existing rules and user inputs.
- **Momentum:** `MomentumBuilder`, `MomentumResolver`, `MomentumStore`.
- **Sonstige Rechnungen:** `StressDayCurve`, `SkinTempBackfillWalker`, `WorkoutElevationSeries` und den Rest von
  `BodyMetricsSeries`.
- **EKG:** Dekodieren und Speichern der MG-Messung; der Bluetooth-Teil bleibt Kotlin.
- **Coach:** wird ein eigenes Paket `StrandCoach` aus `Strand/AI` (rund 23.000 Zeilen; nur 4 Dateien hängen an
  UI-Frameworks), ohne `CoachSemanticMemory`. Netzwerk und Streaming laufen über ein Host-Protokoll, und
  Kotlin übernimmt das HTTP, falls FoundationNetworking auf Android nicht trägt (gleich zu Beginn prüfen).
  Geprüft am 2026-10-28: HTTPS über FoundationNetworking trägt auf Android (der Hevy-Client des Kerns erreichte
  den Server und bekam das erwartete 401, `libFoundationNetworking.so` wird schon mitgeliefert). Es fehlt aber
  `URLSession.bytes(for:)` (AsyncBytes), mit dem `AIProvider`, `AnthropicStreaming`, `OpenAICompatibleStreaming`
  und `GeminiTools` die Antworten streamen; vorhanden sind nur Datentasks mit Delegate. Der Coach braucht deshalb
  für Android einen kleinen Adapter, der einen Delegate-Datentask als `AsyncThrowingStream` von Bytes liefert und
  hinter derselben Schnittstelle sitzt; der Rest des Netzwerkteils kann bleiben. Dieser Adapter liegt seit
  2026-10-28 in StrandCore (`URLSession.streamedBytes(for:)`, `StreamedBytes` mit Byte- und Zeilenlesen wie
  `AsyncBytes.lines`), getestet auf macOS gegen einen Stub und für Android kompiliert; die Provider nutzen ihn,
  sobald der Coach für Android gebaut wird.
  Bestandsaufnahme für den ersten Schritt (2026-10-28): `Strand/AI` hat 95 Dateien mit rund 27.000 Zeilen, 40
  davon sind schon im Kern verlinkt. An UI- oder Benachrichtigungs-Frameworks hängen `CoachCardArtifact`,
  `CoachChart`, `CoachIdentity`, `GoalEventNotifier`, `GoalMaintenance` und `PlanReminder`; sie bleiben App-seitig
  oder bekommen eine geteilte Logikhälfte wie `GoalEventPlan`. 21 Dateien lesen über das Apple-`Repository`
  (allen voran `AICoach.swift` mit 4.691 Zeilen), mit 35 verschiedenen Lesefunktionen. Die häufigsten sind
  `storeHandle` (10, direkter Store-Zugriff, einzeln aufzulösen), `workoutRows` (9), `journalEntries` (8), `series`
  (4), `resolvedStrengthHistory` und `exploreSeries` (je 3). Fast alle haben schon ein Gegenstück im Kern
  (`StoreReader`, `GoalInputReading`, `WeightSeries`, `BodyMetricsReader`, Energie- und Trainingsleser). Der erste
  Schritt ist deshalb ein `CoachDataReading`-Protokoll über genau diese Lesefunktionen, das `Repository` und ein
  Kern-Host erfüllen, wie `GoalInputReading` für die Ziele.
  Schritt 1 erledigt (2026-10-28): `Strand/AI/CoachDataReading.swift`; `AICoach.repo` ist jetzt
  `any CoachDataReading`. Zwei Host-Haken bleiben App-seitig (`refreshCoachCheckIn`, `trainingLoadBrief`), dazu
  `cardioLoadMaxHR` und `strainProfileSex` statt des Apple-Typs `Repository.StrainProfile`. Schritt 2
  erledigt (2026-10-28): der Plan-Abgleich (`PlanReconciliationCoordinator.reconcile`) liest über
  `CoachDataReading`, die Antwort auf verpasste Ziel-Fragen über `CoachDataReading & GoalInputReading`, und
  `GoalTrackingStore.refresh` nimmt jeden `GoalInputReading`-Host. Das Protokoll ist als Symlink im
  Kern verlinkt (`NoopCore/Shared`), die Apple-Umsetzung liegt getrennt in `CoachDataReading+Repository.swift`.
  Schritt 4 erledigt (2026-10-28): `NoopCore/CoreCoachData.swift` erfüllt `CoachDataReading` über `StoreReader`
  und liest gemeinsame Bahnen (Training, Tagebuch, Wasser, Kraft, Körper, Tage) über `CoreGoals.Host`, damit Coach
  und Ziele nicht auseinanderlaufen. Noch ohne Kern-Leser und deshalb leer: Energiezusammenfassungen, der
  Cardio-Spielraum, Stimmung, die Belastungsübersicht und alle Schreibwege. Als Nächstes der Umzug des Coaches
  selbst (`AICoach` ohne `StrandDesign` und ohne `SemanticMemory`) und die Brücke nach Kotlin.

Jede Verschiebung bekommt Kern-Tests auf macOS. Der Echtdaten-Vergleich läuft dort, wo Werte gespeichert
werden.

### 1.3 Android liest nur noch den Kern (E-4, zweite Hälfte)

Local progress (2026-10-27): journal and hydration raw inputs now cross a one-time, transactional
ownership boundary (GRDB v80). Android repository reads/writes and backup export use the core; restored
archives seal the lane against replay from the phone's old Room database. Store/schema, bridge/backup,
arm64 packaging and the installed Room-to-JNI integration check pass. Catalog/opt-in settings now reach
the core (habit and hydration goals, Today & Trends cards). Device delete/forget/re-key and the remaining input lanes
(workouts, health days, lab markers, live sessions, imported series/days/nights, sleep edits, day ownership)
are adopted once and mirrored on every write (2026-10-28). Moving the classic screens' reads to the core and
ending Room writes remain; the strap path among them waits for hardware evidence.
Analysis migration required: no for this ownership move; raw values are preserved.

- **Eingebettete Bildschirme:** Die Datenschicht jedes eingebetteten Klassik-Bildschirms, der abgeleitete
  Zahlen zeigt (Workouts, Stress, Gesundheit, Live-Verlauf, Laborbuch, Vergleich, Explore, Insights), liest
  über neue `CoreRead`-Funktionen (JSON über JNI, Muster `Bridge` → `JNIExports` → `SwiftCore.kt` →
  `CoreRead.kt`) statt aus Room.
- **Room-Schreiben endet:** Danach schreibt Kotlin kein Room mehr. Room bleibt nur für Android-eigene Dinge, die
  der Kern nicht kennt.
- **Bestätigter Verlauf:** Der Schalter „Gemeinsamer Kern bestätigt Verlauf“ wird zum Standard.

## Phase 2: Android-App angeglichen

- **2.1 Navigation wie iOS:** Fünf Tabs (Heute, Trends, Training, Schlaf, Mehr; `StrandiOS/App/RootTabView.swift`).
  Mehr bekommt den Index mit den Kategorien von `MoreDestination`, ohne die reinen Apple-Ziele.
- **2.2 Einbetten:** `Hosted` aus `ForgeSettings.kt` wird zu einem allgemeinen Forge-Rahmen für Mehr. Darin
  laufen Live, Workouts, Gesundheit, Laborbuch, Stress, Atmen, Intervalle, Rhythmus, Wecker, Automationen,
  Insights, Vergleich, Explore, Fused Record, Datenquellen, Backup, Testzentrum, Energiesparen und Coach. Jeder
  Bildschirm wird im Emulator angesehen; Abweichungen vom iOS-Look werden zentral behoben, im Hosted-Pfad von
  `ScreenScaffold`, `NoopCard` und `Palette`.
- **2.3 Neu nach iOS-Vorlage** (Compose in `com.noop.ui.forge`, Daten aus 1.2):
  - Training-Hub mit Krafttraining-Log und Sitzung, Plan, Muskelkarte, Übungsbibliothek, Trainingslast und
    Hevy-Import
  - AgeLess mit Erklärung und Zielverknüpfung
  - Rhythmus-Alter
  - Energie-Plan und Energie-Details
  - Körper: Gewicht und Fotos über die Android-Fotoauswahl, nur auf dem Gerät
  - Momentum
  - Ziele mit Verlauf
  - Coach: Ziele, Pläne, Verlauf
  - EKG-Messungen
  - GPS-Höhenprofil im Live-Training (Android-Standort)
- **2.4 Labor-Schalter wie iOS:** AgeLess, Tagesrhythmus und die übrigen Experimente, gleiche Schlüssel,
  standardmäßig aus.
- **2.5 Neun Sprachen** für alle neuen Texte; das i18n-Gate prüft das.

## Phase 3: Testversion

1. **Prüfen:** Echtdaten-Gleichheit auf 0 Abweichungen. Emulator-Rundgang durch alle Tabs und Mehr-Ziele auf
   fünf Profilen (`Tools/android-smoke.sh`, eigenes Skript für Mehr und Einstellungen). Alle Tests:
   `Tools/local-tests.sh`, Kotlin-Tests, Tools-Tests und CI grün.
2. **Dokumentieren:** `docs/fork/android/STATUS.md`, `PLAN.md` (D20 durch diese Entscheidung ersetzt),
   `TESTING.md` auf den neuen Umfang, Release-Notes.
3. **Release vorbereiten:** Version in `project.yml` und Android `versionName` gemeinsam anheben;
   `publish-ios-release.yml` hängt die signierte APK über `android-release.yml` an. **Ausgelöst wird erst nach
   ausdrücklicher Freigabe des Besitzers**, denn das ist eine Veröffentlichung.
4. **Nach dem Release:** F3 (bestehende Tester), danach Website-Hinweis und angepinntes Issue. Das
   Testing-Etikett bleibt bis zu den D9-Bestätigungen.

## Arbeitsweise (Vorgabe des Besitzers, 2026-10-26)

- **Große Pakete:** viel Code am Stück schreiben und erst bauen, wenn es unbedingt nötig ist, also am Ende eines
  ganzen Pakets oder wenn ein Schritt vom Ergebnis eines Builds abhängt. Kein Build nach jeder kleinen Änderung.
- **Große Commits:** ein Commit pro Paket. Zum Beispiel ist 1.1 komplett ein Commit, ebenso Training mit Kern
  und Oberfläche. Wenn es schneller geht, kommen auch mehrere Pakete in einen Commit.
- **Pushen:** Das Pre-Push-Hook verlangt `Tools/local-tests.sh` auf dem committeten Stand. Deshalb wird selten
  gepusht, dann aber gebündelt. Die CI läuft danach im Hintergrund.
- **Prüfungen gebündelt:** Echtdaten-Test, Emulator-Rundgang und Kotlin-Tests laufen je Paket einmal, nicht pro
  Datei.
- **Platz:** immer nur ein Android-Build gleichzeitig, weil auf der Platte nur etwa 12 GB frei sind.
- **Übergabe:** `STATUS.md` nach jedem Paket aktualisieren, damit eine andere Sitzung oder ein anderes Konto
  nahtlos weitermachen kann.

## Risiken

- FoundationNetworking auf Android (Coach): Ausweg ist HTTP in Kotlin über das Host-Protokoll.
- Medien der Übungsbibliothek: Lizenz und Offline-Größe prüfen, bevor sie in die APK kommen.
- Umfang: Das sind mehrere Wochen Arbeit. Zwischenstände werden gepusht, aber erst am Ende veröffentlicht.
