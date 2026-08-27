# Technische Spezifikation: Floating Claude Chatbot für macOS

**Ziel dieses Dokuments:** Vollständige technische Grundlage, damit eine KI (z. B. Claude Code) diese App eigenständig implementieren kann, ohne Rückfragen zu grundlegenden Architekturentscheidungen stellen zu müssen. Offene Punkte sind explizit am Ende markiert.

---

## 1. Projektüberblick

Native macOS-Desktop-App (Swift/SwiftUI + AppKit), die als **floating, per globalem Shortcut aufrufbares Chat-Fenster** funktioniert und **Claude Code im Headless-Modus** (`claude -p`) als Backend nutzt – authentifiziert über das bestehende Claude-Abo des Nutzers, nicht über API-Billing.

### Kernfunktionen
1. Floating Chat-Fenster, per globalem Shortcut ein-/ausblendbar
2. Screenshot (Vollbild oder Bereichsauswahl) per Shortcut aufnehmen und an die KI schicken
3. Inhalt der aktuell offenen Website extrahieren und an die KI schicken
4. Antworten von Claude Code (Text, Markdown, ggf. Code) im Chat-Fenster anzeigen

### Nicht-funktionale Anforderungen
- Möglichst kleiner Binary-/Installationsgröße
- Möglichst geringer RAM-Verbrauch **im Ruhezustand** (die App läuft dauerhaft im Hintergrund/Menüleiste)
- Kein Dock-Icon, kein unnötiger Chrome – reine Utility-App
- Kein eigenes API-Billing – Nutzung ausschließlich über das lokal eingeloggte Claude-Code-CLI-Abo

> **Wichtiger Hinweis zur Erwartungshaltung:** Das Ruhezustand-RAM der App selbst kann sehr niedrig sein (Swift/AppKit, keine Electron-Basis). Während ein Chat-Request aktiv läuft, startet aber zwangsläufig ein separater Node.js-Prozess (`claude` CLI) mit typischerweise 100–250 MB RAM für die Dauer des Requests. Das ist der Preis der Architekturentscheidung „Abo statt API" und sollte nicht als Fehler missverstanden werden.

---

## 2. Architektur-Überblick

```
┌─────────────────────────────────────────────────────────┐
│  macOS Menu Bar App (LSUIElement, kein Dock-Icon)        │
│                                                           │
│  ┌───────────────┐   ┌────────────────┐  ┌────────────┐ │
│  │ Global Hotkey  │   │ Floating       │  │ Settings   │ │
│  │ Manager        │──▶│ NSPanel + UI   │  │ Window     │ │
│  └───────────────┘   └───────┬────────┘  └────────────┘ │
│                               │                          │
│         ┌─────────────────────┼─────────────────────┐    │
│         ▼                     ▼                     ▼    │
│  ┌─────────────┐     ┌────────────────┐   ┌──────────────┐│
│  │ Screen /     │     │ Claude Code     │   │ Website-     ││
│  │ Region       │     │ Process Manager │   │ Content-     ││
│  │ Capture      │     │ (Process API)   │   │ Extractor    ││
│  │ (ScreenCap-  │     │                 │   │ (AppleScript ││
│  │ tureKit)     │     │                 │   │ o. WebExt.)  ││
│  └─────────────┘     └────────┬────────┘   └──────────────┘│
│                                │                            │
│                                ▼                            │
│                      subprocess: `claude -p ...`             │
│                      (nutzt bestehende `claude login`-        │
│                       Session des Nutzers)                    │
└─────────────────────────────────────────────────────────┘
```

---

## 3. Kernkomponenten im Detail

### 3.1 Floating Window

