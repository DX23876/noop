# NOOP AI · Feature-Spezifikation, Heute-Screen

Beschreibt **Verhalten und Daten**, nicht Aussehen. Für Optik siehe `design-spec.md`.

---

## 1. Aktivitätsstatus

Ein manueller, nutzergesetzter Tageszustand, unabhängig von den berechneten Scores.

### Zustände

| Zustand | Wirkung auf Empfehlungen |
|---|---|
| Aktiv | Normale Readiness-Logik, unverändert |
| Krank | Trainingsempfehlung unterdrückt; Basiskarte zeigt Ruhe-Hinweis |
| Verletzt | Trainingsempfehlung unterdrückt; Basiskarte zeigt entsprechenden Hinweis |
| Pause | Trainingsempfehlung unterdrückt; Basiskarte zeigt entsprechenden Hinweis |

„Unterdrückt" heißt: `propose_plan` und die Trainingsvorschlag-Karten werden für die Dauer des Status nicht ausgelöst.

### Datenmodell

```
ActivityStatus {
  state: .active | .sick | .injured | .onBreak
  validUntil: Date?          // nil = "bis geändert"
  setAt: Date
}
```

- Ein Datensatz pro Tag reicht nicht — der Status kann über Mitternacht gültig bleiben (`validUntil`), daher eigener Typ statt Feld am Tagesdatensatz.
- `validUntil` wird aus der Dauerauswahl berechnet: „Heute" → Ende des aktuellen Tages, „3 Tage" → +3 Tage, „Diese Woche" → Ende der laufenden Woche, „Eigenes Datum" → gewähltes Datum, „Bis geändert" → `nil`.
- Beim Erreichen von `validUntil` fällt der Status automatisch auf `.active` zurück. Kein Reminder, kein Nachfragen — stiller Reset.

### Auswirkung auf die Basiskarte

Die Basiskarte (siehe Feature 2) fragt beim Rendern den aktuellen `ActivityStatus` ab:

- `.active` → normale Readiness-Aussage aus der bestehenden Charge/Effort/Rest-Logik.
- `.sick` / `.injured` / `.onBreak` → statische, zustandsspezifische Aussage statt der berechneten Readiness-Aussage. Die drei Ringe selbst bleiben unverändert (zeigen weiter echte Werte) — nur die *Empfehlung* wird überschrieben.

---

## 2. Basiskarte (Readiness-Statement)

Ein einzelnes, **nicht wegwischbares** Element, das dauerhaft die aktuelle Tages-Einschätzung zeigt.

- Immer genau eine Basiskarte sichtbar, unabhängig vom Zustand der Notification-Karten (Feature 3).
- Inhalt kommt aus derselben Berechnung, die auch den Coach speist (`get_readiness`) — Basiskarte und Coach dürfen sich nie widersprechen, das ist eine bestehende Garantie aus dem Coach-System und gilt hier genauso.
- Bei nicht-aktivem Status (siehe Feature 1) wird der berechnete Text durch eine feste Aussage ersetzt.

---

## 3. Notification-Karten (Kartenstapel)

Ephemere, einzeln wegwischbare Hinweise, die über der Basiskarte liegen.

### Quellen

- Trainingsvorschläge (`propose_plan`)
- Auffälligkeiten in Vitalwerten (z. B. mehrtägige Abweichung vom Baseline)
- Weitere Quellen sind erwartbar — die Kartenmechanik muss generisch für „irgendein kurzer Hinweis mit Titel + Text" funktionieren, nicht hart an diese zwei Quellen gekoppelt sein.

### Verhalten

- Mehrere Karten stapeln sich, oberste zuerst. Anzahl wird über einen Punktindikator angezeigt.
- Wegwischen entfernt die Karte dauerhaft für diesen Tag; sie kehrt nicht zurück, außer die zugrunde liegende Bedingung besteht am Folgetag erneut (dann neue Karteninstanz).
- Keine Undo-Funktion nötig — das ist eine bewusste Vereinfachung.
- Kategorien einzeln in den Settings deaktivierbar (z. B. „Trainingsvorschläge" aus, „Auffälligkeiten" an). Nutzt den bereits vorhandenen Benachrichtigungs-Schalter, keinen neuen.
- Optional zusätzlich als native Push-Notification zustellbar — die Kategorie-Einstellung steuert beides gemeinsam; ist eine Kategorie aus, kommt auch kein Push.

---

## 4. Vitalwerte-Raster: Bearbeitungsmodus

### Reihenfolge

- Nutzerdefiniert, per Drag im Bearbeitungsmodus änderbar.
- Persistiert pro Nutzer (nicht pro Gerät, falls mehrere Geräte je einmal relevant werden — für jetzt reicht lokal).

### Sichtbarkeit

- Jede Metrik einzeln ein-/ausblendbar.
- Ausgeblendete Metriken werden nirgends im Raster gerendert (keine leeren Kacheln — bestehende Regel aus dem allgemeinen Redesign-Briefing gilt hier weiter).

### Rasterdichte

- Global zwei Optionen: 2 oder 3 Kacheln pro Reihe. Kein Vierer-Raster.
- Dichte ist eine Einstellung für das ganze Raster, nicht pro Kachel.

### Erweiterbarkeit (wichtig für die Datenmodellierung)

- Die Menge der verfügbaren Vitalwerte ist **größer** als die aktuell gezeigten sechs. Das Raster muss so gebaut sein, dass neue Metriken hinzukommen können, ohne die Bearbeitungslogik zu ändern — d. h. Kacheln werden aus einer Liste verfügbarer Metriken gerendert, nicht hartkodiert.
- Diese Erweiterbarkeit muss in beiden Rasterdichten (2 und 3) funktionieren.

```
VitalTileConfig {
  metricId: String
  visible: Bool
  sortOrder: Int
}
// separat, global:
gridDensity: Int   // 2 oder 3
```

---

## 5. Coach-Einstieg

- Kein eigener Tab, kein Floating Button.
- Einstieg 1: Avatar in der Kopfzeile (siehe Design-Spec) — immer erreichbar, unabhängig vom Kartenstapel-Zustand.
- Einstieg 2 (bereits bestehend im Coach-System, hier nur bestätigt): „Ask" an jedem Metrik-Detailscreen, vorbelegt mit der jeweiligen Metrik als Kontext.
- Benachrichtigungsindikator (Punkt am Avatar) erscheint nur bei tatsächlich neuer, proaktiver Nachricht — kein Dauerzustand.

---

## 6. Was NICHT Teil dieser Spec ist

- Die genaue Formel für Readiness-Aussagen (existiert bereits im Coach-System, `get_readiness`).
- Zeitpunkt/Häufigkeit von Notification-Auslösern (Produktentscheidung, nicht Layout).
- Das Synthesis-Ziel-System (Building/Maintain o. ä.) — wurde diskutiert, aber zugunsten des bestehenden Goal-&-Journey-Systems aus dem Coach nicht separat spezifiziert. Prüfen, ob `get_readiness` das bereits abdeckt, bevor etwas Neues gebaut wird.
