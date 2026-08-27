# Claude Chat – Firefox/Zen Extension

Diese WebExtension extrahiert den Inhalt des aktiven Browser-Tabs für die Claude Chat macOS App (Route B: Native Messaging).

## Voraussetzungen

1. Claude Chat App installiert und mindestens einmal gestartet (registriert den Native-Messaging-Host automatisch).
2. Firefox oder Zen Browser.

## Extension laden (Entwicklermodus)

### Firefox

1. `about:debugging#/runtime/this-firefox` öffnen
2. **Temporäres Add-on laden…**
3. Den Ordner `ClaudeChatExtension` auswählen (mit `manifest.json`)

### Zen Browser

1. `about:debugging` öffnen
2. **Load Temporary Add-on…** / **Temporäres Add-on laden…**
3. Den Ordner `ClaudeChatExtension` auswählen

Nach dem Laden verbindet sich die Extension automatisch mit dem Native-Messaging-Host (`dev.claudechat`).

## Native Messaging

- Host-Name: `dev.claudechat`
- Extension-ID: `claudechat@dev.local` (fest in `manifest.json` → `browser_specific_settings.gecko.id`)
- Host-Manifest: `~/Library/Application Support/Mozilla/NativeMessagingHosts/dev.claudechat.json`
- Zen (falls vorhanden): `~/Library/Application Support/Zen/NativeMessagingHosts/dev.claudechat.json`

Firefox erwartet im Host-Manifest **`allowed_extensions`** (Extension-ID), nicht Chrome-`allowed_origins` (`moz-extension://…`).

Die App kopiert das Host-Binary nach:

`~/.claudechat/ClaudeChatNativeHost`

(Socket: `~/.claudechat/claudechat.sock`)

## Nutzung

1. Firefox/Zen mit geladener Extension offen lassen
2. Beliebige Webseite im aktiven Tab öffnen
3. In Claude Chat **⌥⇧W** drücken

Die App extrahiert Titel, URL und bereinigten Text und sendet sie an Claude.

## Fehlerbehebung

| Problem | Lösung |
|---------|--------|
| „Keine Verbindung zum Browser“ | Extension laden, App neu starten (schreibt Host-Manifest neu), Browser neu starten |
| „This extension does not have permission…“ | Host-Manifest prüfen: `allowed_extensions` muss `["claudechat@dev.local"]` enthalten |
| Native Messaging blockiert | In `about:config` prüfen, ob Extensions Native Messaging nutzen dürfen |
| Leerer Inhalt | Seite vollständig laden; `about:`/`moz-extension:`-Seiten werden nicht unterstützt |

### about:debugging – Konsole prüfen

1. Extension unter **Temporäre Erweiterungen** finden
2. **Untersuchen** klicken → Konsole öffnen
3. Erwartete Meldungen nach dem Laden:
   - `Claude Chat: Extension gestartet. runtime.id: claudechat@dev.local origin: moz-extension://claudechat@dev.local/ …`
   - `Claude Chat: Native Host verbunden. …`
4. Bei Fehlern:
   - `connectNative fehlgeschlagen: …` → Host-Manifest oder App-Installation prüfen
   - `Native Host getrennt: Access denied` → `allowed_extensions` stimmt nicht mit `runtime.id` überein

### Host-Manifest manuell prüfen

```bash
cat ~/Library/Application\ Support/Mozilla/NativeMessagingHosts/dev.claudechat.json
```

Erwartung (Pfad anpassen):

```json
{
  "allowed_extensions": ["claudechat@dev.local"],
  "description": "Claude Chat Native Messaging Host",
  "name": "dev.claudechat",
  "path": "/Users/<user>/.claudechat/ClaudeChatNativeHost",
  "type": "stdio"
}
```

## Manuelle Tests

1. App bauen und starten → Host-Manifest prüfen (siehe oben)
2. Extension laden, Konsole in `about:debugging` öffnen → `Native Host verbunden` sichtbar
3. Webseite öffnen, **⌥⇧W** → Chat-Panel zeigt extrahierten Inhalt
