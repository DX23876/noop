# Design-Engine: austauschbare Designs (Aktuell, Aura, NOOP, WHOOP-Stil)

Stand: 2026-09-26 · Status: **Plan, Entscheidungen offen (Q1–Q9), noch nichts umgesetzt** ·
Branch: `feature/design-engine`

Anlass: Der Fork [gdorgian/noop](https://github.com/gdorgian/noop) („Noop Aura“) zeigt ein deutlich ruhigeres
iPhone-Design. Statt es 1:1 zu übernehmen, bekommt die App eine Design-Engine: Ein Design ist ein
austauschbares Paket, und das aktuelle Design, Aura, ein eigenes NOOP-Design und ein Design im WHOOP-Stil sind
jeweils eines dieser Pakete. Umschalten geht in den Einstellungen, live.

---

## 1. Ziel

- Mehrere vollständige Designs nebeneinander, per Einstellung umschaltbar, ohne Neustart.
- Ein Design darf sich in **allem Sichtbaren** unterscheiden: Farben, Schrift, Bausteine, Anordnung der Screens,
  Tabs.
- Alle Designs zeigen **dieselben Zahlen unter denselben Namen**. Kein Design rechnet selbst.
- Ein neues Design muss nicht alles definieren. Was fehlt, fällt auf das Standard-Design zurück.
- Das aktuelle Design bleibt nach der Umstellung **unverändert** (Standard-Paket).

## 2. Ausgangslage (geprüfte Fakten)

| Fakt | Stelle | Folge |
|---|---|---|
| Farb-Tokens sind `static let`, die öffentlichen Namen sind eingefroren | `StrandPalette` (`Packages/StrandDesign/.../Palette.swift`), Chrome-Werte aus `NoopVisualStyle.ChromeHex` | Heute nicht zur Laufzeit austauschbar. Die Namen bleiben, nur die Quelle muss sich ändern |
| Laufzeit-Umschaltung gibt es schon zweimal | `StrandPalette.accentChoice` und `StrandPalette.chartStyle` sind `static var`, gesetzt an der App-Wurzel aus `@AppStorage`; die Wurzel wird auf den Rohwert geschlüsselt, damit alles live neu zeichnet (`StrandiOSApp.swift` `.chartStyle(…)`, `StrandApp.swift`) | Erprobtes Muster für „Design wechseln“, ohne Aufrufstellen anzufassen |
| Farbauflösung ist heiß | `Color(light:dark:)` wird pro Frame aufgelöst, Hex-Parsing pro Auflösung kostete ⅓–½ CPU-Kern (#2393) | Theme-Farben müssen einmal pro Design gebaut und gespeichert werden, nie pro Zugriff |
| Kontraste sind getestet | `ChromeContrastTests` liest `NoopVisualStyle.ChromeHex` | Jedes Design muss dieselben Kontrastprüfungen bestehen |
| Umfang der Aufrufstellen | Referenzen: `StrandPalette.` ≈ 5.400, `StrandFont.` ≈ 3.240, `NoopVisualStyle.` ≈ 360, `DomainTheme.` ≈ 350 | Umstellung nur über die Token-Quelle, nicht über die Aufrufstellen |
| Farbwelt pro Bereich existiert | `DomainTheme` (charge / effort / rest / stress): Primärfarbe, Verlauf, Glow | Entspricht Auras „eine Akzentfarbe pro Tab“; geht im Theme auf |
| Datenfarben sind schon ein eigenes Thema | `ChartStyle` (7 Stile: signature, titanium, classic, health, aurora, sunset, forest), `SleepChartStyle` | Bleibt eine eigene Achse, siehe Q1 |
| Today existiert schon **viermal** | `RootTabView.todayTabRoot`: `TodayView` (6.226 Zeilen), `LiquidTodayView` (3.685), `TrendsDashboardView`, `OverviewDashboardView`; dazu das stillgelegte Heute-Redesign `StrandiOS/Redesign/` | Jede Variante holt ihre Daten selbst. Sie sind schon auseinandergelaufen (Kommentar in `DomainTheme`: derselbe Wert hieß „Charge“ und „Recovery“) |
| Tab-Gerüst ist fest verdrahtet | `RootTabView.body`: native `TabView` mit 5 festen Tabs (Today, Trends, Training, Sleep, More), `CoachFloatingButton` darüber | Das Gerüst muss aus dem Design kommen können |
| Es gibt schon eine NOOP-Designvorlage | `docs/fork/redesign-briefing.md`, `docs/fork/design/design-spec.md` + Mockups | Grundlage für das Paket „NOOP“ |
| Aura-Quelle | gdorgian/noop, Basis ryanbr 11.7 (`45ee2fb76`); UI in `StrandiOS/NoopUI` (≈ 42.000 Zeilen), eigenes `NoopDesign.swift`, ≈ 750 feste Farbwerte, 4 Tabs + Plus, nur Englisch; öffentliches Handoff `docs/design/11.7` (HTML pro Screen, Maße); Lizenz PolyForm Noncommercial | Vorlage, kein Merge. Nennung von gdorgian als Quelle |
| macOS hat ein eigenes Gerüst | `Strand/App/RootView.swift` (Seitenleiste) | macOS nutzt vorerst nur Themes (Q9) |

## 3. Architektur

Ein Design ist ein Paket aus vier Teilen. Darunter liegt eine gemeinsame Basis, die kein Design verändern kann.

```
┌──────────────────────── DesignPack ────────────────────────┐
│ 1 Theme        Farben, Schrift, Geometrie, Bereichsakzente, │
│                Bewegung                                     │
│ 2 Stile        Hero, Karte, Kennzahl, Ring, Satz, Liste …   │
│ 3 Layouts      pro Screen optional (Today, Rest, Trends …)  │
│ 4 Gerüst       Tabs, Reihenfolge, Plus-Button, Coach-Knopf  │
└─────────────────────────────────────────────────────────────┘
                 ▲ liest nur
┌──────────────── Basis (für alle Designs gleich) ────────────┐
│ Screen-Modelle: aufbereitete Werte, Namen, Zustände          │
│ (leer / zu wenig Daten / ok), gebaut aus dem Repository      │
└─────────────────────────────────────────────────────────────┘
```

Skizze (Namen vorläufig):

```swift
public protocol DesignPack: Sendable {
    var id: DesignID { get }
    var theme: DesignTheme { get }              // einmal gebaut, gespeichert
    var styles: DesignStyles { get }            // Bausteinstile, Rückfall: Standard
    var shell: ShellSpec { get }                // Tabs + Extras
    func layout(for screen: ScreenID) -> ScreenLayout?   // nil → Standard-Layout
}
```

- **Theme:** Werte als Hex-Paare (hell/dunkel) wie `ChromeHex`, damit Tests sie lesen können. Beim
  Aktivieren eines Designs wird daraus einmal der Satz fertiger `Color`-Werte gebaut.
- **Stile:** nach dem Muster von `ButtonStyle`, über das Environment gesetzt. Ein Baustein
  (`MetricHero`, `InsightCard` …) kennt nur sein Modell und fragt seinen Stil, wie er zu zeichnen ist.
- **Layouts:** bekommen **nur** das Screen-Modell, nie das Repository. Damit kann kein Layout eigene Zahlen
  erfinden oder Namen abweichend vergeben.
- **Gerüst:** eine Liste von Zielen (`ScreenID`) mit Titel, Symbol und Reihenfolge, plus Schalter für
  Plus-Button und Coach-Knopf. Nicht als Tab gewählte Screens landen in „Mehr“.
- **Registry + Einstellung:** `design.pack` in `@AppStorage`; die App-Wurzel setzt das aktive Paket und
  schlüsselt ihre Ansicht darauf (wie `chartStyle`).

## 4. Bestehende Tokens mitnehmen, ohne 5.400 Stellen zu ändern

1. `NoopVisualStyle` und die Chrome-Tokens in `StrandPalette` werden von `static let` zu `static var`, die aus
   dem aktiven Theme lesen. Die Namen bleiben (eingefrorene API).
2. Das Theme hält fertige `Color`-Werte. Ein Zugriff ist ein Lesen aus einem gespeicherten Wert, kein
   Hex-Parsing (#2393).
3. Das Standard-Paket liefert **exakt die heutigen Werte**. Nachweis: `ChromeContrastTests` unverändert grün,
   Screenshots vorher/nachher identisch (macOS und iOS).
4. `ChromeContrastTests` läuft danach über **jedes** registrierte Paket.
5. `StrandFont` genauso: Rollen bleiben, Schriftfamilie/Gewicht/Laufweite kommen aus dem Theme. Dynamic Type
   bleibt Pflicht in jedem Design.

## 5. Rückfall-Regeln

| Fehlt im Design … | … dann |
|---|---|
| ein Theme-Wert | Wert des Standard-Themes |
| ein Bausteinstil | Standard-Stil, gezeichnet mit dem Theme des Designs |
| ein Layout für einen Screen | Standard-Layout, gezeichnet mit Theme und Stilen des Designs |
| ein Screen im Gerüst | erreichbar über „Mehr“ |

Folge: Ein neues Design kann mit **nur einem Theme** anfangen und wirkt sofort app-weit. Eigene Layouts kommen
nach und nach für die Screens, die dem Design wichtig sind.

## 6. Die ersten Designs

| Paket | Inhalt | Quelle |
|---|---|---|
| `standard` | heutiges Theme, heutige 5 Tabs, heutige Screens | Bestand; muss pixelgleich bleiben |
| `aura` | dunkles Theme, ein Akzent pro Bereich, 4 Tabs + Plus; eigene Layouts zuerst für Today und Rest (ein Hero, ein Satz, dann Details) | Handoff `docs/design/11.7` von gdorgian/noop als Maßvorlage; einzelne Zeichnungen (Ring, Orb) dürfen mit Quellenangabe übernommen werden |
| `noop` | Regeln aus `redesign-briefing.md` („Ein Wert, ein Ort“, „Keine leeren Kacheln“, „Farbe kodiert Familie“, „Größe kodiert Wichtigkeit“) | `docs/fork/redesign-briefing.md`, `docs/fork/design/` |
| `whoop-stil` | dunkel, Score-Ringe oben, Zahlen zuerst, knappe Sprache | eigene Gestaltung, siehe Grenzen unten |

**Grenzen für den WHOOP-Stil** (CLAUDE.md, clean-room): keine WHOOP-Logos, -Grafiken, -Icons oder -Schriften,
keine aus der WHOOP-App kopierten Texte oder Screens. „Im Stil von“, kein Nachbau.

**Grenzen für Aura:** nur das Design. Auras eigene Funktionen (Svea, Body-Age-Berechnung, Lift, Ziele,
Beispielperson) werden nicht übernommen; die Plätze werden mit den vorhandenen Daten und dem vorhandenen Coach
gefüllt.

## 7. Schritte

Jeder Schritt ist für sich lieferbar und ändert für Nutzer des Standard-Designs nichts Sichtbares, bis ein
anderes Design gewählt wird.

| # | Schritt | Nachweis |
|---|---|---|
| P1 | `DesignPack`, Registry, Einstellung (versteckt), Standard-Paket; Tokens lesen aus dem aktiven Theme | macOS- und iOS-Build, `swift test` StrandDesign, `ChromeContrastTests`, Screenshots vorher/nachher identisch |
| P2 | Screen-Modell **Today** (Hero, Kernsatz, Kennzahlen, Zustände) + Tests ohne App | `swift test` im Paket des Modells |
| P3 | Gerüst aus dem Paket: `RootTabView` baut Tabs aus `ShellSpec`; Standard-Gerüst = heutige 5 Tabs | iOS-Build, Tabs/Wischgeste/Coach-Knopf unverändert |
| P4 | Paket `aura`: Theme, Gerüst (4 Tabs + Plus), Today-Layout auf dem Modell aus P2; Einstellung sichtbar | Build; Gerät: echte Daten, leere Zustände, Dynamic Type, hell/dunkel |
| P5 | Screen-Modell + Aura-Layout **Rest** | wie P4 |
| P6 | Paket `noop` und `whoop-stil`, zunächst nur Theme + Today | wie P4 |
| P7+ | weitere Screens nach Bedarf; die vier heutigen Today-Varianten auf das Modell umstellen (Q3) | pro Screen |

**Analysis migration required: nein.** Reine Darstellung: keine Formel, kein Fenster, kein gespeicherter Wert
ändert sich. `currentAnalysisRecipeVersion` bleibt.

## 8. Nicht-Ziele

- Keine Layout-Beschreibung per JSON oder eigener Sprache. Designs sind Swift-Code.
- Nichts aus dem Netz laden, keine Design-Downloads.
- Android: nicht betroffen (Apple-only-Fork).
- Keine neuen Kennzahlen. Wenn ein Design einen Wert braucht, den es nicht gibt, ist das ein eigenes Feature.

## 9. Risiken

- **Leistung:** falsch gebaute Token-Quelle bringt #2393 zurück. Gegenmittel: fertige `Color`-Werte pro
  Theme, Messung im Instruments-Profil vor/nach P1.
- **Wurzel-Neuaufbau beim Wechsel:** Navigationspfade und Scrollpositionen gehen verloren. Beim Design-Wechsel
  akzeptabel (seltene Aktion).
- **Übersetzungen:** neue Texte nur über einen Xcode.app-Build in den Katalog; `Localizable.xcstrings`-Churn vor
  dem Commit zurücksetzen.
- **Doppelte Wege:** solange die alten Today-Varianten selbst Daten holen, können sie vom Modell abweichen.
  Deshalb P7.

## 10. Offene Entscheidungen

| # | Frage | Empfehlung |
|---|---|---|
| Q1 | Bestimmt ein Design auch Datenfarben (`ChartStyle`) und Akzent? | Design bringt Vorgaben mit; `ChartStyle` und Akzent bleiben als Nutzer-Übersteuerung mit Option „wie Design“ |
| Q2 | Wo leben Screen-Modelle? | Modelltypen und Bau-Funktionen in einem Paket (testbar mit `swift test`), Eingabe als einfache Werte; die Anbindung ans Repository im App-Target |
| Q3 | Was wird aus den vier Today-Varianten (Classic, Liquid, Trends, Overview)? | Vorerst Layouts im Standard-Paket, unverändert; später entscheiden, welche bleiben |
| Q4 | Aura-Code portieren oder nach Handoff neu bauen? | Nach Handoff neu bauen, auf Tokens; einzelne Zeichnungen mit Quellenangabe übernehmen, keine festen Farbwerte |
| Q5 | Was steht im Aura-Hero auf Today? | Das, wofür man die App öffnet (Charge bzw. letzte Nacht); Atem-Übung als optionaler Einstieg |
| Q6 | Namen im WHOOP-Stil | NOOP-Namen (Charge / Effort / Rest) bleiben, auch dort |
| Q7 | Sprache | Alle Designs übersetzt wie heute; Aura wird nicht auf Englisch festgelegt |
| Q8 | Wo wird die Wahl gespeichert? | Gerätelokal, nicht im `.noopbak`-Whitelist (wie `SleepChartStyle`) |
| Q9 | macOS | Vorerst nur Themes; Seitenleiste und Layouts bleiben |