- Implementierung: `NSPanel`-Subklasse (nicht normales `NSWindow`), damit das Fenster nicht den Fokus/Aktivierungszustand anderer Apps stiehlt.
- `styleMask`: `[.nonactivatingPanel, .titled, .closable, .resizable, .fullSizeContentView]`
- `level`: `.floating` (Standard) — optional `.statusBar`, falls das Fenster auch über Vollbild-Apps sichtbar sein soll
- `collectionBehavior`: `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]` — damit das Fenster auf jedem virtuellen Desktop verfügbar ist
- `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`
- Optik: `NSVisualEffectView` als Hintergrund (Material `.hudWindow` oder `.sidebar`), abgerundete Ecken, dezenter Schatten
- Größe: Standard z. B. 420×600pt, resizable, Position/Größe wird via `setFrameAutosaveName` persistiert
- Ein-/Ausblenden: Fade-Animation über `NSAnimationContext`, kein hartes Show/Hide
- Fenster schließt NICHT die App — nur `orderOut`, App läuft im Hintergrund weiter

### 3.2 Globaler Shortcut-Manager

- **Empfehlung:** Nicht Carbon `RegisterEventHotKey` von Hand implementieren, sondern das etablierte, sehr kleine SPM-Package **`HotKey`** (soffes/HotKey) verwenden — kapselt Carbon intern, minimaler Footprint, aktiv genutzt in vielen Utility-Apps.
- Benötigt **keine** Accessibility-Berechtigung für einfache globale Tastenkombinationen.
- Standard-Shortcuts (alle in Settings frei konfigurierbar, gespeichert als `KeyCombo` in `UserDefaults`):

| Aktion | Standard-Shortcut |
|---|---|
| Chat-Fenster ein-/ausblenden | ⌥⌘Space |
| Vollbildschirm aufnehmen & senden | ⌥⇧S |
| Bereich aufnehmen & senden | ⌥⇧D |
| Aktuelle Website extrahieren & senden | ⌥⇧W |
| Neue Konversation | ⌥⇧N |

### 3.3 Claude Code Headless Integration (Kernstück)

**Voraussetzung (App prüft dies, implementiert es aber nicht selbst):**
Der Nutzer muss die Claude Code CLI installiert und einmalig via `claude login` mit seinem Abo authentifiziert haben. Die App erkennt fehlende Auth durch einen Testaufruf und zeigt dann eine Onboarding-Anleitung an ("Bitte führe im Terminal `claude login` aus").

**CLI-Pfad-Auflösung:**
- Nicht hardcoden (`/usr/local/bin/claude` ist nicht garantiert, besonders bei nvm/Homebrew-Installationen).
- Beim ersten Start: `Process` mit `/bin/zsh -l -c "which claude"` ausführen (Login-Shell, damit PATH inkl. nvm/Homebrew geladen wird), Pfad in `UserDefaults` cachen.
- In Settings: manueller Override-Pfad möglich, falls Auto-Erkennung fehlschlägt.

**Befehlsmuster pro Chat-Nachricht:**
```bash
claude -p "<Prompt-Text>" \
  --output-format stream-json \
  --verbose \
  --include-partial-messages \
  [--resume <session_id>] \
  --allowedTools "Read" \
  --permission-mode acceptEdits \
  [--model sonnet|opus|haiku]
```

- **Streaming (empfohlen für UX):** `--output-format stream-json` liefert newline-delimited JSON-Events, die inkrementell geparst werden und die letzte Chat-Bubble live aktualisieren (analog ChatGPT-Streaming-Effekt).
- **Einfacher/robusterer Fallback:** `--output-format json` (blockierend), Antwort kommt als ein JSON-Objekt mit Feldern u. a. `result`, `session_id`, `total_cost_usd`, `duration_ms`.

**Session-Verwaltung (zwingend nötig, sonst kein Chat-Gedächtnis):**
- `claude -p` ist pro Aufruf zustandslos aus Sicht des aufrufenden Prozesses.
- Erste Nachricht einer Konversation: **ohne** `--resume`. Aus der JSON-Antwort wird `session_id` extrahiert und lokal der Konversation zugeordnet.
- Jede Folgenachricht: **mit** `--resume <session_id>`.
- „Neue Konversation"-Aktion: löscht die zugeordnete `session_id`, nächste Nachricht startet wieder ohne `--resume`.
- Datenmodell (siehe 3.7) speichert: `conversationId (UUID, lokal)` ↔ `claudeSessionId (String, von der CLI)`.

