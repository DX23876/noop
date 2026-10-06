# Apple-Health-Synchronisation — Umsetzung vom 6. Oktober 2026

Analysis migration required: **yes**, Rezept **AI-19**. Android-Parität entfällt im Apple-only-Fork.

Health → NOOP speichert vollständige Tagesfenster gemeinsam in einer SQLite-Transaktion.
Historische Körperwerte ändern außerhalb dieses Fensters ausschließlich ihre eigenen Spalten und
Serien. Fehlgeschlagene Schlaf-, Tageswert- oder Workout-Abfragen bestätigen weder einen leeren
Datenbestand noch den Health-Anchor. Eine fehlgeschlagene Workout-Herzfrequenzabfrage ersetzt
keine vorhandene Kurve.

Schlaf wird zunächst pro Quelle in Nächte aufgeteilt. Watch-Daten haben Vorrang, anschließend
detaillierte Stadien und eine stabile Quellenkennung. Überlappende Minuten zählen einmal; die Nacht
gehört zu ihrem Aufwachdatum. Ein ganztägiger Block einer anderen Quelle verbindet Nachtschlaf und
Mittagsschlaf nicht. In-Bed-Zeit zählt nicht als Schlaf.

Health-Workout-Löschungen werden anhand der UUID und Herkunft verarbeitet. Ein anderer Health-UUID
am selben bisherigen natürlichen Schlüssel schützt dessen Workout-Zeile. Manuelle Zeilen und
Nutzerentscheidungen bleiben erhalten. Der betroffene Importbereich wird vor der Metadatenlöschung
dauerhaft vorgemerkt und nach erfolgreichen, begrenzten Wiederholungsabfragen bestätigt.

NOOP → Health verwendet stabile Sync-IDs und persistente Versionen für Messwerte, Schlafsegmente,
Workouts und deren Energie-, Distanz- und Routendaten. Unveränderte Nutzdaten werden übersprungen.
Eine Ersatzspeicherung geht der Bereinigung beobachteter Legacy-Objekte voraus. Löschfehler werden
sichtbar und können wiederholt werden. Die Workout-Identität enthält Startzeit und Sportart; manuelle
Korrekturen und native Sessions haben Vorrang vor erkannten oder importierten WHOOP-Kopien.

SQLite hält die betroffenen Intervalle von Workout-, Schlaf-, Vitalwert- und Körpermessungsänderungen
sowie verspäteten HR-Offloads fest. Die Bestätigung gilt nur für die verarbeitete Revision. Änderungen
während eines laufenden Exports bleiben dadurch offen. Historische Intervalle werden zusätzlich zum
aktuellen Fenster gezielt verarbeitet. Profilgewicht-Schreibaufträge überstehen einen Neustart.
Taillenexport setzt weiterhin den bestehenden Opt-in und die Health-Schreibfreigabe voraus.

Workout-Export liest das aktive und alle behaltenen WHOOP-Geräte sowie sämtliche nativen Seiten.
Apple-Watch-Aufzeichnungen nativer Sessions werden nicht nochmals exportiert. Originale Pausen,
Runden und Phasen bleiben erhalten; HR-Buckets, die eine Pause überlappen, werden nicht angehängt.
Historische Zusammenfassungen ohne Zeitachse können keine exakten Pausenzeiten liefern.

AI-19 repariert fehlende historische Apple-Tagesprojektionen aus erhaltenen metricSeries-Werten in
fortsetzbaren Transaktionen. Der Analyse-Cursor wird erst nach Reparatur und Refresh geschrieben.
Ein separater Health-Import-Cursor aktualisiert die behaltene Historie in 31-Tage-Fenstern.
Berechtigungsanforderungen und nicht datierbare Health-Löschungen können diesen Lauf zurücksetzen;
eine Generation schützt den Reset vor einem noch laufenden älteren Checkpoint. Rohdaten und
manuelle Schlaf-/Workout-Korrekturen werden nicht gelöscht.

Reine Leseintegration wird nach einem Neustart anhand der erfolgreich angeforderten Berechtigungen
fortgesetzt. Das behauptet keine überprüfbare Lesefreigabe: HealthKit legt diese nicht offen.
Der Hintergrund-Exportscheduler prüft tatsächliche Schreibrechte separat.

Die automatisierte Prüfung umfasst Regressionen für Rollback, Historienerhalt, UUID-Löschung,
Quellenwahl, Wiederanlauf, Revisionen, Geräteregister, mehr als 500 Workouts und die Analyse-Migration.
iOS- und macOS-Builds sowie Paket- und App-Tests ergänzen diese Prüfung. Freigaben, Hintergrundzustellung,
Fitness-Darstellung und Workout-/Route-Zuordnungen benötigen weiterhin einen Test auf einem iPhone.
