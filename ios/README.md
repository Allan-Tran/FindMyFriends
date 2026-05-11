# Mesh Messenger — iOS

SwiftUI + SwiftData + MultipeerConnectivity + CoreBluetooth. Targets iOS 17+.

## Project setup in Xcode

This folder is a flat tree of Swift sources, not an `.xcodeproj`. To open it in Xcode:

1. **File → New → Project… → iOS → App.** Product Name `MeshMessenger`, Interface SwiftUI, Language Swift, no Core Data, no tests.
2. Pick a location *outside* this folder.
3. In the project navigator, delete the auto-generated `MeshMessengerApp.swift`, `ContentView.swift`, and `Assets.xcassets` group references (move to trash is fine).
4. Drag the contents of [MeshMessenger/](MeshMessenger/) into the project navigator. Choose **"Create folder references"** so the layout stays in sync if files are added later.
5. In the target's **Info** tab, paste the keys from [MeshMessenger/Resources/Info-additions.plist](MeshMessenger/Resources/Info-additions.plist) into the Info.plist (or replace the generated one entirely).
6. In **Signing & Capabilities**, add the **Background Modes** capability and enable:
   - Uses Bluetooth LE accessories
   - Acts as a Bluetooth LE accessory
   - Background fetch
   - Remote notifications
7. Add the **Push Notifications** capability.
8. Set the deployment target to iOS 17.0 minimum.
9. Edit [Config/AppConfig.swift](MeshMessenger/Config/AppConfig.swift) so `backendBaseURL` points at your running ASP.NET backend (default: `http://localhost:5080`, which won't be reachable on a device — use your machine's LAN IP).

## Architecture

Four-layer separation, matching the design doc:

```
Views/         SwiftUI presentation
Domain/        AuthSession, GroupStore, MessageRouter — orchestrates engines + persistence
Mesh/          MeshEngine — MultipeerConnectivity advertiser+browser, flood routing
Proximity/     ProximityEngine — CoreBluetooth scan + Kalman smoothing + distance bands
Sync/          SyncEngine — NWPathMonitor + relay push/fetch
Network/       APIClient + per-resource API wrappers
Persistence/   SwiftData @Model types — sole writers of the local SQLite store
```

The three engines do not call each other. They emit events; the domain layer routes between them and persistence.

## What's covered in this drop

- Authentication via the backend OTP flow (phone → SMS code → JWT). Tokens stored in Keychain.
- Group create / join (invite code) / list. Local-first reads with server refresh.
- BLE mesh: advertiser + browser + auto-accept, controlled flooding with TTL + dedup, persisted on receive.
- Proximity: BLE peripheral beacon + central scan + per-peer Kalman-smoothed RSSI → bands.
- Online relay: when connected, outgoing messages also POST to `/relay/messages`, and pending messages are fetched via `GET /relay/messages?groupId=…&since=…`.
- APNs: device-token registration after login. Background remote-notification handler triggers a relay fetch.

## What's left to wire by hand

- A real `MCPeerID` strategy is included (persisted per install). On username change you should regenerate.
- The Multipeer service type is `mesh-msgr` (matches `NSBonjourServices`).
- Background execution: Multipeer connections will degrade after ~30s in background. This is accepted per the design. The proximity beacon continues via `bluetooth-peripheral` mode.

## I'm on Windows, you're not

These files were written without a Swift compiler. Type-check + fix-up in Xcode is expected. Most likely friction points: SwiftData `@Model` strict-concurrency warnings (silence with `@unchecked Sendable` if needed), and `MCPeerID` requires a `let` not `var` since it's reference-cached.