**Prozess-Management:**
- Jeder Aufruf läuft asynchron über `Process` + `Pipe` (stdout/stderr), niemals blockierend auf dem Main-Thread.
- Timeout: Prozess nach z. B. 120s automatisch terminieren (`process.terminate()`), Fehler im UI anzeigen.
- Abbruch durch Nutzer: „Stop"-Button im UI ruft `process.terminate()` auf dem laufenden Prozess auf.
- Pro Konversation nur ein aktiver Prozess gleichzeitig (Race Conditions bei `session_id` vermeiden). Mehrere parallele Konversationen mit je eigenem Prozess sind möglich, aber optional/später.

**Fehlerbehandlung:**
- Exit-Code ≠ 0 oder `is_error: true` im JSON → Fehlermeldung im Chat als Systemnachricht anzeigen, inkl. stderr-Auszug.
- CLI nicht gefunden → Onboarding-Hinweis.
- Nicht eingeloggt → Onboarding-Hinweis mit Link/Anleitung zu `claude login`.

### 3.4 Screenshot-Aufnahme (Vollbild & Bereich)

- **API:** `ScreenCaptureKit` (nicht das veraltete `CGWindowListCreateImage`) — effizienter, von Apple für neue Capture-Apps vorgesehen.
- **Vollbild:** `SCScreenshotManager.captureImage(contentFilter:configuration:)` — Einzelaufnahme, kein dauerhafter Capture-Stream nötig → minimaler RAM/CPU-Overhead im Vergleich zu `SCStream`. Nutzbar, da Minimum-Target macOS 14+ ist (siehe Entscheidung unten).
- **Bereichsauswahl:** eigenes transparentes, randloses Overlay-Fenster über allen Displays, Nutzer zieht ein Rechteck auf (analog zu ⌘⇧4), anschließend wird das Vollbild-Ergebnis von `SCScreenshotManager` auf den gewählten Bereich zugeschnitten (`CGImage.cropping(to:)`).
- **Berechtigung:** Screen-Recording-TCC-Berechtigung. Prüfen via `CGPreflightScreenCaptureAccess()`, anfordern via `CGRequestScreenCaptureAccess()`. Falls verweigert: Anleitung zu Systemeinstellungen → Datenschutz & Sicherheit → Bildschirmaufnahme anzeigen. **Wichtig:** macOS verlangt nach Erteilen der Berechtigung einen Neustart der App.
- **Speicherung:** Screenshot als PNG in `~/Library/Caches/<BundleID>/screenshots/`, Dateiname mit Timestamp/UUID.
- **Aufräumen:** Beim App-Start alle Screenshot-Dateien älter als 24h löschen.
- **Übergabe an Claude Code:** Dateipfad wird in den Prompt eingebettet, z. B.:
  ```
  claude -p "Analysiere diesen Screenshot: /Users/.../screenshots/abc.png" --allowedTools "Read"
  ```
  ⚠️ **Zu verifizieren (siehe Abschnitt 6):** Die exakte Syntax, wie Claude Code CLI im Headless-Modus Bildpfade in einem Prompt erkennt und über sein `Read`-Tool einliest, ist nicht mit letzter Sicherheit dokumentiert und sollte von der bauenden KI zu Beginn empirisch getestet werden (einfacher Testaufruf mit einem Testbild).

### 3.5 Website-Content-Extraktion

Zwei mögliche Routen mit sehr unterschiedlichem Aufwand — **Browser-Priorität muss vor Implementierung geklärt werden** (siehe Abschnitt 6):

