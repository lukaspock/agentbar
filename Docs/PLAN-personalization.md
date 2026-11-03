# Plan: Lebendiger Idle-Zustand, Bots und Personalisierung

Stand: 2026-11-03. Nur Planung, nichts davon ist gebaut. **Reihenfolge:** zuerst das Hand-Off (`Docs/PLAN-agent-user.md`, MVP Stufe 1), danach dieser Plan.

## 1. Idle-Zustand mit mehr Leben
Ausgangslage: `BlobView` (`App/Sources/UI/StatusCircle.swift`) zeigt im Idle halb geschlossene Augen in `BarTheme.idle` (40 % Weiß), Blinzeln alle 5,3 s. Auf dem Notch wirkt das wie ein grauer Punkt.

Vom User gewählt (2026-11-03): Ideen 1 bis 4.
1. **Atmen + Einschlafen:** Idle-Blob atmet langsam (Skalierung ca. ±4 %), Augen offen, gelegentliches Umschauen. Nach einigen Minuten Idle schläft er ein: Augen zu, kleines "z" steigt auf. Neue Aktivität weckt ihn mit einem kleinen Hüpfer.
2. **Agent-Farbe gedimmt:** Im Idle behält der Blob seine Agent-Farbe (ca. 55 % Sättigung/Helligkeit) statt Grau. Gilt auch für `done`.
3. **Mikro-Aktionen:** Zufällig alle ca. 20 bis 40 s: Gähnen, Strecken, kurz dem Mauszeiger folgen, Kopfwackeln. Zeitabstände pro Session leicht verschieden (aus der Session-ID abgeleitet, wie `BlobKind.forSession`).
4. **Nachglühen nach Done:** Weicher Ring in Agent-Farbe, klingt über ca. 10 s aus, danach Ruhezustand.

Nicht gewählt (bleiben Optionen): Zeit-Hinweis ("30m") und kollektive Mini-Blobs im eingeklappten Kreis.

Randbedingungen: `accessibilityReduceMotion` respektieren (statisch, ohne Atmen/Aktionen); TimelineView bei 30 fps nur wenn nötig, im Schlaf auf niedrige Rate; kein Dauerlauf, wenn die Bar nicht sichtbar ist; Zustandsübergänge laufen weiter über `BarTheme.spring`.

## 2. Namen, Farben, Theme
- Agent/Bot **umbenennen** (Kontextmenü oder Doppelklick), Name wird in Liste, Kopfzeile und Freigabe-Anzeige verwendet. Der Anzeigename stammt aus App-Wissen, nie aus Agent-Text (gleiche Vertrauensregel wie das "läuft als agentbar"-Chip im Agent-User-Plan).
- **Farbe pro Agent/Bot** wählbar; Standardfarbe pro Agent-Typ (Claude Code, Codex, GenericCLI, Computer Use).
- **Settings > Theme:** Farbpaletten (z. B. Pastell, Neon, Mono) und eigene Default-Farbe pro Agent-Typ. Hand-off-Prinzip bleibt: Das Hand-Off/Freigabe-Erlebnis steht im Vordergrund, Personalisierung ist Zusatz.
- Speicherung: Preferences-Datei im App-Support-Verzeichnis des Besitzers (nicht im Contract-Model; additives Feld nur über den Coordinator, Contract ist FROZEN).

## 3. Bots (eigene Agents wie bei Grogbot)
Idee des Users: Man wählt ein Verzeichnis, in dem gearbeitet werden soll, dann einen **Bot**, der dort arbeiten soll. Man kann eigene Bots erstellen; jeder Bot hat einen eigenen **Startprompt** oder nutzt einen eigenen **Skill**.

Vorschlag Datenmodell (`Bot`):
- `id`, `name`, `color`, `blobKind` (optional fest, sonst aus ID), `agentKind` (z. B. Claude Code), `systemPrompt`/Startprompt, `skill` (optional, Name oder Pfad), optionale Standardeinstellungen (Modell, erlaubte Tools, "Immer erlauben"-Regeln bleiben exakt und pro Bot getrennt).
- Persistenz: eine JSON-Datei pro Bot oder eine Liste; Import/Export später.

Vorschlag Ablauf (ersetzt/erweitert `NewChatFlow`):
1. "New session" > Verzeichnis wählen (lokal per `NSOpenPanel`, oder Workspace des Agent-Benutzers, siehe `PLAN-agent-user.md`).
2. Bot wählen (Liste mit Farbe/Blob) oder "Neuer Bot".
3. Session startet mit dem Startprompt/Skill des Bots; Name und Farbe des Bots erscheinen in der Bar.
4. Bot-Editor in den Settings: Name, Farbe, Startprompt, Skill, Agent-Typ.

Sicherheit: Startprompt ist Benutzereingabe, kein Agent-Output. Bot-Dateien dürfen vom Agent-Benutzer nicht beschreibbar sein. Freigabe-Rendering und Click-Guard bleiben unverändert.

