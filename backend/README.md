# Mesh Messenger — Backend

ASP.NET Core 10 backend for the Mesh Messenger iOS app. Thin identity + group coordination + ephemeral relay only — no message history server-side.

## Quick start

```powershell
cd backend
docker compose up -d                              # postgres + redis
dotnet user-secrets init
dotnet user-secrets set "Jwt:SigningKey"   "$([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))"
dotnet user-secrets set "PhoneHash:Pepper" "$([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))"
dotnet run
```

The API listens on `http://localhost:5080` (and `https://localhost:5443` if launched with the `https` profile). Health check at `/health`.

In Development mode `db.Database.EnsureCreated()` is called on startup so you don't need to run migrations to try the API. For production, generate a real migration:

```powershell
dotnet tool install --global dotnet-ef
dotnet ef migrations add Initial
dotnet ef database update
```

## Configuration

Required (set via user-secrets or environment variables — never check raw values into git):

- `Jwt:SigningKey` — at least 32 chars. HS256 secret for access tokens.
- `PhoneHash:Pepper` — at least 16 chars. Fixed Argon2id salt for deterministic phone lookup. Treat as highly sensitive.

Optional — when unset, the app uses dev stubs that log to the console instead of hitting the real services:

- `Twilio:AccountSid`, `Twilio:AuthToken`, `Twilio:FromNumber` — when all three are set, OTP SMS goes through Twilio. Otherwise the OTP is logged at WARN level (look for `[DEV SMS]`).
- `Apns:KeyId`, `Apns:TeamId`, `Apns:BundleId`, `Apns:PrivateKeyPath` — when all set and the `.p8` file exists, relay-message notifications are sent to APNs. `Apns:UseSandbox` defaults to `true`. Otherwise pushes are logged (look for `[DEV PUSH]`).

Connection strings:

- `ConnectionStrings:Postgres` — defaults match `docker-compose.yml`.
- `ConnectionStrings:Redis` — defaults to `localhost:6379`.

## Endpoints

Auth (no JWT required):
- `POST /auth/request-otp` — `{ phoneNumber }` → sends OTP, rate-limited
- `POST /auth/verify-otp` — `{ phoneNumber, otp, username? }` → `AuthResponseDto`. `username` only required on first verification for a phone.
- `POST /auth/refresh` — `{ refreshToken }` → new tokens (rotates refresh token)
- `POST /auth/logout` — `{ refreshToken }` → revokes refresh token and APNs device token

Users (JWT required):
- `GET  /users/search?q={prefix}` → up to 20 username matches
- `POST /users/contacts` — `{ phoneHashes: [...] }` → matches for hashes the client already knows. Max 1000 per request.

Groups (JWT required):
- `POST   /groups` — `{ name }` → creates group, caller is admin
- `GET    /groups/{id}` → group + members (caller must be a member)
- `POST   /groups/{id}/join` — `{ inviteCode }` → joins if code matches
- `DELETE /groups/{id}/members/{userId}` → admin removes, or self leaves (admin cannot remove self while still admin)
- `PUT    /groups/{id}/members/{userId}` — `{ role }` → admin only; promoting transfers admin ownership
- `DELETE /groups/{id}` → admin only

Relay (JWT required):
- `POST   /relay/messages` — `{ groupId, envelopePayload }` → stores opaque payload in Redis (24h TTL) and triggers APNs background push to other group members
- `GET    /relay/messages?groupId={id}&since={iso8601}` → unexpired payloads for the group
- `DELETE /relay/messages/{messageId}` → removes a single message (sender or any group member)

Push (JWT required):
- `POST   /push/register` — `{ deviceToken }` → sets caller's APNs device token (replaces any previous)
- `DELETE /push/register` — `{ deviceToken }` → clears it if it matches

## Notes on the design

- Phone numbers are normalised (digits-only + optional leading `+`) and hashed with Argon2id using a server-side pepper. The hash is stored; the raw number is not. Lookup is deterministic because the pepper is fixed. The `PhoneNumberLookup` column stores the last 4 digits only — useful for ops/telemetry buckets, not for lookup.
- Refresh tokens are 256-bit random values, base64url encoded. Stored as SHA-256 hashes. One per user — login on a new device atomically rotates the token, invalidating the old session.
- Access tokens are HS256 JWTs with a 15-min default TTL.
- OTPs are 6 digits, lifetime 10 min, max 5 wrong attempts, max 3 requests per 15 min per phone hash. Stored in Redis only.
- Relay messages are stored in Redis as `relay:msg:{id}` strings with the configured TTL, plus a sorted set `relay:group:{groupId}` for time-range queries. The envelope is treated as an opaque payload — the server never inspects message content.
