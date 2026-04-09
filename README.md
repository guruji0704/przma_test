# Alem

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix


# Code Structure Documentation

## Overview

This document describes the improved code structure of the ALEM application with proper separation of concerns, reusable components, and comprehensive API documentation.

## Directory Structure

```
lib/
├── alem/                          # Core business logic
│   ├── application.ex            # Application supervisor
│   ├── repo.ex                   # Ecto repository
│   ├── mailer.ex                 # Email functionality
│   │
│   ├── identity/                  # Identity management
│   │   ├── did.ex                # DID generation, validation, resolution
│   │   └── resolver.ex           # Identity resolution utilities
│   │
│   ├── namespace/                # Namespace management
│   │   ├── namespace.ex          # Public namespace API
│   │   ├── manager.ex            # Namespace GenServer manager
│   │   ├── data_router.ex        # Document routing and storage
│   │   ├── registry.ex           # Service registry
│   │   ├── supervisor.ex         # Namespace supervisor
│   │   └── pleroma_integration.ex # Pleroma integration
│   │
│   ├── schemas/                  # Database schemas
│   │   ├── namespace.ex          # Namespace schema
│   │   └── document.ex           # Document schema
│   │
│   └── storage/                  # Storage backends
│       ├── object_store.ex       # S3/Linode object storage
│       ├── document_store.ex     # CouchDB document storage
│       └── relational_store.ex   # PostgreSQL relational storage
│
└── alem_web/                      # Web layer (Phoenix)
    ├── endpoint.ex               # Phoenix endpoint
    ├── router.ex                 # Route definitions
    ├── swagger.ex                # OpenAPI/Swagger documentation
    │
    ├── plugs/                    # Reusable plugs
    │   └── pleroma_auth.ex       # Pleroma OAuth authentication plug
    │
    ├── controllers/              # HTTP controllers
    │   ├── auth_controller.ex    # Pleroma authentication endpoints
    │   ├── did_controller.ex     # DID management endpoints
    │   ├── identity_controller.ex # Identity resolution endpoints
    │   ├── namespace_controller.ex # Namespace management
    │   └── namespace_pleroma_controller.ex # Pleroma namespace integration
    │
    └── components/               # UI components
        ├── core_components.ex    # Reusable UI components
        └── layouts/              # Layout templates
```

## Key Improvements

### 1. Authentication Plug (`AlemWeb.Plugs.PleromaAuth`)

**Purpose**: Centralized authentication logic to avoid code duplication

**Benefits**:
- Single source of truth for token verification
- Consistent error handling
- Reusable across all controllers
- Cleaner controller code

**Usage**:
```elixir
defmodule AlemWeb.NamespacePleromaController do
  use AlemWeb, :controller
  
  plug AlemWeb.Plugs.PleromaAuth  # Add authentication
  
  def create_or_get(conn, _params) do
    # Access authenticated user via conn.assigns
    token = conn.assigns.pleroma_token
    account_info = conn.assigns.pleroma_account
    account_id = conn.assigns.pleroma_account_id
    # ...
  end
end
```

### 2. DID Controller (`AlemWeb.DIDController`)

**Endpoints**:
- `POST /api/v1/did/generate` - Generate a new DID
- `POST /api/v1/did/validate` - Validate a DID format
- `GET /api/v1/did/:did/resolve` - Resolve DID to DID document
- `GET /api/v1/did/:did` - Get DID information

**Purpose**: Manage Decentralized Identifiers independently

### 3. Identity Controller (`AlemWeb.IdentityController`)

**Endpoints**:
- `GET /api/v1/identity/resolve/:identifier` - Resolve any identifier to namespace
- `POST /api/v1/identity/compare` - Compare two identifiers
- `GET /api/v1/identity/:identifier/identifiers` - Get all identifiers for a namespace

**Purpose**: Unified identity resolution across DID, Pleroma ID, and namespace ID

### 4. Refactored Namespace Controller

**Before**: Duplicated authentication logic in every action
**After**: Uses `PleromaAuth` plug, cleaner and more maintainable

## API Endpoints

