# Claude Chat

Native macOS-Menüleisten-App mit schwebendem Chat-Fenster, das **Claude Code** im Headless-Modus (`claude -p`) als Backend nutzt — authentifiziert über dein bestehendes Claude-Abo, nicht über API-Billing.

Die App läuft dauerhaft im Hintergrund (kein Dock-Icon), lässt sich per globalem Shortcut ein- und ausblenden und unterstützt Screenshots, Website-Extraktion aus Firefox/Zen sowie das Senden von Dateien aus Finder und Vorschau.

## Funktionen

- **Floating Chat-Fenster** — per Shortcut ein-/ausblendbar, bleibt auf allen Desktops sichtbar
- **Claude Code Integration** — nutzt die lokal eingeloggte CLI-Session (`claude login`)
- **Streaming-Antworten** — Live-Anzeige während Claude antwortet
- **Mehrere Konversationen** — parallele Chats mit Session-Verwaltung (`--resume`)
- **Screenshots** — Vollbild oder Bereichsauswahl, direkt an Claude senden
- **Website-Extraktion** — Inhalt des aktiven Firefox-/Zen-Tabs per WebExtension + Native Messaging
- **Dateien senden** — markierte Finder-Dateien oder geöffnete Vorschau-Dokumente
- **Anpassbare Shortcuts** — alle Hotkeys in den Einstellungen konfigurierbar
- **Start bei Login** — optional über die Einstellungen

## Voraussetzungen

| Anforderung | Details |
|---|---|
| **macOS** | 14.0 (Sonoma) oder neuer |
| **Claude Code CLI** | Installiert und mit `claude login` authentifiziert |
| **Firefox oder Zen** | Nur für die Website-Extraktion (WebExtension erforderlich) |
| **Xcode** | Nur zum Bauen aus dem Quellcode (15+) |

## Installation

### Vorgebautes DMG

1. `ClaudeChat-0.1.0.dmg` öffnen
2. **Claude Chat.app** nach **Programme** ziehen und einmal starten
3. Firefox-Extension installieren: `about:addons` → Zahnrad → **Add-on aus Datei installieren…** → `claude-chat-website-extractor-1.0.0.xpi` aus dem DMG wählen
4. Browser neu starten (empfohlen)

Beim ersten Start registriert die App automatisch den Native-Messaging-Host für Firefox/Zen.

### Aus dem Quellcode bauen

```bash
# App bauen
./scripts/build-release.sh

# Vollständiges Release (App + signierte Extension + DMG)
./scripts/build-distribution.sh
```

Details zu Code Signing und Notarisierung: [docs/RELEASE.md](docs/RELEASE.md)

## Erste Schritte

1. **Claude Code CLI einrichten** (falls noch nicht geschehen):

   ```bash
   # Installation je nach Setup, z. B.:
   npm install -g @anthropic-ai/claude-code
   claude login
   ```

2. **Claude Chat starten** — erscheint als Icon in der Menüleiste
3. **Chat öffnen** mit dem Standard-Shortcut **⌃⌥⌘K** (oder Linksklick auf das Menüleisten-Icon)
4. **Für Website-Extraktion:** Firefox-Extension installieren (siehe oben)

Fehlt die CLI oder die Anmeldung, zeigt die App eine Onboarding-Anleitung an.

## Tastenkürzel

Alle Shortcuts sind in **Einstellungen…** (Menüleisten-Icon → Rechtsklick) anpassbar.

| Aktion | Standard |
|---|---|
| Chat ein-/ausblenden | ⌃⌥⌘K |
| Vollbild-Screenshot | ⌥⇧S |
| Bereichs-Screenshot | ⌥⇧D |
| Website extrahieren | ⌥⇧W |
| Datei senden | ⌥⇧F |
| Neue Konversation | ⌥⇧N |

## Berechtigungen

Die App fragt Berechtigungen erst beim ersten Nutzen des jeweiligen Features an:

| Berechtigung | Wofür |
|---|---|
| **Bildschirmaufnahme** | Screenshot-Funktion |
| **Automation (Finder/Vorschau)** | Datei senden |
| **Native Messaging** | Website-Extraktion über Firefox/Zen |

Nach Erteilen der Bildschirmaufnahme-Berechtigung ist ein **Neustart der App** erforderlich.

## Firefox-Extension

Die WebExtension extrahiert Titel, URL und bereinigten Text des aktiven Tabs und leitet ihn über einen Native-Messaging-Host an die App weiter.

- Ausführliche Anleitung und Fehlerbehebung: [ClaudeChatExtension/README.md](ClaudeChatExtension/README.md)
- Für Entwicklung kann die Extension auch temporär über `about:debugging` geladen werden

## Projektstruktur

```
claude-chat/
├── ClaudeChat/              # macOS-App (Swift/SwiftUI + AppKit)
│   └── ClaudeChat/
│       ├── Services/        # CLI, Screenshots, Konversationen, Hotkeys, …
│       ├── Views/           # Chat-UI, Einstellungen
│       └── Windows/         # Floating NSPanel
├── ClaudeChatExtension/     # Firefox/Zen WebExtension
├── ClaudeChatNativeHost/    # Native-Messaging-Host (stdin/stdout ↔ Unix-Socket)
├── scripts/                 # Build-, Signier- und DMG-Skripte
├── docs/                    # Release-Dokumentation
└── SPEC.md                  # Technische Spezifikation
```

## Architektur

```
Menüleisten-App (LSUIElement)
    ├── Floating NSPanel + SwiftUI-Chat
    ├── Globale Hotkeys (HotKey-SPM)
    ├── ScreenCaptureKit (Screenshots)
    ├── AppleScript (Finder/Vorschau)
    └── Claude Code CLI (claude -p, stream-json)
            ↑
Firefox/Zen Extension → Native Messaging Host → Unix-Socket
```

Die App startet für jede Nachricht einen `claude`-Subprozess und verwaltet Sessions über `--resume`. Konversationen werden als JSON-Dateien in `~/Library/Application Support/` gespeichert.

## Entwicklung

```bash
# Release-Build
./scripts/build-release.sh

# Nur DMG (App muss bereits existieren)
./scripts/create-dmg.sh

# Extension signieren (benötigt Mozilla AMO API-Keys in scripts/amo-credentials.env)
./scripts/sign-extension.sh
```

Öffne `ClaudeChat/ClaudeChat.xcodeproj` in Xcode für lokale Entwicklung mit Debugging.

## Bekannte Einschränkungen

- Jede Nachricht startet einen neuen `claude`-Prozess (~1–2 s Cold-Start zusätzlich zur Antwortzeit)
- Während aktiver Anfragen: ~100–250 MB RAM pro laufendem CLI-Prozess
- Nutzung zählt gegen das gleiche Abo-Kontingent wie Claude Code im Terminal
- Kein Mac App Store (Subprozesse und Native Messaging erfordern Verteilung außerhalb des Store)
- Website-Extraktion aktuell nur für Firefox/Zen, nicht für Safari/Chrome

## Lizenz

Siehe Repository für Lizenzinformationen.

## Weiterführend

- [SPEC.md](SPEC.md) — vollständige technische Spezifikation
- [docs/RELEASE.md](docs/RELEASE.md) — Code Signing, Notarisierung, Distribution
- [ClaudeChatExtension/README.md](ClaudeChatExtension/README.md) — Extension-Setup und Troubleshooting
