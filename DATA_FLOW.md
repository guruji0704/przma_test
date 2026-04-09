# ALEM Data Flow Documentation

## Overview
ALEM is a decentralized document synchronization system with a Phoenix (Elixir) backend and a Tauri (Rust) desktop client. It uses CRDTs (Conflict-free Replicated Data Types) for offline-first document synchronization across devices.

---

## 1. Authentication Flow

### Registration Process
```
Desktop App (Tauri/Rust)              Phoenix Server (Elixir)
        |                                        |
        |  POST /api/v1/account/register         |
        |  ────────────────────────────────────────►   |
        |                                              |
        |                                              ▼
        |                                    ┌─────────────────────┐
        |                                    │  AuthController    │
        |                                    │  register_account  │
        |                                    └─────────────────────┘
        |                                              │
        |                                              ▼
        |                                    ┌─────────────────────┐
        |                                    │    Alem.Auth        │
        |                                    │  register_user/1   │
        |                                    └─────────────────────┘
        |                                              │
        |                                              ▼
        |                                    ┌─────────────────────┐
        |                                    │    Alem.DID         │
        |                                    │  generate(user_id) │
        |                                    │  Format: did:przma:|
        |                                    │  <base64url-sha256>│
        |                                    └─────────────────────┘
        |                                              │
        |                                              ▼
        |                                    ┌─────────────────────┐
        |                                    │   Pleroma.User      │
        |                                    │   (DB Schema)       │
        |                                    │  - nickname         │
        |                                    │  - password_hash    │
        |                                    │  - did_id          │
        |                                    │  - is_active       │
        |                                    └─────────────────────┘
        |                                              │
        |  ◄──────────────────────────────────────   │
        |  { account, did, namespace, sync_config }   |
```

**Key Steps:**
1. User registers via Desktop App
2. `AuthController.register_account/2` receives request
3. Captcha verification via `Auth.verify_captcha/2`
4. User created in DB via `Auth.register_user/1`
5. DID generated via `DID.generate(user_id)` → `did:przma:<sha256-fingerprint>`
6. Namespace created for user via `Namespace.create_for_user/1`
7. Returns account data, DID, namespace key, and sync configuration

### DID Generation (Alem.DID)
```
elixir
def generate(user_id) do
  # Create unique input: user_id + random nonce + timestamp
  nonce = :crypto.strong_rand_bytes(32)
  timestamp = System.system_time(:microsecond)
  input = "#{user_id}#{Base.encode64(nonce)}#{timestamp}"
  
  # Generate SHA-256 hash
  hash = :crypto.hash(:sha256, input)
  
  # Encode as base64url (no padding)
  fingerprint = Base.url_encode64(hash, padding: false)
  
  # Format as DID
  "did:przma:#{fingerprint}"
end
```

### OAuth Token Flow
1. **LOGIN REQUEST:** Client ──POST /oauth/token──► Server
2. **VERIFICATION:** Alem.Auth.authenticate_user/2
3. **TOKEN CREATION:** Alem.Auth.create_token/3
4. **RESPONSE:** {access_token, token_type, expires_in}
5. **SUBSEQUENT REQUESTS:** Headers: Authorization: Bearer <access_token>

---

## 2. Document Storage Flow

### Desktop App → Server Upload
```
Desktop App                                    Phoenix Server
    |                                              |
    |  User creates/edits document                 |
    |  (CRDT: Automerge)                           |
    |                                              |
    |  ┌─────────────────────────────────────┐     │
    |  │  Local libsql DB (Embedded)         │     │
    |  │  - documents table                 │     │
    |  │  - automerge_state (blob)          │     │
    |  │  - text_content                    │     │
    |  │  - needs_upload = 1                │     │
    |  └─────────────────────────────────────┘     │
    |            │                                  |
    |            │ (Sync Engine runs every 30s)     |
    |            ▼                                  │
    |  ┌─────────────────────────────────────┐     │
    |  │  upload_crdt_document()              │     │
    |  │  POST /api/v1/sync/crdt_upload       │     │
    |  └─────────────────────────────────────┘     │
    |            │                                  |
    |            │  HTTP POST with Bearer Token     │
    |            │  {doc_id, filename,             │────────────►
    |            │   automerge_state_b64,           │
    |            │   text_content, device_id,      │
    |            │   last_modified_at}             │
    |            │                                  |
    |            ▼                                  ▼
    |                                    ┌─────────────────────┐
    |                                    │  SyncController     │
    |                                    │  crdt_upload/1     │
    |                                    └─────────────────────┘
    |                                              │
    |                          ┌───────────────────┴───────────────────┐
    |                          │                                       │
    |                          ▼                                       ▼
    |              ┌─────────────────────┐               ┌─────────────────────┐
    |              │   AWS S3 Storage    │               │   sqld (LibSQL)    │
    |              │                     │               │                     │
    |              │  user/<user_id>/   │               │  documents table   │
    |              │    crdt/<doc_id>   │               │  - id               │
    |              │    .automerge      │               │  - user_id          │
    |              │                     │               │  - filename        │
    |              │  user/<user_id>/   │               │  - text_content    │
    |              │    documents/      │               │  - device_id       │
    |              │    <doc_id>/<filename>               │  - status          │
    |              │                     │               │                     │
    |              │  user/<user_id>/   │               │  UPSERT on conflict│
    |              │    metadata/       │               │                     │
    |              │    <doc_id>.json   │               │                     │
    |              └─────────────────────┘               └─────────────────────┘
```

