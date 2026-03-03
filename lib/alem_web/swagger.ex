defmodule AlemWeb.Swagger do
  @moduledoc "OpenAPI/Swagger specification for PRZMA/ALEM API"

  alias OpenApiSpex.{Components, Info, OpenApi, Reference, Schema, Server}

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "PRZMA / ALEM API",
        version: "1.0.0",
        description: """
        ALEM — Multi-tenant Document Management & Perception Intelligence Platform

        ## Authentication Flow
        1. `GET /api/v1/pleroma/captcha` — get captcha challenge
        2. `POST /api/v1/apps` — register OAuth app, get client_id/client_secret
        3. `POST /api/v1/account/register` — register user (DID auto-generated)
        4. `POST /api/v1/oauth/token` — login, get Bearer token (a session is also created)
        5. `GET /api/v1/accounts/verify_credentials` — verify token
        6. `GET /api/v1/accounts/did` — get your Decentralized Identifier

        ## Session Management
        Each login automatically creates a session record (device, IP, browser).
        - `GET /api/v1/sessions` — list all active sessions
        - `DELETE /api/v1/sessions/:id` — logout from one specific device
        - `DELETE /api/v1/sessions/all` — logout from every device immediately

        ## DID (Decentralized Identifier)
        Every user gets exactly **one** DID at registration. Format: `did:przma:<sha256-fingerprint>`
        The DID is the root identity used to create and isolate namespaces.
        """
      },
      servers: [
        %Server{url: "http://localhost:4000", description: "Development"}
      ],
      paths: %{
        # ── Captcha ─────────────────────────────────────────
        "/api/v1/pleroma/captcha" => %OpenApiSpex.PathItem{
          get: op("Get Captcha", "Authentication", "get_captcha",
            "Get a captcha challenge (token + answer). Use token+solution when registering.",
            %{200 => resp("Captcha", "CaptchaResponse"),
              500 => resp("Error",   "ErrorResponse")})
        },

        # ── OAuth App ────────────────────────────────────────
        "/api/v1/apps" => %OpenApiSpex.PathItem{
          post: op_body("Register OAuth App", "Authentication", "register_app",
            "Register a new OAuth application. Returns client_id and client_secret.",
            "RegisterAppRequest",
            %{200 => resp("App registered",  "RegisterAppResponse"),
              422 => resp("Validation error", "ErrorResponse")})
        },

        # ── Register ─────────────────────────────────────────
        "/api/v1/account/register" => %OpenApiSpex.PathItem{
          post: op_body("Register Account", "Authentication", "register_account",
            "Create a new user account. A DID (did:przma:...) is automatically generated and stored.",
            "RegisterAccountRequest",
            %{200 => resp("Account created", "AccountResponse"),
              400 => resp("Bad request",      "ErrorResponse")})
        },

        # ── OAuth Token ──────────────────────────────────────
        "/api/v1/oauth/token" => %OpenApiSpex.PathItem{
          post: op_body("Login / Get Token", "Authentication", "get_oauth_token",
            """
            Login with nickname + password.

            On success:
            - Returns `access_token` (Bearer) and `did`
            - Automatically creates a **session record** tracking your IP and device

            After login, use the `access_token` in the Authorization header:
            `Authorization: Bearer <access_token>`
            """,
            "OAuthTokenRequest",
            %{200 => resp("Token + DID",    "OAuthTokenResponse"),
              401 => resp("Unauthorized",    "ErrorResponse"),
              400 => resp("Bad grant type",  "ErrorResponse")})
        },

        # ── Verify Credentials ───────────────────────────────
        "/api/v1/accounts/verify_credentials" => %OpenApiSpex.PathItem{
          get: op_auth("Verify Credentials", "Authentication", "verify_credentials",
            "Verify your Bearer token. Returns account info including DID.",
            %{200 => resp("Account info", "AccountResponse"),
              401 => resp("Unauthorized",  "ErrorResponse")})
        },

        # ── DID ──────────────────────────────────────────────
        "/api/v1/accounts/did" => %OpenApiSpex.PathItem{
          get: op_auth("Get My DID", "DID", "get_did",
            """
            Get the authenticated user's Decentralized Identifier (DID).

            Format: `did:przma:<sha256-base64url-fingerprint>`

            The DID is:
            - Generated once at registration — never changes
            - Globally unique (cryptographic hash of user_id + random nonce + timestamp)
            - The root identity for namespace creation
            """,
            %{200 => resp("DID info",    "DIDResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        # ── Sessions ─────────────────────────────────────────
        "/api/v1/sessions" => %OpenApiSpex.PathItem{
          get: op_auth("List Active Sessions", "Sessions", "list_sessions",
            """
            Get all active login sessions for your account.

            Each session shows:
            - `id` — use this to revoke a specific session
            - `device` — desktop / mobile / tablet / api_client / unknown
            - `ip_address` — IP address that was used to log in
            - `user_agent` — browser or app identifier
            - `last_active_at` — most recent activity time
            - `created_at` — when you logged in from this device
            """,
            %{200 => resp("Sessions list", "SessionsResponse"),
              401 => resp("Unauthorized",   "ErrorResponse")}),

          delete: op_auth("Logout From All Devices", "Sessions", "revoke_all_sessions",
            """
            Immediately revoke ALL active sessions and tokens across every device.

            Use this if you suspect your account has been compromised.
            You will need to log in again on all devices after this.
            """,
            %{200 => resp("All sessions revoked", "MessageResponse"),
              401 => resp("Unauthorized",           "ErrorResponse")})
        },

        "/api/v1/sessions/{id}" => %OpenApiSpex.PathItem{
          delete: op_auth_param("Revoke Session by ID", "Sessions", "revoke_session",
            """
            Logout from one specific device by session ID.

            Get the `id` from `GET /api/v1/sessions`.
            Only the session belonging to the authenticated user can be revoked.
            All other sessions remain active.
            """,
            [session_id_param()],
            %{200 => resp("Session revoked", "MessageResponse"),
              404 => resp("Not found",        "ErrorResponse"),
              401 => resp("Unauthorized",     "ErrorResponse")})
        },

        # ── Revoke Token ─────────────────────────────────────
        "/oauth/token/revoke" => %OpenApiSpex.PathItem{
          delete: op_auth("Logout (Revoke Token)", "Authentication", "revoke_token",
            "Revoke the current Bearer token. The token will return 401 after this.",
            %{200 => resp("Revoked",   "MessageResponse"),
              404 => resp("Not found", "ErrorResponse")})
        },

        # ── Delete Account ───────────────────────────────────
        "/api/v1/pleroma/delete_account" => %OpenApiSpex.PathItem{
          post: op_auth_body("Delete Account", "Authentication", "delete_account",
            "Delete account (requires password). Revokes all tokens and sessions.",
            "PasswordConfirmRequest",
            %{200 => resp("Deleted",       "StatusResponse"),
              401 => resp("Unauthorized",   "ErrorResponse"),
              403 => resp("Wrong password", "ErrorResponse")})
        },

        # ── Disable Account ──────────────────────────────────
        "/api/v1/pleroma/disable_account" => %OpenApiSpex.PathItem{
          post: op_auth_body("Disable Account", "Authentication", "disable_account",
            "Disable account (requires password). Revokes all tokens and sessions.",
            "PasswordConfirmRequest",
            %{200 => resp("Disabled",      "StatusResponse"),
              401 => resp("Unauthorized",   "ErrorResponse"),
              403 => resp("Wrong password", "ErrorResponse")})
        },

        # ── Namespace ────────────────────────────────────────
        "/api/v1/namespaces" => %OpenApiSpex.PathItem{
          post: op_auth("Create/Get Namespace", "Namespace", "create_or_get_namespace",
            "Create or retrieve the namespace for the authenticated user (keyed by DID).",
            %{200 => resp("Namespace", "NamespaceResponse"),
              401 => resp("Unauthorized", "ErrorResponse")}),
          get: op_auth("Get Namespace", "Namespace", "get_namespace",
            "Get namespace status for the authenticated user.",
            %{200 => resp("Namespace", "NamespaceResponse"),
              404 => resp("Not found",  "ErrorResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        "/api/v1/namespaces/account" => %OpenApiSpex.PathItem{
          get: op_auth("Get Account in Namespace", "Namespace", "get_namespace_account",
            "Get account info stored in the authenticated user's namespace.",
            %{200 => resp("Account",     "AccountResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        }
      },
      components: %Components{
        schemas: %{
          # ── Request schemas ────────────────────────────────
          "RegisterAppRequest"     => register_app_request_schema(),
          "OAuthTokenRequest"      => oauth_token_request_schema(),
          "RegisterAccountRequest" => register_account_request_schema(),
          "PasswordConfirmRequest" => password_confirm_schema(),

          # ── Response schemas ───────────────────────────────
          "RegisterAppResponse"    => register_app_response_schema(),
          "OAuthTokenResponse"     => oauth_token_response_schema(),
          "AccountResponse"        => account_response_schema(),
          "CaptchaResponse"        => captcha_response_schema(),
          "DIDResponse"            => did_response_schema(),
          "SessionsResponse"       => sessions_response_schema(),
          "SessionObject"          => session_object_schema(),
          "NamespaceResponse"      => namespace_response_schema(),
          "ErrorResponse"          => error_response_schema(),
          "MessageResponse"        => message_response_schema(),
          "StatusResponse"         => status_response_schema()
        },
        securitySchemes: %{
          "BearerAuth" => %OpenApiSpex.SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: "OAuth Bearer token. Obtain from POST /api/v1/oauth/token"
          }
        }
      }
    }
  end

  # ===========================================================================
  # Schema definitions
  # ===========================================================================

  defp register_app_request_schema do
    %Schema{
      type: :object, title: "RegisterAppRequest",
      required: [:client_name],
      properties: %{
        client_name:   %Schema{type: :string, example: "My PRZMA App"},
        redirect_uris: %Schema{type: :string, example: "urn:ietf:wg:oauth:2.0:oob"},
        scopes:        %Schema{type: :string, example: "read write", default: "read write"},
        website:       %Schema{type: :string, example: "https://example.com"}
      }
    }
  end

  defp register_app_response_schema do
    %Schema{
      type: :object, title: "RegisterAppResponse",
      properties: %{
        id:            %Schema{type: :string, example: "K7mF2xQ9rP..."},
        name:          %Schema{type: :string, example: "My PRZMA App"},
        client_id:     %Schema{type: :string, example: "K7mF2xQ9rP..."},
        client_secret: %Schema{type: :string, example: "abc123..."},
        redirect_uri:  %Schema{type: :string, example: "urn:ietf:wg:oauth:2.0:oob"},
        vapid_key:     %Schema{type: :string, nullable: true}
      }
    }
  end

  defp oauth_token_request_schema do
    %Schema{
      type: :object, title: "OAuthTokenRequest",
      required: [:grant_type],
      properties: %{
        grant_type:    %Schema{type: :string, enum: ["password", "client_credentials"], example: "password"},
        username:      %Schema{type: :string, description: "Your nickname", example: "johndoe"},
        password:      %Schema{type: :string, format: :password, example: "securepassword123"},
        client_id:     %Schema{type: :string, example: "K7mF2xQ9rP..."},
        client_secret: %Schema{type: :string, example: "abc123..."},
        scope:         %Schema{type: :string, example: "read write"}
      }
    }
  end

  defp oauth_token_response_schema do
    %Schema{
      type: :object, title: "OAuthTokenResponse",
      description: "Login response. Includes access_token, DID, and creates a session record.",
      properties: %{
        access_token:  %Schema{type: :string, example: "a-GvXrUzM9Fv..."},
        token_type:    %Schema{type: :string, example: "Bearer"},
        scope:         %Schema{type: :string, example: "read write"},
        expires_in:    %Schema{type: :integer, example: 2592000},
        refresh_token: %Schema{type: :string, example: "refresh_abc123..."},
        me:            %Schema{type: :string, description: "Your nickname", example: "johndoe"},
        did:           %Schema{
          type: :string,
          description: "Your Decentralized Identifier",
          example: "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"
        },
        created_at: %Schema{type: :integer, example: 1740614645}
      }
    }
  end

  defp register_account_request_schema do
    %Schema{
      type: :object, title: "RegisterAccountRequest",
      required: [:nickname, :email, :password],
      properties: %{
        nickname:         %Schema{type: :string, example: "johndoe"},
        email:            %Schema{type: :string, format: :email, example: "john@example.com"},
        password:         %Schema{type: :string, format: :password, example: "securepassword123"},
        fullname:         %Schema{type: :string, example: "John Doe"},
        bio:              %Schema{type: :string, example: "Software developer"},
        captcha_token:    %Schema{type: :string, description: "Token from GET /api/v1/pleroma/captcha"},
        captcha_solution: %Schema{type: :string, description: "Answer from the captcha challenge"}
      }
    }
  end

  defp account_response_schema do
    %Schema{
      type: :object, title: "AccountResponse",
      properties: %{
        id:           %Schema{type: :string, example: "mK92pqRtYuIoplKj"},
        username:     %Schema{type: :string, example: "johndoe"},
        acct:         %Schema{type: :string, example: "johndoe"},
        display_name: %Schema{type: :string, example: "John Doe"},
        note:         %Schema{type: :string, example: "Software developer"},
        avatar:       %Schema{type: :string, example: ""},
        created_at:   %Schema{type: :string, example: "2026-02-27T00:00:00Z"},
        did:          %Schema{type: :string, example: "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"},
        pleroma: %Schema{
          type: :object,
          properties: %{
            is_admin:     %Schema{type: :boolean},
            is_moderator: %Schema{type: :boolean},
            is_active:    %Schema{type: :boolean}
          }
        }
      }
    }
  end

  defp captcha_response_schema do
    %Schema{
      type: :object, title: "CaptchaResponse",
      properties: %{
        type:          %Schema{type: :string, example: "image"},
        token:         %Schema{type: :string, example: "oU-MJtbyHv..."},
        answer_data:   %Schema{type: :string, example: "A8F3K2"},
        seconds_valid: %Schema{type: :integer, example: 300}
      }
    }
  end

  defp did_response_schema do
    %Schema{
      type: :object, title: "DIDResponse",
      properties: %{
        user_id:       %Schema{type: :string, example: "mK92pqRtYuIoplKj"},
        nickname:      %Schema{type: :string, example: "johndoe"},
        did:           %Schema{type: :string, example: "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"},
        did_method:    %Schema{type: :string, example: "przma"},
        fingerprint:   %Schema{type: :string, example: "K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"},
        namespace_key: %Schema{type: :string, example: "k7mf2xq9rpvn3wlt"},
        description:   %Schema{type: :string}
      }
    }
  end

  defp sessions_response_schema do
    %Schema{
      type: :object, title: "SessionsResponse",
      description: "All active sessions for the authenticated user",
      properties: %{
        sessions: %Schema{
          type: :array,
          items: %Reference{"$ref": "#/components/schemas/SessionObject"}
        }
      },
      example: %{
        sessions: [
          %{
            id:             "abc123xyz",
            device:         "desktop",
            ip_address:     "192.168.1.1",
            user_agent:     "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
            last_active_at: "2026-03-03T10:30:00",
            created_at:     "2026-03-03T09:00:00"
          },
          %{
            id:             "def456uvw",
            device:         "mobile",
            ip_address:     "10.0.0.5",
            user_agent:     "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0)",
            last_active_at: "2026-03-02T20:00:00",
            created_at:     "2026-03-02T18:00:00"
          }
        ]
      }
    }
  end

  defp session_object_schema do
    %Schema{
      type: :object, title: "SessionObject",
      properties: %{
        id: %Schema{
          type: :string,
          description: "Session ID — pass to DELETE /api/v1/sessions/:id to revoke",
          example: "abc123xyz"
        },
        device: %Schema{
          type: :string,
          description: "Detected device type: desktop / mobile / tablet / api_client / unknown",
          example: "desktop"
        },
        ip_address:     %Schema{type: :string, example: "192.168.1.1"},
        user_agent:     %Schema{type: :string, example: "Mozilla/5.0..."},
        last_active_at: %Schema{type: :string, format: :"date-time"},
        created_at:     %Schema{type: :string, format: :"date-time", description: "Login time"}
      }
    }
  end

  defp password_confirm_schema do
    %Schema{
      type: :object, title: "PasswordConfirmRequest",
      required: [:password],
      properties: %{
        password: %Schema{type: :string, format: :password, example: "securepassword123"}
      }
    }
  end

  defp namespace_response_schema do
    %Schema{
      type: :object, title: "NamespaceResponse",
      properties: %{
        status:    %Schema{type: :string, example: "success"},
        namespace: %Schema{type: :object, additionalProperties: true}
      }
    }
  end

  defp error_response_schema do
    %Schema{
      type: :object, title: "ErrorResponse",
      required: [:error],
      properties: %{
        error: %Schema{type: :string, example: "Invalid or expired token"}
      }
    }
  end

  defp message_response_schema do
    %Schema{
      type: :object, title: "MessageResponse",
      properties: %{
        message: %Schema{type: :string, example: "Session revoked"}
      }
    }
  end

  defp status_response_schema do
    %Schema{
      type: :object, title: "StatusResponse",
      properties: %{
        status: %Schema{type: :string, example: "success"}
      }
    }
  end

  # ===========================================================================
  # Helper builders
  # ===========================================================================

  defp op(summary, tag, op_id, desc, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: [tag], operationId: op_id,
      description: desc, responses: build_responses(responses)
    }
  end

  defp op_auth(summary, tag, op_id, desc, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: [tag], operationId: op_id,
      description: desc, security: [%{"BearerAuth" => []}],
      responses: build_responses(responses)
    }
  end

  defp op_body(summary, tag, op_id, desc, schema_name, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: [tag], operationId: op_id,
      description: desc,
      requestBody: OpenApiSpex.Operation.request_body(
        "Request body", "application/json",
        %Reference{"$ref": "#/components/schemas/#{schema_name}"},
        required: true
      ),
      responses: build_responses(responses)
    }
  end

  defp op_auth_body(summary, tag, op_id, desc, schema_name, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: [tag], operationId: op_id,
      description: desc, security: [%{"BearerAuth" => []}],
      requestBody: OpenApiSpex.Operation.request_body(
        "Request body", "application/json",
        %Reference{"$ref": "#/components/schemas/#{schema_name}"},
        required: true
      ),
      responses: build_responses(responses)
    }
  end

  defp op_auth_param(summary, tag, op_id, desc, parameters, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: [tag], operationId: op_id,
      description: desc, security: [%{"BearerAuth" => []}],
      parameters: parameters,
      responses: build_responses(responses)
    }
  end

  defp session_id_param do
    %OpenApiSpex.Parameter{
      name: :id,
      in: :path,
      required: true,
      description: "Session ID from GET /api/v1/sessions",
      schema: %Schema{type: :string, example: "abc123xyz"}
    }
  end

  defp resp(desc, schema_name) do
    OpenApiSpex.Operation.response(desc, "application/json",
      %Reference{"$ref": "#/components/schemas/#{schema_name}"}
    )
  end

  defp build_responses(map) do
    Enum.into(map, %{})
  end
end
