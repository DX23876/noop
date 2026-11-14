# Cardio-Kopfkarte — Übersetzungen einspielen

Die Kopfkarte der Cardio-Seite führte mit der internen Lastzahl ("at least 109 cardio points"). Die
Karte sagt jetzt in Worten, was die Seite sagen kann, und bringt **zwölf neue Katalog-Keys** mit.

Der Ablauf ist derselbe wie in [`plans-i18n.md`](plans-i18n.md): Katalog-Keys entstehen nur bei einem
Build aus **Xcode.app**, danach die deutschen Fassungen eintragen und
`python3 Tools/i18n_audit.py --ci origin/main` nach dem Beendigungscode beurteilen.

| Englisch | Deutsch |
|---|---|
| `Heart rate recorded in \(lane.measuredCount) of \(lane.possibleCount) sessions` | `Herzfrequenz in \(lane.measuredCount) von \(lane.possibleCount) Einheiten aufgezeichnet` |
| `Nothing to compare` | `Nichts zum Vergleichen` |
| `None of these sessions was recorded with heart rate, so how hard they were cannot be read.` | `Keine dieser Einheiten wurde mit Herzfrequenz aufgezeichnet. Wie hart sie waren, lässt sich deshalb nicht lesen.` |
| `A session without heart rate counts as nothing here, so this reads low.` | `Eine Einheit ohne Herzfrequenz zählt hier als nichts. Der Wert fällt deshalb zu niedrig aus.` |
| `Not enough weeks yet` | `Noch nicht genug Wochen` |
| `A week is only ever compared with your own earlier weeks. There are not yet enough of them.` | `Eine Woche wird immer nur mit deinen eigenen früheren Wochen verglichen. Davon gibt es noch nicht genug.` |
| `Too few sessions measured` | `Zu wenige Einheiten gemessen` |
| `Heart rate is missing from most of these sessions, so a comparison would read low.` | `Bei den meisten dieser Einheiten fehlt die Herzfrequenz. Ein Vergleich würde zu niedrig ausfallen.` |
| `easier than your usual week` | `leichter als deine übliche Woche` |
| `about as hard as your usual week` | `etwa so hart wie deine übliche Woche` |
| `harder than your usual week` | `härter als deine übliche Woche` |
| `much harder than your usual week` | `viel härter als deine übliche Woche` |

Nicht mehr verwendet (die Einträge dürfen im Katalog bleiben): `%lld of %lld sessions complete`,
`at least %@`, `No usable heart-rate trace in this window, so cardiovascular load is not estimated`,
`Only %lld of %lld sessions are complete; the measured total is a lower bound`. `%lld TRIMP` steht
weiter in der Trainingslast-Seite.
