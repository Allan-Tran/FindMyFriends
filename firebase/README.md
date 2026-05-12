# Mesh Messenger — Firebase

All server-side concerns live here: Firestore security rules, indexes, and the single Cloud Function that fans out FCM pushes when a relay message lands.

## One-time setup

1. **Install the Firebase CLI** (if you don't already have it):
   ```bash
   npm install -g firebase-tools
   firebase login
   ```

2. **Create the Firebase project** at <https://console.firebase.google.com>:
   - New project, name `mesh-messenger` (or anything).
   - In the new project: **Build → Authentication → Get started → Email/Password → Enable**. Also enable **Email link (passwordless sign-in)** if you ever want it, but it's not used.
   - **Build → Firestore Database → Create database → Production mode → pick a region**.
   - **Build → Cloud Messaging → Apple app config**: upload your APNs auth key (`.p8`) from Apple Developer. Without this, FCM cannot deliver to iOS.
   - **Project settings → Your apps → Add app → iOS**, bundle ID = your iOS app's bundle ID. Download `GoogleService-Info.plist` and drop it into the Xcode project root (it goes inside the app target).

3. **Upgrade to Blaze plan**. Cloud Functions requires it. You'll still pay $0 unless you exceed the free tier (2M function invocations / 400K GB-s per month — friend-group scale is nowhere near).

4. **Wire the local CLI to your project**:
   ```bash
   cd firebase
   firebase use --add        # pick the project you created
   ```

5. **Deploy rules + indexes**:
   ```bash
   firebase deploy --only firestore:rules,firestore:indexes
   ```

6. **Set the TTL policy** for relay messages. The CLI doesn't have a one-liner for TTL yet; do it once via `gcloud`:
   ```bash
   gcloud firestore fields ttls update expiresAt \
     --collection-group=relay --project=<your-project-id> --enable-ttl
   ```
   …or in the Firebase console: **Firestore → Time-to-live (TTL) → Add policy → Collection group `relay`, field `expiresAt`**.

7. **Install function deps + deploy**:
   ```bash
   cd functions
   npm install
   npm run build
   cd ..
   firebase deploy --only functions
   ```

## Local development (no deploys)

```bash
cd firebase
firebase emulators:start
```

The emulator UI is at <http://localhost:4000>. In the iOS app, point `FirebaseConfig.useEmulator = true` in `ios/MeshMessenger/Config/AppConfig.swift` to route everything to the local emulator.

## Data model

```
users/{uid}
  email          : string
  username       : string
  usernameLower  : string   // for uniqueness lookup
  createdAt      : timestamp
  fcmToken       : string?  // latest FCM token; replaced on login
  emailVerified  : bool     // mirrored from auth, updated by client

usernames/{usernameLower}
  uid            : string   // reservation for uniqueness

inviteCodes/{code}
  groupId        : string   // public-readable to authenticated users

groups/{groupId}
  name           : string
  adminId        : string
  inviteCode     : string
  createdAt      : timestamp
  memberIds      : [string]  // denormalised for "groups I'm in" query

groups/{groupId}/members/{uid}
  role           : "admin" | "member"
  joinedAt       : timestamp
  username       : string    // denormalised, refreshed by client on rename

groups/{groupId}/relay/{messageId}
  envelopePayload: string    // base64(JSON) of the MeshMessage envelope
  senderUid      : string
  storedAt       : timestamp
  expiresAt      : timestamp // 24h after storedAt; TTL policy deletes
```

## Security rules notes

- Username uniqueness: the client writes `usernames/{lower}` first (atomic create, fails if taken), then `users/{uid}`. Both happen in one Firestore batch on signup.
- Invite codes are public-readable to authenticated users. Knowing the code is the credential to join — same as the original phone-OTP design. Codes are 8-char alphanumeric; not crypto-secret, just hard to enumerate.
- `groups` create requires `emailVerified=true` to prevent unverified spam accounts from creating noise.
- `relay/{messageId}` create requires `expiresAt > request.time`, so clients must set a future timestamp (24h ahead) — otherwise TTL would expire it immediately.

## The Cloud Function

`onRelayMessageCreated` fires on every new doc under `groups/*/relay/*`. It reads the group's members, looks up each member's `fcmToken`, and sends a silent background FCM push containing `{groupId, messageId, kind:"relay"}`. The iOS client wakes briefly, reads the message from Firestore, and persists locally.

If FCM reports a stale token (`registration-token-not-registered` or `invalid-registration-token`), the function clears it from the user doc.
