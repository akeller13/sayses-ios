# SAYses iOS - Setup Anleitung

## Voraussetzungen

- Xcode 15.0 oder neuer
- macOS Sonoma 14.0 oder neuer
- CocoaPods (optional für Dependencies)
- CMake 3.20+ (für C++ Core Build)

## Xcode Projekt erstellen

### 1. Neues Projekt in Xcode erstellen

1. Öffne Xcode
2. File → New → Project
3. Wähle "iOS" → "App"
4. Konfiguriere:
   - Product Name: `SAYses`
   - Team: Dein Apple Developer Team
   - Organization Identifier: `com.sayses`
   - Interface: `SwiftUI`
   - Language: `Swift`
   - Storage: `None`

5. Speichere das Projekt in `/Users/andreaskeller/developer/sayses-ios/`

### 2. Bestehende Dateien hinzufügen

1. Lösche die automatisch erstellten Dateien (ContentView.swift, SAYsesApp.swift)
2. Rechtsklick auf das SAYses Target → "Add Files to SAYses..."
3. Füge alle Ordner aus `SAYses/` hinzu:
   - App/
   - UI/
   - ViewModels/
   - Models/
   - Services/
   - Bridges/
   - Resources/

### 3. Bridging Header konfigurieren

1. Build Settings → Swift Compiler - General
2. "Objective-C Bridging Header" setzen auf:
   ```
   SAYses/Bridges/SAYses-Bridging-Header.h
   ```

### 4. Build Settings anpassen

```
SWIFT_OBJC_BRIDGING_HEADER = SAYses/Bridges/SAYses-Bridging-Header.h
ENABLE_BITCODE = NO
INFOPLIST_FILE = SAYses/Resources/Info.plist
CODE_SIGN_ENTITLEMENTS = SAYses/Resources/SAYses.entitlements
```

### 5. C++ Core kompilieren

```bash
cd /Users/andreaskeller/developer/sayses-ios/Core
mkdir build && cd build
cmake .. -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build . --config Release
```

### 6. C++ Framework einbinden

1. Ziehe `SaysesCore.framework` in das Xcode Projekt
2. Target → General → Frameworks, Libraries, and Embedded Content
3. Füge `SaysesCore.framework` als "Embed & Sign" hinzu

### 7. Required Frameworks

Füge folgende System Frameworks hinzu:
- AVFoundation
- AuthenticationServices
- PushKit
- Security
- AudioToolbox

## Capabilities aktivieren

1. Target → Signing & Capabilities → "+ Capability"
2. Aktiviere:
   - Background Modes (Audio, VoIP)
   - Push Notifications
   - Associated Domains

## Build & Run

1. Wähle ein iPhone Device oder Simulator
2. ⌘+R zum Bauen und Starten

## Troubleshooting

### "Bridging Header not found"
Stelle sicher, dass der Pfad zum Bridging Header korrekt ist.

### "Missing symbols for C++ code"
1. Prüfe ob SaysesCore.framework korrekt eingebunden ist
2. Prüfe die Library Search Paths in Build Settings

### "Microphone permission denied"
Die App benötigt eine Beschreibung in Info.plist für den Mikrofonzugriff (NSMicrophoneUsageDescription).
