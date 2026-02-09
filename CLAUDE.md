# Claude Code Anweisungen für SAYses iOS

## Wichtige Pfade

- **Backend:** `ssh damian:/opt/vox/backend`
- **Android:** `/Users/andreaskeller/developer/sayses-android/app/src/main/java/com/sayses/android/service`

## Allgemeine Verhaltensregeln

### Bei Unsicherheit immer nachfragen
Wenn Anweisungen mehrdeutig sind oder mehrere Implementierungsansätze möglich sind:
- **Nicht selbst entscheiden** und den "praktischsten" Weg wählen
- **Immer nachfragen** und die Optionen präsentieren
- Die Entscheidung liegt beim Benutzer, nicht bei Claude

### Keine eigenmächtigen Änderungen
- **Code-Änderungen und Layout-Änderungen nur mit explizitem Auftrag des Benutzers**
- Niemals eigenständig Code hinzufügen, entfernen oder umstrukturieren, der nicht ausdrücklich beauftragt wurde
- Auch keine "kleinen Verbesserungen" oder "Aufräumarbeiten" ohne Auftrag

## Backend-Hinweise

### AsyncSession (SQLAlchemy 2.0)
Beim Anlegen oder Ändern eines Endpunktes darauf achten: `auth.db` ist eine `AsyncSession` (SQLAlchemy 2.0). Eine solche hat keine `.query()` Methode. Man muss stattdessen `select()` + `await db.execute()` verwenden.

### Lokale Imports in Endpoint-Funktionen
Models wie `DispatcherRequest`, `AlarmLog` etc. sind NICHT auf Modul-Ebene importiert. Jede Endpoint-Funktion muss einen **lokalen Import** haben:

```python
# RICHTIG — lokaler Import + async select():
async def my_endpoint(auth: MobileAuth = Depends(get_mobile_auth_extended_timestamp)):
    auth.verify_sse_signature()
    from models import DispatcherRequest   # ← PFLICHT!
    db = auth.db

    query = select(DispatcherRequest).where(
        DispatcherRequest.certificate_hash == auth.certificate_hash,
        DispatcherRequest.status == "in_progress"
    )
    result = await db.execute(query)
    request = result.scalars().first()

# FALSCH — kein lokaler Import:
async def my_endpoint(auth: ...):
    db = auth.db
    query = select(DispatcherRequest).where(...)  # ← NameError!

# FALSCH — AsyncSession hat kein .query():
request = db.query(DispatcherRequest).filter(...).first()  # ← AttributeError!
```

## Build & Deploy

- Projekt öffnen: `open SAYses.xcodeproj`
- Build über Xcode (Cmd+B)
- Deploy über Xcode auf angeschlossenes Gerät

## Architektur

- Swift mit SwiftUI für UI
- @Observable / @StateObject für State Management
- Mumble-Protokoll für Kommunikation
- Keycloak für OAuth2 Authentifizierung

## Wichtige Verzeichnisse

- UI Screens: `SAYses/UI/Screens/`
- UI Components: `SAYses/UI/Components/`
- Services: `SAYses/Services/`
- ViewModels: `SAYses/ViewModels/`
- Data Models: `SAYses/Models/`

---

## KRITISCHE BUGFIXES - NIEMALS RÜCKGÄNGIG MACHEN

### 1. OfflineStatusBanner blockiert Touch-Events
**Problem:** Das OfflineStatusBanner im ZStack blockiert Touch-Events für darunterliegende Elemente.
**Lösung:** IMMER `.allowsHitTesting(false)` auf OfflineStatusBanner setzen.
**Betroffene Dateien:**
- `SAYses/UI/Screens/ChannelList/ChannelListView.swift`
- `SAYses/UI/Screens/Channel/ChannelView.swift`

```swift
// RICHTIG:
OfflineStatusBanner(secondsUntilRetry: mumbleService.reconnectCountdown)
    .allowsHitTesting(false)

// FALSCH - blockiert Touch-Events:
OfflineStatusBanner(secondsUntilRetry: mumbleService.reconnectCountdown)
```

### 2. Login-Loop nach Keycloak-Authentifizierung
**Problem:** Nach erfolgreicher Keycloak-Anmeldung landet der User wieder auf dem Login-Screen.
**Ursache:** Race Condition - `checkAuthentication()` wird während des Logins aufgerufen.
**Lösung:** `isLoginInProgress` Flag in AuthViewModel verwenden.
**Betroffene Datei:** `SAYses/ViewModels/AuthViewModel.swift`

```swift
private var isLoginInProgress = false

func checkAuthentication() async {
    if isAuthenticated { return }
    if isLoginInProgress { return }  // WICHTIG!
    // ...
}

func lookupAndLogin(emailOrUsername: String) async {
    isLoginInProgress = true
    // ... login logic ...
    isLoginInProgress = false
}
```

### 3. AlarmTriggerButton außerhalb NavigationStack
**Problem:** Wenn AlarmTriggerButton außerhalb des NavigationStack platziert ist, bleibt er beim Navigieren zur ChannelView sichtbar (zwei Alarm-Buttons übereinander).
**Lösung:** AlarmTriggerButton auf BEIDEN Seiten via `.safeAreaInset(edge: .bottom)` einbinden. In ChannelListView mit `navigationPath.isEmpty`-Bedingung, damit er beim Navigieren zur Detailseite ausgeblendet wird. In ChannelView als eigener `.safeAreaInset`.
**Betroffene Dateien:**
- `SAYses/UI/Screens/ChannelList/ChannelListView.swift` - HAT AlarmTriggerButton (nur wenn `navigationPath.isEmpty`)
- `SAYses/UI/Screens/Channel/ChannelView.swift` - HAT AlarmTriggerButton (eigener safeAreaInset)

### 4. Menüs in Toolbar reagieren nicht
**Problem:** profileMenu und optionsMenu in der Toolbar reagieren nicht auf Tippen.
**Ursache:** NavigationStack war in einem VStack gewrappt, was die Toolbar-Interaktion stört.
**Lösung:** NIEMALS NavigationStack in VStack wrappen. Für zusätzliche Elemente am unteren Rand `safeAreaInset` verwenden.
**Betroffene Datei:** `SAYses/UI/Screens/ChannelList/ChannelListView.swift`

```swift
// RICHTIG - safeAreaInset für Elemente am unteren Rand:
NavigationStack(path: $navigationPath) {
    // Content
    .toolbar { ... }
}
.safeAreaInset(edge: .bottom) {
    AlarmTriggerButton(...)
}

// FALSCH - VStack um NavigationStack blockiert Toolbar:
VStack {
    NavigationStack(path: $navigationPath) {
        // Content
        .toolbar { ... }  // <-- Menüs funktionieren nicht!
    }
    AlarmTriggerButton(...)
}
```

---

## Checkliste nach Code-Änderungen

Vor jedem Deployment prüfen:
- [ ] OfflineStatusBanner hat `.allowsHitTesting(false)`
- [ ] Menüs in Toolbar funktionieren (profileMenu, optionsMenu)
- [ ] Login funktioniert ohne Loop
- [ ] AlarmTriggerButton auf Kanalübersicht UND Kanaldetailseite sichtbar (je einer, nicht doppelt)
- [ ] Navigation zwischen Screens funktioniert
- [ ] PTT Button funktioniert auf Detailseite
