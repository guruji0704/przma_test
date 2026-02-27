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
        4. `POST /oauth/token` — login, get Bearer token (response includes DID)
        5. `GET /api/v1/accounts/verify_credentials` — verify token
        6. `GET /api/v1/accounts/did` — get your Decentralized Identifier

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
              422 => resp("Validation error","ErrorResponse")})
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
        "/oauth/token" => %OpenApiSpex.PathItem{
          post: op_body("Login / Get Token", "Authentication", "get_oauth_token",
            "Login with nickname + password. Response includes access_token AND your DID.",
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
            - Stored permanently in `users.did_id`

            Use `namespace_key` to derive storage names from your DID.
            """,
            %{200 => resp("DID info", "DIDResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        # ── Revoke Token (Logout) ────────────────────────────
        "/oauth/token/revoke" => %OpenApiSpex.PathItem{
          delete: op_auth("Logout / Revoke Token", "Authentication", "revoke_token",
            "Revoke current Bearer token. After this, the token returns 401.",
            %{200 => resp("Revoked", "MessageResponse"),
              404 => resp("Not found", "ErrorResponse")})
        },

        # ── Delete Account ───────────────────────────────────
        "/api/pleroma/delete_account" => %OpenApiSpex.PathItem{
          post: op_auth_body("Delete Account", "Authentication", "delete_account",
            "Delete account (requires password). Revokes all tokens.",
            "PasswordConfirmRequest",
            %{200 => resp("Deleted",      "StatusResponse"),
              401 => resp("Unauthorized",  "ErrorResponse"),
              403 => resp("Wrong password","ErrorResponse")})
        },

        # ── Disable Account ──────────────────────────────────
        "/api/pleroma/disable_account" => %OpenApiSpex.PathItem{
          post: op_auth_body("Disable Account", "Authentication", "disable_account",
            "Disable account (requires password). Account can no longer login.",
            "PasswordConfirmRequest",
            %{200 => resp("Disabled",     "StatusResponse"),
              401 => resp("Unauthorized",  "ErrorResponse"),
              403 => resp("Wrong password","ErrorResponse")})
        },

        # ── Namespace ────────────────────────────────────────
        "/api/namespaces/pleroma" => %OpenApiSpex.PathItem{
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

        "/api/namespaces/pleroma/account" => %OpenApiSpex.PathItem{
          get: op_auth("Get Account in Namespace", "Namespace", "get_namespace_account",
            "Get account info stored in the authenticated user's namespace.",
            %{200 => resp("Account", "AccountResponse"),
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
          "NamespaceResponse"      => namespace_response_schema(),
          "ErrorResponse"          => error_response_schema(),
          "MessageResponse"        => message_response_schema(),
          "StatusResponse"         => status_response_schema()
        },
        securitySchemes: %{
          "BearerAuth" => %OpenApiSpex.SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: "OAuth Bearer token. Get from POST /oauth/token"
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
        grant_type: %Schema{type: :string, enum: ["password", "client_credentials"], example: "password"},
        username:   %Schema{type: :string, description: "Your nickname", example: "johndoe"},
        password:   %Schema{type: :string, format: :password, example: "securepassword123"},
        client_id:  %Schema{type: :string, example: "K7mF2xQ9rP..."},
        client_secret: %Schema{type: :string, example: "abc123..."},
        scope:      %Schema{type: :string, example: "read write"}
      }
    }
  end

  defp oauth_token_response_schema do
    %Schema{
      type: :object, title: "OAuthTokenResponse",
      description: "Login response includes access_token AND your DID",
      properties: %{
        access_token:  %Schema{type: :string, example: "a-GvXrUzM9Fv..."},
        token_type:    %Schema{type: :string, example: "Bearer"},
        scope:         %Schema{type: :string, example: "read write"},
        expires_in:    %Schema{type: :integer, example: 2592000},
        refresh_token: %Schema{type: :string, example: "refresh_abc123..."},
        me:            %Schema{type: :string, description: "Your nickname", example: "johndoe"},
        did:           %Schema{
          type: :string,
          description: "Your Decentralized Identifier — use this as namespace root",
          example: "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"
        },
        created_at:    %Schema{type: :integer, example: 1740614645}
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
      description: "User account info. Includes DID field.",
      properties: %{
        id:           %Schema{type: :string, example: "mK92pqRtYuIoplKj"},
        username:     %Schema{type: :string, example: "johndoe"},
        acct:         %Schema{type: :string, example: "johndoe"},
        display_name: %Schema{type: :string, example: "John Doe"},
        note:         %Schema{type: :string, example: "Software developer"},
        avatar:       %Schema{type: :string, example: ""},
        created_at:   %Schema{type: :string, example: "2026-02-27T00:00:00Z"},
        did:          %Schema{
          type: :string,
          description: "Decentralized Identifier — generated once at registration",
          example: "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"
        },
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
        answer_data:   %Schema{type: :string, description: "The correct answer (shown for dev)", example: "A8F3K2"},
        seconds_valid: %Schema{type: :integer, example: 300}
      }
    }
  end

  defp did_response_schema do
    %Schema{
      type: :object, title: "DIDResponse",
      description: "Decentralized Identifier details for the authenticated user",
      properties: %{
        user_id:       %Schema{type: :string, description: "DB user ID", example: "mK92pqRtYuIoplKj"},
        nickname:      %Schema{type: :string, example: "johndoe"},
        did:           %Schema{
          type: :string,
          description: "Full DID — store this, it never changes",
          example: "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"
        },
        did_method:    %Schema{type: :string, example: "przma"},
        fingerprint:   %Schema{
          type: :string,
          description: "SHA-256 fingerprint (base64url) — the unique part of the DID",
          example: "K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"
        },
        namespace_key: %Schema{
          type: :string,
          description: "First 16 chars of fingerprint — used for namespace/storage naming",
          example: "k7mf2xq9rpvn3wlt"
        },
        description:   %Schema{type: :string, example: "This DID is your unique decentralized identifier. One per user, never changes."}
      },
      example: %{
        user_id:       "mK92pqRtYuIoplKj",
        nickname:      "johndoe",
        did:           "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH",
        did_method:    "przma",
        fingerprint:   "K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH",
        namespace_key: "k7mf2xq9rpvn3wlt",
        description:   "This DID is your unique decentralized identifier. One per user, never changes."
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
        message: %Schema{type: :string, example: "Token revoked successfully"}
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

  defp resp(desc, schema_name) do
    OpenApiSpex.Operation.response(desc, "application/json",
      %Reference{"$ref": "#/components/schemas/#{schema_name}"}
    )
  end

  defp build_responses(map) do
    Enum.into(map, %{})
  end
end