**Route A — AppleScript (nur Safari & Chromium-Browser: Chrome, Edge, Brave, Arc etc.)**
- Deutlich einfacher, kein Extension-Code nötig.
- Beispiel Safari:
  ```applescript
  tell application "Safari"
    set theURL to URL of front document
    set theText to do JavaScript "document.body.innerText" in front document
  end tell
  ```
- Ausführung aus Swift via `NSAppleScript` oder `osascript` als Subprozess.
- Erste Ausführung löst automatisch eine macOS-Automation-Berechtigungsanfrage aus ("App möchte Safari steuern").
- Bei Chrome analog über `tell application "Google Chrome" ... execute front window's active tab javascript "..."`.

**Route B — WebExtension + Native Messaging (nötig für Firefox-basierte Browser: Firefox, Zen)**
Firefox-basierte Browser unterstützen keine AppleScript-Steuerung. Notwendige Komponenten:
1. **WebExtension** (Manifest V2/V3): Content-Script extrahiert `document.title`, `document.URL` und bereinigten Lesetext (einfache Heuristik oder Readability.js-Port, um Nav/Footer/Werbung zu entfernen).
2. **Background-Script** der Extension lauscht auf eingehende Native-Messaging-Nachrichten und fordert den Content-Script-Extrakt vom aktiven Tab an.
3. **Native Messaging Host**: kleines Helper-Executable, registriert per Manifest-JSON in `~/Library/Application Support/Mozilla/NativeMessagingHosts/`. Kommuniziert mit der Extension über das von Firefox vorgeschriebene längenpräfixierte JSON-Protokoll auf stdin/stdout, leitet Anfragen/Antworten an die Haupt-App weiter (z. B. über einen lokalen Unix-Domain-Socket).
4. **Ablauf bei Shortcut-Druck:** Haupt-App → Socket-Request an Native-Messaging-Host → Host → Extension-Background-Script → Content-Script im aktiven Tab → extrahierter Text zurück durch dieselbe Kette → Haupt-App baut daraus den Claude-Code-Prompt.
5. Deutlich mehr Implementierungsaufwand als Route A (eigenes Extension-Signing/Verteilung, Host-Installation, Protokoll-Handling).

**Entscheidung:** Route B (Firefox/Zen, WebExtension + Native Messaging) ist Priorität und wird direkt umgesetzt — Route A (Safari/Chrome) ist nicht Teil des Scopes, es sei denn, sie wird später explizit nachgefordert.

### 3.6 Chat-UI

- SwiftUI-View innerhalb des `NSPanel` (per `NSHostingView` eingebettet).
- Markdown-Rendering: natives `AttributedString(markdown:)` (kein externes Markdown-Package nötig → hält die App klein).
- Nachrichtenliste: `LazyVStack` in `ScrollView` + `ScrollViewReader` für Auto-Scroll.
- Streaming: letzte Assistant-Bubble wird bei `stream-json`-Events live nachgeführt.
- Eingabefeld: mehrzeilig, ⌘⏎ oder ⏎ zum Senden (konfigurierbar), Screenshot-Thumbnail-Vorschau vor dem Absenden falls ein Bild angehängt ist.
- Code-Blöcke: eigene Darstellung mit Copy-Button und Monospace-Font.
- **Konversations-Liste (wegen Mehrfach-Konversationen, siehe 3.7):** kompakte Sidebar oder ausklappbares Popover mit Titel + Zeitstempel je Konversation, „+"-Button für neue Konversation, Swipe/Rechtsklick zum Löschen/Umbenennen. Aktiver Lade-Zustand (Spinner) pro Eintrag, falls dort gerade ein `claude`-Prozess läuft.

### 3.7 Konversations- & Session-Speicherung

- Bewusst **keine** Core Data/SwiftData-Runtime, um Overhead/Größe klein zu halten — stattdessen einfache JSON-Dateien in `~/Library/Application Support/<BundleID>/conversations/`, eine Datei pro Konversation (z. B. `<conversationId>.json`).
- Datenmodell pro Konversation:
  ```json
  {
    "id": "uuid",
    "title": "Auto oder vom Nutzer umbenannt",
    "createdAt": "ISO8601",
    "claudeSessionId": "string oder null",
    "messages": [
      { "role": "user|assistant|system", "content": "...", "timestamp": "...", "attachmentPath": "optional" }
    ]
  }
  ```
