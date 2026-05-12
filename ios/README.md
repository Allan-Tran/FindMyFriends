# Mesh Messenger — iOS

SwiftUI + SwiftData + MultipeerConnectivity + CoreBluetooth + Firebase. Targets iOS 17+.

## Project setup in Xcode

This folder is a flat tree of Swift sources, not an `.xcodeproj`. To open it in Xcode:

1. **File → New → Project… → iOS → App.** Product Name `MeshMessenger`, Interface SwiftUI, Language Swift.
2. Pick a location outside this folder.
3. Delete the generated `MeshMessengerApp.swift`, `ContentView.swift`, `Assets.xcassets` references (trash is fine).
4. Drag the contents of [MeshMessenger/](MeshMessenger/) into the project navigator. Choose **"Create folder references"** so new files appear automatically.
5. **Add the Firebase SDK** via SwiftPM: File → Add Package Dependencies → `https://github.com/firebase/firebase-ios-sdk` → pick:
   - `FirebaseAuth`
   - `FirebaseFirestore`
   - `FirebaseMessaging`
6. **Drop in `GoogleService-Info.plist`.** Download it from your Firebase project's iOS app config and add it to the Xcode project root (inside the app target). See [../firebase/README.md](../firebase/README.md) for the full Firebase project setup.
7. Merge the keys from [MeshMessenger/Resources/Info-additions.plist](MeshMessenger/Resources/Info-additions.plist) into the target's Info.plist, or replace it entirely.
8. **Signing & Capabilities** → add:
   - **Push Notifications**
   - **Background Modes** → enable *Uses Bluetooth LE accessories*, *Acts as a Bluetooth LE accessory*, *Background fetch*, *Remote notifications*.
9. Deployment target: iOS 17.0+.

The first run of the app will create a Firebase Auth user and write `users/{uid}` to Firestore. Subsequent runs read the session from Firebase Auth automatically — there is no local token store.

## Architecture

```
Views/         SwiftUI screens
Domain/        AuthSession, GroupStore, MessageRouter — orchestrates engines + persistence
Mesh/          MeshEngine — MultipeerConnectivity advertiser+browser, flood routing
Proximity/     ProximityEngine — CoreBluetooth scan + Kalman smoothing + distance bands
Sync/          SyncEngine — NWPathMonitor + Firestore relay snapshot listeners
Firebase/      AuthService, UserService, GroupService, RelayService, PushService, models
Persistence/   SwiftData @Model types — sole writers of the local SQLite store
Push/          PushNotificationCenter + AppDelegate — FCM + APNs handoff
Config/        AppConfig
```

The three engines do not call each other; the domain layer routes events.

## Data shape on Firebase

See [../firebase/README.md](../firebase/README.md). Short version:

- `users/{uid}` — profile (username, email, fcmToken, emailVerified).
- `usernames/{lower}` — reservation row enforcing username uniqueness.
- `inviteCodes/{code}` — code → groupId lookup, used for join-by-code.
- `groups/{groupId}` — name, adminId, inviteCode, memberIds[].
- `groups/{groupId}/members/{uid}` — role + denormalised username.
- `groups/{groupId}/relay/{messageId}` — ephemeral relay envelopes with TTL on `expiresAt`.

## Auth

Firebase Auth, email + password.

- **Sign up** writes `users/{uid}` and reserves the username in a single batch, then sends a verification email.
- **Email verification gate.** `ContentView` shows `EmailVerificationView` while `isEmailVerified == false`. Group creation is also gated server-side in `firestore.rules` (the `isVerified()` helper).
- **Password reset** uses Firebase's built-in email link flow.
- **Sign out on a new device** is automatic — Firebase Auth maintains one session per device and replaces the FCM token on next login.

## Local Firebase emulator (optional)

For development without touching prod:

```bash
cd firebase
firebase emulators:start
```

Then in [Config/AppConfig.swift](MeshMessenger/Config/AppConfig.swift) flip `useEmulator = true` and set `emulatorHost` to your dev machine's address (e.g. `127.0.0.1` for iOS Simulator on the same Mac, or your Mac's LAN IP for a real device).

## What's covered

- Email/password auth with verification, reset, and gated app entry.
- Group create/join/leave with invite codes.
- BLE mesh: advertiser + browser + auto-accept, controlled flooding with TTL + dedup, persisted on receive.
- Proximity: BLE peripheral beacon + central scan + per-peer Kalman-smoothed RSSI → bands.
- Online relay: outgoing chat envelopes also POST to `groups/{id}/relay`, snapshot listeners deliver incoming.
- FCM: device-token registration after login; background push from the Cloud Function wakes the app for a Firestore fetch.

## Heads-up for Xcode

These files were written without a Swift compiler. Most likely friction points when you first build:

- If Swift 6 strict concurrency complains about `AuthService`/etc being `Sendable`, drop the `Sendable` conformance (they're value types with non-isolated fields that *are* Sendable in practice — Swift just can't always prove it).
- `@DocumentID` requires `import FirebaseFirestore` in any file that uses it. All `FirebaseModels.swift` types already do.
- The `Messaging.messaging().delegate` connection in `PushNotificationCenter` needs to happen after `FirebaseApp.configure()`. `MeshMessengerApp.init` calls `FirebaseManager.configure()` before constructing the push center, so this is already correct.