### S3 Storage Structure
- `user/<user_id>/crdt/<doc_id>.automerge` - CRDT state
- `user/<user_id>/documents/<doc_id>/<filename>` - Text content
- `user/<user_id>/metadata/<doc_id>.json` - Document metadata

---

## 3. Bidirectional Sync Flow

### Sync Engine (Rust - Background Process)
```
rust
// Runs every 30 seconds
pub async fn start(app: AppHandle) {
    loop {
        match run_sync_cycle(&app).await {
            Ok(0)     => log::debug!("[CRDT Sync] Nothing to sync"),
            Ok(count) => log::info!("[CRDT Sync] ✅ Auto-synced {} document(s)", count),
            Err(e)    => log::warn!("[CRDT Sync] ❌ Cycle error: {}", e),
        }
        tokio::time::sleep(Duration::from_secs(30)).await;
    }
}
```

### Push Phase
1. Query local libsql: `SELECT * FROM documents WHERE needs_upload = 1`
2. For each pending document:
   - Base64 encode automerge_state
   - POST to `/api/v1/sync/crdt_upload` with Bearer token
   - On success: Update local DB `is_synced = 1, needs_upload = 0`
   - On failure: Set `status = 'failed'`

### Pull Phase
1. Query sqld: `SELECT * FROM documents WHERE user_id = ? AND updated_at > ?`
2. For each remote document:
   - Skip if device_id = current device (already have it)
   - If exists locally: Update if remote is newer
   - If new: Insert into local libsql

---

## 4. API Endpoints

### Authentication Endpoints
| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/v1/pleroma/captcha` | Get captcha challenge |
| POST | `/api/v1/apps` | Register OAuth app |
| POST | `/api/v1/account/register` | Register new user |
| POST | `/oauth/token` | Get access token |
| GET | `/api/v1/accounts/verify_credentials` | Verify token |
| DELETE | `/oauth/token` | Revoke token |

### DID Endpoints
| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/v1/did/generate` | Generate DID |
| POST | `/api/v1/did/validate` | Validate DID |
| GET | `/api/v1/did/:did/resolve` | Resolve DID |

### Sync Endpoints
| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/v1/sync/upload` | Upload document |
| POST | `/api/v1/sync/crdt_upload` | Upload CRDT state |
| GET | `/api/v1/sync/changes` | Get changes |
| POST | `/api/v1/sync/apply` | Apply changes |

---

## 5. Database Schema Relationships

### PostgreSQL (Phoenix Server)
```
oauth_apps
├── id (PK)
├── client_id
├── client_secret
├── name
├── redirect_uris
└── scopes

oauth_tokens
├── id (PK)
├── user_id (FK → users)
├── app_id (FK → oauth_apps)
├── token
├── scopes
├── valid_until
└── revoked_at

users
├── id (PK)
├── nickname
├── email
├── password_hash
├── did_id
├── is_active
├── is_admin
├── is_moderator
└── inserted_at

namespaces
├── id (PK)
├── user_id (FK → users)
├── namespace_key
├── tenant_id
└── config

documents
├── id (PK)
├── tenant_id
├── user_id (FK → users)
├── filename
├── object_key
├── content_hash
├── text_content
├── metadata
└── status
```

Desktop)
```
local_identity
### LibSQL (├── id (singleton)
├── server_url
├── did
├── access_token
├── user_id
└── last_sync_at

documents
├── id (PK)
├── filename
├── automerge_state (BLOB)
├── text_content
├── device_id
├── is_synced
├── needs_upload
├── status
├── created_at
└── last_synced_at
```

---

## 6. Key Data Transformations

| Stage | Data Format | Transformation |
|-------|-------------|----------------|
| User Registration | `params` (nickname, email, password) | → `User` schema → DB insert |
| DID Generation | `user_id` + random nonce | → SHA-256 hash → Base64URL → `did:przma:<fp>` |
| Namespace Key | DID | → First 16 chars of fingerprint |
| Document Upload | Binary content | → S3 object key: `user/<id>/documents/<doc_id>/<filename>` |
| CRDT State | Automerge binary | → Base64 encode → HTTP POST |
| sqld Sync | SQL `SELECT` | → HTTP JSON → Upsert local |

---

## 7. Technology Stack

### Backend (Phoenix/Elixir)
- **Web Framework:** Phoenix 1.7
- **Database:** PostgreSQL (main), sqld/LibSQL (sync)
- **Auth:** Pbkdf2 password hashing, OAuth tokens
- **Storage:** AWS S3 (Linode Objects)
- **Identifier:** DID (Decentralized Identifier)

### Desktop Client (Tauri/Rust)
- **Framework:** Tauri 2.0
- **Database:** libsql (embedded)
- **Sync:** CRDT with Automerge
- **Language:** Rust + TypeScript/React

---

This architecture enables:
- **Offline-first**: Documents work offline and sync when connected
- **Multi-device**: CRDTs allow seamless editing across devices
- **Decentralized**: DID-based identity without central authority
- **Tenant isolation**: Namespace keys isolate user data