- **Entscheidung: Mehrere parallele Konversationen von Anfang an (v1).** Das bedeutet zusätzlich:
  - Eine Sidebar oder ein Dropdown/Popover zur Konversations-Übersicht und -Umschaltung im UI (3.6).
  - Ein Index-File (z. B. `conversations/index.json`) mit Liste aller Konversations-IDs, Titeln und `updatedAt` für schnelles Laden der Übersicht, ohne alle Konversationsdateien einzeln parsen zu müssen.
  - Pro Konversation ein eigener, unabhängiger `claude`-Prozess möglich — die Prozess-Queue in 3.3 gilt weiterhin nur **pro Konversation** (max. ein aktiver Request je Konversation gleichzeitig), nicht global für die App.
  - UI muss klar anzeigen, welche Konversation gerade einen laufenden Request hat (z. B. Spinner neben dem Konversationstitel in der Liste), da mehrere gleichzeitig „tippen" können.

### 3.8 Einstellungen

- Shortcut-Anpassung (Recorder-UI, z. B. über das `HotKey`-Package oder eine eigene minimalistische Umsetzung)
- Claude-CLI-Pfad-Override
- Modellwahl (`--model sonnet|opus|haiku`)
- Streaming an/aus
- „Beim Login starten" via `SMAppService` (macOS 13+)
- Menüleisten-Icon als primäre Präsenz (`NSStatusItem`); App läuft als Accessory-App (`LSUIElement = true` in Info.plist) → **kein Dock-Icon**, reduziert Eindruck von Bloat und passt zum „schlank"-Ziel

### 3.9 Berechtigungen (Übersicht)

| Berechtigung | Wofür | Wann angefragt |
|---|---|---|
| Bildschirmaufnahme | Screenshot-Feature | Beim ersten Screenshot-Versuch |
| Automation (Safari/Chrome) | AppleScript-Website-Extraktion (Route A) | Beim ersten Extraktionsversuch pro Browser |
| Keine Accessibility nötig | für einfache globale Hotkeys via `HotKey`-Package | — |
| Keine Full Disk Access nötig | — | — |

### 3.10 Datenspeicherung & Aufräumen

- Screenshots: `~/Library/Caches/<BundleID>/screenshots/`, automatische Löschung >24h beim App-Start
- Konversationen: siehe 3.7
- Keinerlei Telemetrie/Analytics (hält App klein, schont Privatsphäre)

---

## 4. Technologie-Entscheidungen im Überblick

| Bereich | Entscheidung | Begründung |
|---|---|---|
| UI-Framework | SwiftUI in `NSPanel`/`NSHostingView` | Nativ, klein, kein Electron-Overhead |
| Backend | Claude Code CLI headless (`claude -p`) | Nutzt bestehendes Abo statt API-Billing |
| Globale Hotkeys | `HotKey`-SPM-Package (Carbon-Wrapper) | Bewährt, minimal, keine Accessibility-Berechtigung nötig |
| Screenshot-API | `ScreenCaptureKit` / `SCScreenshotManager` | Moderne, effiziente Apple-API statt deprecated APIs |
| Persistenz | Flache JSON-Dateien | Vermeidet Core Data/SwiftData-Runtime-Overhead |
| Markdown-Rendering | Natives `AttributedString(markdown:)` | Keine externe Abhängigkeit |
| App-Typ | Accessory-App (`LSUIElement`), Menüleiste statt Dock | Passt zum Utility-Charakter, spart Ressourcen |
| Vertrieb | Notarisiert außerhalb Mac App Store | Sandbox des App Store verhindert Subprozess-Ausführung & Native Messaging |

