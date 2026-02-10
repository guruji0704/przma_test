# Pleroma Integration - Quick Start Guide

A quick reference guide for developers to get started with Pleroma integration.

## Prerequisites

- Phoenix application running
- Pleroma instance (or mock server for development)
- OAuth application registered with Pleroma

## Quick Setup

### 1. Configuration

```bash
# Development (uses local mock server automatically)
# No configuration needed - mock server starts on port 4001

# Production
export PLEROMA_BASE_URL=https://your-pleroma-instance.com
```

### 2. Get OAuth Token

```bash
# Register OAuth app
curl -X POST http://localhost:4000/api/v1/apps \
  -H "Content-Type: application/json" \
  -d '{"client_name": "My App"}'

# Get token (password grant)
curl -X POST http://localhost:4000/oauth/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password&username=user&password=pass&client_id=xxx&client_secret=yyy"
```

### 3. Use Namespace

```bash
# Set your token
TOKEN="your_oauth_token"

# Create/get namespace
curl -X POST http://localhost:4000/api/namespaces/pleroma \
  -H "Authorization: Bearer $TOKEN"

# Get namespace status
curl -X GET http://localhost:4000/api/namespaces/pleroma \
  -H "Authorization: Bearer $TOKEN"
```

## Endpoints Cheat Sheet

### Authentication
- `POST /api/v1/apps` - Register OAuth app
- `POST /oauth/token` - Get OAuth token
- `POST /api/account/register` - Register account
- `GET /api/v1/pleroma/captcha` - Get captcha

### Namespaces
- `POST /api/namespaces/pleroma` - Create/get namespace
- `GET /api/namespaces/pleroma` - Get namespace
- `POST /api/namespaces/pleroma/sync` - Sync with Pleroma
- `GET /api/namespaces/pleroma/account` - Get account info

## Code Examples

### Elixir

```elixir
alias Alem.Namespace.PleromaIntegration

# Create namespace
{:ok, user_id, account} = 
  PleromaIntegration.ensure_namespace_for_pleroma_account("account_id", token)

# Sync
{:ok, result} = 
  PleromaIntegration.sync_namespace_with_pleroma(user_id, token, sync_mode: :metadata_only)
```

### JavaScript

```javascript
// Get namespace
const response = await fetch('http://localhost:4000/api/namespaces/pleroma', {
  headers: { 'Authorization': `Bearer ${token}` }
});
const namespace = await response.json();
```

## Testing

1. Start server: `mix phx.server`
2. Open Swagger: `http://localhost:4000/api/swagger`
3. Click "Authorize" → Enter token
4. Test endpoints

## Common Commands

```bash
# Check configuration
iex> Application.get_env(:alem, :pleroma)

# Test mock server
curl http://localhost:4001/

# Verify token
curl http://localhost:4001/api/v1/accounts/verify_credentials \
  -H "Authorization: Bearer $TOKEN"
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| 404 errors | Check `PLEROMA_BASE_URL` config |
| Invalid token | Verify token with Pleroma API |
| Namespace not found | Use POST to create namespace |
| Mock server not starting | Check `dev_routes` in config |

## Full Documentation

See [PLEROMA_INTEGRATION.md](./PLEROMA_INTEGRATION.md) for complete documentation.

