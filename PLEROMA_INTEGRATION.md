# Pleroma Integration Documentation

Complete guide for using Pleroma authentication and namespace integration in the ALEM application.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Setup and Configuration](#setup-and-configuration)
4. [Authentication Endpoints](#authentication-endpoints)
5. [Namespace Integration](#namespace-integration)
6. [API Reference](#api-reference)
7. [Usage Examples](#usage-examples)
8. [Testing](#testing)
9. [Troubleshooting](#troubleshooting)

---

## Overview

This application integrates with Pleroma, a federated social networking platform, to provide:

- **OAuth Authentication**: Users authenticate using Pleroma OAuth tokens
- **Namespace Management**: Each Pleroma account gets an isolated namespace
- **Data Synchronization**: Sync namespace documents with Pleroma
- **Account Association**: Link Pleroma accounts with application namespaces

### Key Features

- ✅ OAuth 2.0 token-based authentication
- ✅ Automatic namespace creation for Pleroma users
- ✅ Token verification with Pleroma API
- ✅ Namespace data synchronization
- ✅ Complete Swagger/OpenAPI documentation
- ✅ Local mock server for development

---

## Architecture

### Components

```
┌─────────────────┐
│   Client App    │
└────────┬────────┘
         │ OAuth Token
         ▼
┌─────────────────────────────────┐
│   ALEM Application              │
│                                 │
│  ┌──────────────────────────┐  │
│  │  AuthController          │  │  ──► Proxies to Pleroma API
│  │  - OAuth endpoints       │  │
│  │  - Account registration  │  │
│  └──────────────────────────┘  │
│                                 │
│  ┌──────────────────────────┐  │
│  │  NamespacePleromaController│ │  ──► Manages namespaces
│  │  - Create/get namespace  │  │
│  │  - Sync with Pleroma     │  │
│  └──────────────────────────┘  │
│                                 │
│  ┌──────────────────────────┐  │
│  │  PleromaIntegration       │  │  ──► Core integration logic
│  │  - Token verification     │  │
│  │  - Account association    │  │
│  └──────────────────────────┘  │
└────────┬─────────────────────────┘
         │
         ▼
┌─────────────────┐
│  Pleroma API    │
│  (or Mock)      │
└─────────────────┘
```

### Data Flow

1. **Authentication Flow**:
   ```
   Client → Register OAuth App → Get Token → Verify Token → Access Namespace
   ```

2. **Namespace Creation Flow**:
   ```
   Authenticated Request → Verify Token → Check Namespace → Create if Needed → Return Status
   ```

3. **Sync Flow**:
   ```
   Sync Request → Get Namespace Documents → Transform Data → Upload to Pleroma
   ```

---

## Setup and Configuration

### 1. Environment Configuration

The Pleroma base URL is configured in multiple places with the following precedence:

1. `PLEROMA_BASE_URL` environment variable (highest priority)
2. `config/dev.exs` for development
3. `config/runtime.exs` for runtime configuration
4. Default: `http://localhost:4001` (development) or `https://pleroma.social` (production)

#### Development Setup

```elixir
# config/dev.exs
config :alem, :pleroma, base_url: "http://localhost:4001"
```

#### Production Setup

```bash
# Set environment variable
export PLEROMA_BASE_URL=https://your-pleroma-instance.com
```

### 2. Local Mock Server

For development, a Pleroma mock server automatically starts on port 4001.

**Features:**
- Implements all Pleroma authentication endpoints
- Provides mock OAuth token verification
- Returns realistic mock data
- Automatically started in development mode

**Endpoints Available:**
- `POST /api/v1/apps` - OAuth app registration
- `POST /oauth/token` - OAuth token generation
- `POST /api/account/register` - Account registration
- `GET /api/v1/pleroma/captcha` - Captcha endpoint
- `GET /api/v1/accounts/verify_credentials` - Token verification
- And more...

### 3. Dependencies

The following dependencies are required (already included):

```elixir
# mix.exs
{:req, "~> 0.5"}          # HTTP client for Pleroma API calls
{:open_api_spex, "~> 3.18"} # Swagger documentation
```

---

## Authentication Endpoints

### 1. Register OAuth Application

Register a new OAuth application with Pleroma.

**Endpoint:** `POST /api/v1/apps`

**Request:**
```json
{
  "client_name": "My Application",
  "redirect_uris": "urn:ietf:wg:oauth:2.0:oob",
  "scopes": "read write follow push",
  "website": "https://example.com"
}
```

**Response:**
```json
{
  "id": "12345",
  "client_id": "abc123def456",
  "client_secret": "secret123",
  "name": "My Application",
  "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
  "vapid_key": null
}
```

### 2. Get OAuth Token

Obtain an OAuth access token using various grant types.

**Endpoint:** `POST /oauth/token`

**Request (Password Grant):**
```
grant_type=password
&client_id=abc123def456
&client_secret=secret123
&username=user@example.com
&password=password123
&scope=read write follow push
```

**Request (Authorization Code Grant):**
```
grant_type=authorization_code
&client_id=abc123def456
&client_secret=secret123
&code=auth_code_123
&redirect_uri=urn:ietf:wg:oauth:2.0:oob
```

**Response:**
```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "token_type": "Bearer",
  "scope": "read write follow push",
  "created_at": 1234567890
}
```

### 3. Register Account

Register a new user account with Pleroma.

**Endpoint:** `POST /api/account/register`

**Request:**
```json
{
  "nickname": "johndoe",
  "email": "john@example.com",
  "password": "securepassword123",
  "fullname": "John Doe",
  "bio": "Software developer",
  "captcha_solution": "ABCD1234",
  "captcha_token": "token123"
}
```

### 4. Get Captcha

Get a captcha challenge for account registration.

**Endpoint:** `GET /api/v1/pleroma/captcha`

**Response:**
```json
{
  "token": "captcha_token_123",
  "answer_data": "ABCD1234",
  "type": "image/png"
}
```

### 5. Account Management

**Delete Account:** `POST /api/pleroma/delete_account`
**Disable Account:** `POST /api/pleroma/disable_account`
**Get MFA Settings:** `GET /api/v1/pleroma/accounts/mfa`

---

## Namespace Integration

### Overview

The namespace integration automatically creates and manages isolated namespaces for each Pleroma user. Each namespace provides:

- Isolated data storage
- Service management
- Resource tracking
- Pleroma account association

### Key Concepts

- **User ID**: The Pleroma account ID is used as the namespace user_id
- **Tenant ID**: Defaults to "default" but can be customized
- **Token Verification**: All requests verify the OAuth token with Pleroma
- **Automatic Creation**: Namespaces are created automatically on first access

### Integration Module

The `Alem.Namespace.PleromaIntegration` module provides:

```elixir
# Create or get namespace for Pleroma account
PleromaIntegration.ensure_namespace_for_pleroma_account(account_id, oauth_token, opts)

# Get namespace for Pleroma account
PleromaIntegration.get_namespace_for_pleroma_account(account_id, oauth_token)

# Sync namespace with Pleroma
PleromaIntegration.sync_namespace_with_pleroma(user_id, oauth_token, opts)

# Get Pleroma account info
PleromaIntegration.get_pleroma_account_info(user_id)

# Update OAuth token
PleromaIntegration.update_pleroma_token(user_id, new_token)
```

---

## API Reference

### Namespace Endpoints

#### 1. Create or Get Namespace

**Endpoint:** `POST /api/namespaces/pleroma`

**Headers:**
```
Authorization: Bearer <oauth_token>
Content-Type: application/json
```

**Response:**
```json
{
  "namespace": {
    "user_id": "12345",
    "tenant_id": "default",
    "status": "healthy",
    "started_at": "2024-01-01T00:00:00Z",
    "pleroma_account": {
      "id": "12345",
      "username": "test_user",
      "acct": "test_user@localhost",
      "display_name": "Test User"
    }
  }
}
```

#### 2. Get Namespace

**Endpoint:** `GET /api/namespaces/pleroma`

**Headers:**
```
Authorization: Bearer <oauth_token>
```

**Response:**
```json
{
  "namespace": {
    "user_id": "12345",
    "tenant_id": "default",
    "status": "healthy",
    "started_at": "2024-01-01T00:00:00Z",
    "services": [
      {
        "name": "data_router",
        "pid": "#PID<0.123.0>",
        "alive": true,
        "node": "node@localhost"
      }
    ],
    "resource_usage": {
      "documents": 42,
      "storage_bytes": 1048576
    },
    "pleroma_account": {
      "id": "12345",
      "username": "test_user",
      "acct": "test_user@localhost",
      "display_name": "Test User"
    }
  }
}
```

#### 3. Sync Namespace with Pleroma

**Endpoint:** `POST /api/namespaces/pleroma/sync`

**Headers:**
```
Authorization: Bearer <oauth_token>
Content-Type: application/json
```

**Request Body (Optional):**
```json
{
  "sync_mode": "metadata_only"
}
```

**Sync Modes:**
- `metadata_only`: Sync only document metadata
- `full`: Full sync including document content as Pleroma posts

**Response:**
```json
{
  "message": "Sync completed",
  "result": {
    "synced_count": 42,
    "mode": "metadata_only"
  }
}
```

#### 4. Get Pleroma Account Info

**Endpoint:** `GET /api/namespaces/pleroma/account`

**Headers:**
```
Authorization: Bearer <oauth_token>
```

**Response:**
```json
{
  "account": {
    "id": "12345",
    "username": "test_user",
    "acct": "test_user@localhost",
    "display_name": "Test User",
    "note": "Test account for namespace integration",
    "avatar": "",
    "locked": false,
    "bot": false,
    "created_at": "2024-01-01T00:00:00Z"
  }
}
```

---

## Usage Examples

### Complete Authentication Flow

```bash
# 1. Register OAuth Application
curl -X POST http://localhost:4000/api/v1/apps \
  -H "Content-Type: application/json" \
  -d '{
    "client_name": "My App",
    "redirect_uris": "urn:ietf:wg:oauth:2.0:oob",
    "scopes": "read write follow push"
  }'

# Response contains client_id and client_secret
CLIENT_ID="abc123def456"
CLIENT_SECRET="secret123"

# 2. Get OAuth Token (Password Grant)
curl -X POST http://localhost:4000/oauth/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" \
  -d "username=user@example.com" \
  -d "password=password123" \
  -d "scope=read write follow push"

# Response contains access_token
TOKEN="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."

# 3. Create or Get Namespace
curl -X POST http://localhost:4000/api/namespaces/pleroma \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json"

# 4. Get Namespace Status
curl -X GET http://localhost:4000/api/namespaces/pleroma \
  -H "Authorization: Bearer $TOKEN"

# 5. Sync with Pleroma
curl -X POST http://localhost:4000/api/namespaces/pleroma/sync \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"sync_mode": "metadata_only"}'
```

### Elixir Code Example

```elixir
# In your application code
alias Alem.Namespace.PleromaIntegration

# Get OAuth token from user
oauth_token = get_user_oauth_token()

# Ensure namespace exists for Pleroma account
case PleromaIntegration.ensure_namespace_for_pleroma_account("account_id", oauth_token) do
  {:ok, user_id, account_info} ->
    # Namespace is ready to use
    IO.puts("Namespace created for user: #{user_id}")
    IO.inspect(account_info)
  
  {:error, :invalid_token} ->
    IO.puts("Invalid OAuth token")
  
  {:error, reason} ->
    IO.puts("Error: #{inspect(reason)}")
end

# Sync namespace documents
case PleromaIntegration.sync_namespace_with_pleroma(user_id, oauth_token, sync_mode: :metadata_only) do
  {:ok, result} ->
    IO.puts("Synced #{result.synced_count} documents")
  
  {:error, reason} ->
    IO.puts("Sync failed: #{inspect(reason)}")
end
```

### JavaScript/TypeScript Example

```javascript
// Register OAuth app
const appResponse = await fetch('http://localhost:4000/api/v1/apps', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    client_name: 'My App',
    redirect_uris: 'urn:ietf:wg:oauth:2.0:oob',
    scopes: 'read write follow push'
  })
});
const app = await appResponse.json();

// Get OAuth token
const tokenResponse = await fetch('http://localhost:4000/oauth/token', {
  method: 'POST',
  headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  body: new URLSearchParams({
    grant_type: 'password',
    client_id: app.client_id,
    client_secret: app.client_secret,
    username: 'user@example.com',
    password: 'password123',
    scope: 'read write follow push'
  })
});
const tokenData = await tokenResponse.json();
const accessToken = tokenData.access_token;

// Create/get namespace
const namespaceResponse = await fetch('http://localhost:4000/api/namespaces/pleroma', {
  method: 'POST',
  headers: {
    'Authorization': `Bearer ${accessToken}`,
    'Content-Type': 'application/json'
  }
});
const namespace = await namespaceResponse.json();
console.log('Namespace:', namespace);
```

---

## Testing

### Using the Mock Server

The local mock server automatically starts in development mode and provides:

- Mock OAuth token generation
- Mock account verification
- Realistic response data
- All Pleroma endpoints implemented

### Testing Authentication

```bash
# Test OAuth app registration
curl -X POST http://localhost:4000/api/v1/apps \
  -H "Content-Type: application/json" \
  -d '{"client_name": "Test App"}'

# Test token generation
curl -X POST http://localhost:4000/oauth/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&username=test&password=test"
```

### Testing Namespace Integration

```bash
# Get a mock token (from mock server)
TOKEN="mock_token_123"

# Test namespace creation
curl -X POST http://localhost:4000/api/namespaces/pleroma \
  -H "Authorization: Bearer $TOKEN"

# Test namespace retrieval
curl -X GET http://localhost:4000/api/namespaces/pleroma \
  -H "Authorization: Bearer $TOKEN"
```

### Swagger UI Testing

1. Start the server: `mix phx.server`
2. Open Swagger UI: `http://localhost:4000/api/swagger`
3. Click "Authorize" and enter your Bearer token
4. Test endpoints directly from the UI

---

## Troubleshooting

### Common Issues

#### 1. 404 Errors from Pleroma API

**Problem:** Getting 404 errors when calling Pleroma endpoints.

**Solutions:**
- Check that `PLEROMA_BASE_URL` is set correctly
- Verify the Pleroma instance is running and accessible
- In development, ensure the mock server is running on port 4001
- Check server logs for the actual URL being called

#### 2. Invalid Token Errors

**Problem:** Getting "Invalid Pleroma OAuth token" errors.

**Solutions:**
- Verify the token is valid and not expired
- Check that the token format is correct: `Bearer <token>`
- Ensure the Pleroma instance can verify the token
- Check that the token has the required scopes

#### 3. Namespace Not Found

**Problem:** Namespace doesn't exist for a Pleroma account.

**Solutions:**
- Use `POST /api/namespaces/pleroma` to create the namespace
- Verify the account ID matches the Pleroma account
- Check that the namespace was created successfully in logs

#### 4. Mock Server Not Starting

**Problem:** Mock server doesn't start automatically.

**Solutions:**
- Ensure `dev_routes` is enabled in `config/dev.exs`
- Check that port 4001 is not already in use
- Restart the Phoenix server
- Check logs for startup errors

### Debugging

Enable detailed logging:

```elixir
# In config/dev.exs
config :logger, level: :debug
```

Check logs for:
- Pleroma API calls: `Calling Pleroma API: ...`
- Token verification: `Pleroma token verified for account: ...`
- Namespace creation: `Starting namespace manager`
- Errors: `Pleroma API error: ...`

### Configuration Verification

```elixir
# In IEx console
iex> Application.get_env(:alem, :pleroma)
[base_url: "http://localhost:4001"]

iex> System.get_env("PLEROMA_BASE_URL")
nil  # or your configured URL
```

---

## File Structure

```
lib/
├── alem/
│   └── namespace/
│       ├── pleroma_integration.ex    # Core integration logic
│       ├── namespace.ex               # Namespace API
│       └── manager.ex                 # Namespace manager
│
├── alem_web/
│   ├── controllers/
│   │   ├── auth_controller.ex         # Pleroma auth endpoints
│   │   └── namespace_pleroma_controller.ex  # Namespace endpoints
│   └── swagger.ex                     # API documentation
│
└── pleroma_mock_server.ex            # Development mock server

config/
├── config.exs                         # Base configuration
├── dev.exs                            # Development config
└── runtime.exs                        # Runtime config
```

---

## Security Considerations

1. **Token Storage**: Never store OAuth tokens in plain text. Use secure storage.
2. **Token Validation**: Always verify tokens with Pleroma before use.
3. **HTTPS**: Use HTTPS in production for all API calls.
4. **Scope Limitation**: Request only necessary OAuth scopes.
5. **Token Expiration**: Handle token expiration gracefully.
6. **Rate Limiting**: Implement rate limiting for API endpoints.

---

## API Documentation

Complete API documentation is available via Swagger UI:

- **URL**: `http://localhost:4000/api/swagger`
- **OpenAPI Spec**: `http://localhost:4000/api/swagger/openapi.json`

The Swagger UI provides:
- Interactive API testing
- Request/response examples
- Schema definitions
- Authentication support

---

## Additional Resources

- [Pleroma API Documentation](https://api.pleroma.social/)
- [OAuth 2.0 Specification](https://oauth.net/2/)
- [OpenAPI Specification](https://swagger.io/specification/)

---

## Support

For issues or questions:
1. Check the troubleshooting section
2. Review server logs
3. Test with the mock server first
4. Verify configuration settings

---

**Last Updated**: 2024-02-11
**Version**: 1.0.0