---

## 5. Bekannte Trade-offs / Einschränkungen

1. **Latenz pro Nachricht:** Jeder `claude -p`-Aufruf startet einen neuen Node-Prozess → spürbarer Cold-Start (~1–2s) zusätzlich zur eigentlichen Modell-Antwortzeit. Das ist inhärent an der gewählten Architektur (Abo statt Direkt-API) und nicht durch App-Optimierung eliminierbar.
2. **RAM während aktiver Nutzung:** ~100–250 MB pro laufendem `claude`-Prozess, freigegeben nach Abschluss. Ruhezustand der App selbst bleibt aber niedrig.
3. **Geteiltes Nutzungskontingent:** Headless-Aufrufe verbrauchen dasselbe Abo-Kontingent wie interaktive Claude-Code-Nutzung im Terminal — bei intensiver Chat-Nutzung über die App kann das Kontingent schneller ausgeschöpft sein.
4. **Kein Mac-App-Store-Vertrieb möglich** aufgrund der Subprozess-/Native-Messaging-Architektur.
5. **Route B (Firefox/Zen-Extraktion)** ist ein eigenständiges Mini-Projekt (WebExtension + Native Messaging Host) mit deutlich mehr Aufwand als Route A (AppleScript für Safari/Chrome).

---

## 6. Getroffene Entscheidungen & verbleibende offene Frage

**Entschieden:**
- Browser-Priorität: **Firefox/Zen via Route B** (WebExtension + Native Messaging) — nicht Safari/Chrome.
- Minimale macOS-Version: **14+** (ermöglicht `SCScreenshotManager` und `SMAppService` ohne Fallback-Code).
- Konversationsmodell: **mehrere parallele Konversationen von Anfang an** (siehe 3.7, 3.6).

**Noch offen:**
1. **Bild-Anhänge in `claude -p`:** Exakte Syntax/Verhalten beim Referenzieren einer Bilddatei im Headless-Prompt sollte zu Beginn der Implementierung mit einem einfachen Testaufruf verifiziert werden, bevor der Screenshot-Feature-Code darauf aufbaut.

---

## 7. Vorgeschlagener Phasenplan

**Phase 1 — MVP**
Floating `NSPanel` + globaler Toggle-Shortcut + einfacher Text-Chat über `claude -p` (blockierendes JSON, kein Streaming) + Session-Handling (`--resume`) + einfache JSON-Datei-Speicherung. Kein Screenshot, keine Website-Extraktion.

**Phase 2 — Screenshots**
`ScreenCaptureKit`-Integration für Vollbild & Bereichsauswahl, Anhängen an Prompt, Berechtigungs-Flow.

**Phase 3 — Streaming**
Umstellung auf `stream-json` für Live-Antwort-Anzeige.

**Phase 4 — Website-Extraktion**
Route B (WebExtension + Native Messaging Host für Firefox/Zen): zuerst der Native-Messaging-Host inkl. Installations-/Registrierungslogik, dann die WebExtension (Content-Script + Background-Script), zuletzt die Socket-Anbindung an die Haupt-App.

**Phase 5 — Politur & Vertrieb**
Settings-UI, Shortcut-Anpassung, Launch-at-Login, Code-Signing, Notarisierung, DMG-Erstellung, Binary-Größenoptimierung (Dead-Code-Stripping, Whole-Module-Optimization).

---

## 8. Packaging & Distribution

- Universal Binary (arm64 + x86_64) über Xcode-Target „Any Mac"
- Release-Build: Dead-Code-Stripping aktiv, Whole-Module-Optimization (`-O`), Debug-Symbole entfernt
- Kein App Sandbox (inkompatibel mit Subprozess-Ausführung & Native Messaging) — stattdessen Hardened Runtime + Notarisierung für Verteilung außerhalb des App Store
- Vertrieb als notarisiertes `.app` in einer `.dmg`, z. B. über eigene Website oder GitHub Releases