## 4. Offene Fragen an den User
- Wie viele Bots erwartest du? (Entscheidet, ob eine Liste reicht oder Gruppen/Suche nötig sind.)
- Skill oder Startprompt: beides, oder zuerst nur Startprompt?
- Soll ein Bot fest an ein Verzeichnis gebunden sein können (z. B. "Reviewer für Projekt X")?
- Gilt eine Bot-Farbe auch im eingeklappten Sammel-Kreis?

## 5. Vorgeschlagene Pakete (disjunkte Dateien)
| P | Inhalt | Besitzt |
|---|--------|---------|
| B1 | Idle-Animationen (Atmen, Schlaf, Mikro-Aktionen, Nachglühen) | `StatusCircle.swift`, `Theme.swift` |
| B2 | Preferences-Store (Name, Farbe, Theme, Bots) + Tests | neue Dateien im Core oder App/Store |
| B3 | Settings-Fenster: Theme + Bot-Editor | neue Dateien App/Sources/UI/Settings |
| B4 | NewChatFlow mit Verzeichnis + Bot-Wahl | `ChatBackend.swift`, `DetailPanel.swift` (nach P6 des Agent-User-Plans abstimmen) |
| B5 | Integration, Screenshots, Abnahme durch den User | ein Agent |

Reihenfolge: B1 und B2 parallel, dann B3, dann B4, dann B5. Abnahme durch den User nach B1 (sichtbar am Notch) und nach B4.

## 6. Leerzustand: eigenes Maskottchen (Entscheidung 2026-11-03)
Ohne Agent zeigt die Bar kein generisches graues Blob mehr, sondern das **persönliche Maskottchen des Users**. Jeder User gestaltet es selbst (Settings > Mascot): Name, Körperform (die 5 BlobKinds), Farbe, Augenstil (rund/Pille/müde/fröhlich) und optionales Accessoire (keins, Mütze, Brille, Schleife, Antenne). Es lebt wie ein Idle-Blob (B1: Atmen, Blinzeln, Mikro-Aktionen, Schlaf nach Inaktivität), gehört aber keinem Agent. Startet ein Agent, macht das Maskottchen Platz (sanft ausblenden, Agent-Blob übernimmt); bleibt kein Agent mehr übrig, kommt es zurück. Hover am Notch ohne Agent: kleines Panel mit "New session".
Fertige/schlafende Agents bleiben sichtbar, **bis der User sie schließt** (Entscheidung: kein Auto-Ausblenden).
Paket B6: Preferences-Erweiterung (`MascotAppearance` im PreferencesStore) + Settings-Tab "Mascot" + Leerzustand in BarShell/StatusCircle. Danach B4.

## 7. B4 präzisiert: "New session" inline im Notch statt eigenem Fenster (User-Wunsch 2026-11-03)
Der heutige Dialog (`NewChatDialog.swift`, eigenes NSPanel) wird durch einen **Inline-Flow im Notch-Panel** ersetzt: Klick auf "New session" tauscht den Panel-Inhalt (kein neues Fenster, mit Zurück-Pfeil) gegen Schritte:
1. **Run as:** Ich / agentbar (wie bisher, agentbar ausgegraut ohne Host).
2. **Projekt/Workspace:** lokal Ordner wählen (NSOpenPanel bleibt als Systemdialog nötig) oder agentbar-Workspace aus Liste / "New workspace".
3. **Bot:** Liste der Bots (Farbe, Name, Agent-Typ) oder "No bot (plain Claude)"; Bot liefert Startprompt/Skill, Name und Farbe der Session.
4. **Start.** Weiter wie bisher in den Chat.
Platz: Panel wächst/animiert mit (BarTheme.spring); Tastatur: Enter = weiter, Esc = zurück. Der Click-Guard-Gedanke gilt weiter: keine versehentlichen Starts während Panel-Animation.
Außerdem in B4: Namen/Farben aus dem PreferencesStore in Bar-Zeilen, Chat-Header und Freigabekarten anzeigen (Anzeigename nur aus App-Wissen), Startprompt/Skill des Bots beim Start der Session verwenden.

## 8. Entscheidungen zu B4/B5 (User, 2026-11-03)
- **Skill:** Startprompt + Skill-Name: Ist am Bot ein Skill eingetragen (z. B. `review-code`), wird `/<skill>` vor den Startprompt gestellt.
- **Bot-Ordner:** Optionaler Standardordner/Workspace pro Bot (im Editor setzbar, im Inline-Flow vorausgewählt, änderbar). Erfordert additives Feld am `Bot` (Core, Preferences).
- **Sammel-Kreis:** Farbe des wichtigsten Agents; needsInput/error behalten ihre Warnfarbe.
- **Keine neuen Fenster** außer Settings (und dem macOS-Ordnerdialog): bestehende NSAlert/NSPanel-Dialoge (NewChatDialog, "Agent user…"-Alert, Bestätigungen) wandern ins Notch-Panel. Bei Unklarheit nachfragen statt raten.
- **B5:** Integration, Gesamttests (swift test, e2e, Build ohne Warnungen), Screenshots, Doku (CONTRACTS.md "Preferences as built", HANDOFF/ROADMAP), Abnahme durch den User.
Reihenfolge: B6 (läuft) -> B4 -> B5. Danach Farbe wärmer + Glow kräftiger (nach Notch-Eindruck des Users).