### Authentication & Pleroma
- `POST /api/v1/apps` - Register OAuth application
- `POST /api/v1/oauth/token` - Get OAuth token
- `POST /api/v1/account/register` - Register Pleroma account
- `GET /api/v1/pleroma/captcha` - Get captcha
- `POST /api/v1/pleroma/delete_account` - Delete account
- `POST /api/v1/pleroma/disable_account` - Disable account
- `GET /api/v1/pleroma/accounts/mfa` - Get MFA settings

### DID Management
- `POST /api/v1/did/generate` - Generate new DID
- `POST /api/v1/did/validate` - Validate DID format
- `GET /api/v1/did/:did/resolve` - Resolve DID to document
- `GET /api/v1/did/:did` - Get DID information

### Identity Resolution
- `GET /api/v1/identity/resolve/:identifier` - Resolve identifier to namespace
- `POST /api/v1/identity/compare` - Compare two identifiers
- `GET /api/v1/identity/:identifier/identifiers` - Get all identifiers

### Namespace Management (Requires Authentication)
- `POST /api/v1/namespaces` - Create/get namespace
- `GET /api/v1/namespaces` - Get namespace status
- `POST /api/v1/namespaces/sync` - Sync namespace
- `GET /api/v1/namespaces/account` - Get account info

## Swagger Documentation

All endpoints are fully documented in Swagger/OpenAPI:

- **Swagger UI**: `http://localhost:4000/api/swagger`
- **OpenAPI JSON**: `http://localhost:4000/api/swagger/openapi.json`

### Features:
- Complete request/response schemas
- Authentication requirements
- Example values
- Error responses
- Tagged by category (DID, Identity, Namespace, etc.)

## Code Organization Principles

### 1. Separation of Concerns
- **Business Logic** (`lib/alem/`) - Pure Elixir modules, no web dependencies
- **Web Layer** (`lib/alem_web/`) - Phoenix controllers, plugs, routing

### 2. DRY (Don't Repeat Yourself)
- Authentication logic extracted to plug
- Common patterns reused
- Shared utilities in dedicated modules

### 3. Single Responsibility
- Each controller handles one resource
- Each module has a clear purpose
- Functions are focused and small

### 4. Testability
- Business logic separated from web layer
- Plugs can be tested independently
- Controllers are thin and delegate to business logic

## Migration Guide

### For Existing Code

If you have existing code that manually extracts tokens:

**Before**:
```elixir
def my_action(conn, _params) do
  auth_header = Plug.Conn.get_req_header(conn, "authorization")
  case extract_token(auth_header) do
    nil -> # handle error
    token -> # use token
  end
end
```

**After**:
```elixir
plug AlemWeb.Plugs.PleromaAuth

def my_action(conn, _params) do
  token = conn.assigns.pleroma_token
  account_info = conn.assigns.pleroma_account
  # use token and account_info
end
```

## Testing

### Testing Plugs
```elixir
test "PleromaAuth plug verifies token" do
  conn = 
    build_conn()
    |> put_req_header("authorization", "Bearer valid_token")
    |> AlemWeb.Plugs.PleromaAuth.call([])
  
  assert conn.assigns.pleroma_token == "valid_token"
end
```

### Testing Controllers
```elixir
test "DID generation" do
  conn = post(conn, "/api/v1/did/generate", %{method: "key"})
  assert %{"did" => did} = json_response(conn, 200)
  assert String.starts_with?(did, "did:key:")
end
```

## Best Practices

1. **Always use the auth plug** for protected endpoints
2. **Keep controllers thin** - delegate to business logic modules
3. **Use Swagger** - document all endpoints
4. **Follow naming conventions** - controllers end with `Controller`, plugs end with plug name
5. **Error handling** - Use consistent error response format

## Future Improvements

1. **Rate Limiting Plug** - Add rate limiting to prevent abuse
2. **CORS Configuration** - Proper CORS setup for web clients
3. **API Versioning** - Add versioning (e.g., `/api/v1/`, `/api/v2/`)
4. **Request Validation** - Add schema validation for requests
5. **Response Caching** - Add caching for frequently accessed data

---

**Last Updated**: 2026-02-16
**Version**: 2.0.0

