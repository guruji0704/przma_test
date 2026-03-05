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

        ## ✅ Full Authentication Flow (follow in order)

        ### Step 1 — Get a captcha
        `GET /api/v1/pleroma/captcha`
        Save `token` and `answer_data` from the response.

        ### Step 2 — Register an OAuth app (once)
        `POST /api/v1/apps`
        Save `client_id` and `client_secret`.

        ### Step 3 — Register your account
        `POST /api/v1/account/register`
        Use the captcha `token` + `answer_data` from Step 1.
        A **6-digit OTP** is sent to your email from noreply@przma.com.
        Save the `user_id` from the response.

        ### Step 4 — Verify your email
        `POST /api/v1/account/verify_email`
        Submit `user_id` + the 6-digit `code` from your inbox.
        OTP is valid for **10 minutes**. Use resend if it expires.

        ### Step 5 — Login
        `POST /api/v1/oauth/token`
        Returns `access_token` (Bearer token) and your `did`.

        ### Step 6 — Authorize in Swagger UI
        Click the **Authorize 🔒** button (top right).
        Paste your `access_token`. All 🔒 endpoints will work.

        ---

        ## Session Management
        Each login creates a session record (device, IP, browser).
        - `GET /api/v1/sessions` — list all active sessions
        - `DELETE /api/v1/sessions/:id` — logout one device
        - `DELETE /api/v1/sessions` — logout all devices

        ## DID (Decentralized Identifier)
        Every user gets one DID at registration: `did:przma:<sha256-fingerprint>`
        """
      },
      servers: [
        %Server{url: "http://localhost:4000", description: "Development"}
      ],
      paths: %{
        # ── Captcha ──────────────────────────────────────────────────────────
        "/api/v1/pleroma/captcha" => %OpenApiSpex.PathItem{
          get: op("Step 1 — Get Captcha", "Authentication", "get_captcha",
            """
            Get a captcha challenge.

            **Save both fields from the response:**
            - `token` → use as `captcha_token` in register
            - `answer_data` → use as `captcha_solution` in register
            """,
            %{200 => resp("Captcha challenge", "CaptchaResponse"),
              500 => resp("Error", "ErrorResponse")})
        },

        # ── OAuth App ─────────────────────────────────────────────────────────
        "/api/v1/apps" => %OpenApiSpex.PathItem{
          post: op_body("Step 2 — Register OAuth App", "Authentication", "register_app",
            "Register an OAuth application. Do this once and save `client_id` + `client_secret`.",
            "RegisterAppRequest",
            %{200 => resp("App registered", "RegisterAppResponse"),
              422 => resp("Validation error", "ErrorResponse")})
        },

        # ── Register ──────────────────────────────────────────────────────────
        "/api/v1/account/register" => %OpenApiSpex.PathItem{
          post: op_body("Step 3 — Register Account", "Authentication", "register_account",
            """
            Create a new user account.

            **On success:**
            - User is created with a unique DID (`did:przma:...`)
            - A **6-digit code** is emailed from noreply@przma.com
            - Save the `user_id` from the response

            **Next:** `POST /api/v1/account/verify_email` with `user_id` + `code` from inbox
            """,
            "RegisterAccountRequest",
            %{200 => resp("Account created — check email for 6-digit code", "RegisterResponse"),
              400 => resp("Bad request", "ErrorResponse")})
        },

        # ── Verify Email ──────────────────────────────────────────────────────
        "/api/v1/account/verify_email" => %OpenApiSpex.PathItem{
          post: op_body("Step 4 — Verify Email (Enter Code)", "Email Verification", "verify_email",
            """
            Verify your email by submitting the 6-digit code sent to your inbox.

            **Fields:**
            - `user_id` — from the Step 3 register response
            - `code` — the 6-digit number from your email

            **Rules:**
            - Code is valid for **10 minutes**
            - Max **3 attempts** before lockout
            - If expired or locked, use `POST /api/v1/account/resend_otp`

            **On success:** you can log in via `POST /api/v1/oauth/token`
            """,
            "VerifyEmailRequest",
            %{200 => resp("Email verified — you can now log in", "VerifyEmailResponse"),
              400 => resp("Invalid or expired code", "ErrorResponse"),
              429 => resp("Too many attempts — request a new code", "ErrorResponse")})
        },

        # ── Resend OTP ────────────────────────────────────────────────────────
        "/api/v1/account/resend_otp" => %OpenApiSpex.PathItem{
          post: op_body("Resend Code", "Email Verification", "resend_otp",
            """
            Resend the 6-digit verification code to your email.

            Use this if:
            - The code expired (10 minute window)
            - You didn't receive the email
            - You exceeded the attempt limit

            **Rate limited:** 60 seconds cooldown between resends.
            """,
            "ResendOTPRequest",
            %{200 => resp("Code resent", "MessageResponse"),
              400 => resp("Already verified", "ErrorResponse"),
              404 => resp("User not found", "ErrorResponse"),
              429 => resp("Resend rate limited — wait 60s", "ErrorResponse")})
        },

        # ── OAuth Token ───────────────────────────────────────────────────────
        "/api/v1/oauth/token" => %OpenApiSpex.PathItem{
          post: op_body("Step 5 — Login / Get Token", "Authentication", "get_oauth_token",
            """
            Login with nickname + password.

            **Email must be verified first** (Step 4). If not verified, returns 403
            with instructions to complete verification.

            **On success:**
            - Returns `access_token` (Bearer) — paste into the Authorize 🔒 button above
            - Returns your `did`
            - Creates a session record (device, IP, browser)
            """,
            "OAuthTokenRequest",
            %{200 => resp("Token issued", "OAuthTokenResponse"),
              401 => resp("Invalid credentials", "ErrorResponse"),
              403 => resp("Email not verified", "ErrorResponse"),
              400 => resp("Bad grant type", "ErrorResponse")})
        },

        # ── Verify Credentials ────────────────────────────────────────────────
        "/api/v1/accounts/verify_credentials" => %OpenApiSpex.PathItem{
          get: op_auth("Verify Token / Get Account", "Authentication", "verify_credentials",
            "Verify your Bearer token is valid. Returns your account info including DID.",
            %{200 => resp("Account info", "AccountResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        # ── DID ───────────────────────────────────────────────────────────────
        "/api/v1/accounts/did" => %OpenApiSpex.PathItem{
          get: op_auth("Get My DID", "DID", "get_did",
            """
            Get your Decentralized Identifier (DID).

            Format: `did:przma:<sha256-base64url-fingerprint>`
            Generated once at registration — never changes.
            """,
            %{200 => resp("DID info", "DIDResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        # ── Sessions ──────────────────────────────────────────────────────────
        "/api/v1/sessions" => %OpenApiSpex.PathItem{
          get: op_auth("List Active Sessions", "Sessions", "list_sessions",
            "Get all active login sessions. Each shows device, IP, and last activity time.",
            %{200 => resp("Sessions list", "SessionsResponse"),
              401 => resp("Unauthorized", "ErrorResponse")}),

          delete: op_auth("Logout From All Devices", "Sessions", "revoke_all_sessions",
            "Revoke ALL active sessions and tokens across every device immediately.",
            %{200 => resp("All sessions revoked", "MessageResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        "/api/v1/sessions/{id}" => %OpenApiSpex.PathItem{
          delete: op_auth_param("Logout One Device", "Sessions", "revoke_session",
            "Revoke a single session by ID. Get the ID from `GET /api/v1/sessions`.",
            [session_id_param()],
            %{200 => resp("Session revoked", "MessageResponse"),
              404 => resp("Not found", "ErrorResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        # ── Revoke Token ──────────────────────────────────────────────────────
        "/oauth/token/revoke" => %OpenApiSpex.PathItem{
          delete: op_auth("Logout (Revoke Token)", "Authentication", "revoke_token",
            "Revoke the current Bearer token. Returns 401 on any subsequent request.",
            %{200 => resp("Revoked", "MessageResponse"),
              404 => resp("Not found", "ErrorResponse")})
        },

        # ── Delete Account ────────────────────────────────────────────────────
        "/api/v1/pleroma/delete_account" => %OpenApiSpex.PathItem{
          post: op_auth_body("Delete Account", "Account Management", "delete_account",
            "Permanently delete account (requires password). Revokes all tokens and sessions.",
            "PasswordConfirmRequest",
            %{200 => resp("Deleted", "StatusResponse"),
              401 => resp("Unauthorized", "ErrorResponse"),
              403 => resp("Wrong password", "ErrorResponse")})
        },

        # ── Disable Account ───────────────────────────────────────────────────
        "/api/v1/pleroma/disable_account" => %OpenApiSpex.PathItem{
          post: op_auth_body("Disable Account", "Account Management", "disable_account",
            "Disable account (requires password). Revokes all tokens and sessions.",
            "PasswordConfirmRequest",
            %{200 => resp("Disabled", "StatusResponse"),
              401 => resp("Unauthorized", "ErrorResponse"),
              403 => resp("Wrong password", "ErrorResponse")})
        },

        # ── Namespace ─────────────────────────────────────────────────────────
        "/api/v1/namespaces" => %OpenApiSpex.PathItem{
          post: op_auth("Create/Get Namespace", "Namespace", "create_or_get_namespace",
            "Create or retrieve the namespace for the authenticated user (keyed by DID).",
            %{200 => resp("Namespace", "NamespaceResponse"),
              401 => resp("Unauthorized", "ErrorResponse")}),
          get: op_auth("Get Namespace", "Namespace", "get_namespace",
            "Get namespace status for the authenticated user.",
            %{200 => resp("Namespace", "NamespaceResponse"),
              404 => resp("Not found", "ErrorResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        "/api/v1/namespaces/account" => %OpenApiSpex.PathItem{
          get: op_auth("Get Account in Namespace", "Namespace", "get_namespace_account",
            "Get account info stored in the authenticated user's namespace.",
            %{200 => resp("Account", "AccountResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        }
      },
      components: %Components{
        schemas: %{
          # ── Request schemas ───────────────────────────────────────────────
          "RegisterAppRequest"     => register_app_request_schema(),
          "OAuthTokenRequest"      => oauth_token_request_schema(),
          "RegisterAccountRequest" => register_account_request_schema(),
          "VerifyEmailRequest"     => verify_email_request_schema(),
          "ResendOTPRequest"       => resend_otp_request_schema(),
          "PasswordConfirmRequest" => password_confirm_schema(),

          # ── Response schemas ──────────────────────────────────────────────
          "RegisterAppResponse"  => register_app_response_schema(),
          "OAuthTokenResponse"   => oauth_token_response_schema(),
          "RegisterResponse"     => register_response_schema(),
          "VerifyEmailResponse"  => verify_email_response_schema(),
          "AccountResponse"      => account_response_schema(),
          "CaptchaResponse"      => captcha_response_schema(),
          "DIDResponse"          => did_response_schema(),
          "SessionsResponse"     => sessions_response_schema(),
          "SessionObject"        => session_object_schema(),
          "NamespaceResponse"    => namespace_response_schema(),
          "ErrorResponse"        => error_response_schema(),
          "MessageResponse"      => message_response_schema(),
          "StatusResponse"       => status_response_schema()
        },
        securitySchemes: %{
          "BearerAuth" => %OpenApiSpex.SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: "Paste the access_token from POST /api/v1/oauth/token"
          }
        }
      }
    }
  end

  # ===========================================================================
  # Request Schemas
  # ===========================================================================

  defp register_app_request_schema do
    %Schema{
      type: :object, title: "RegisterAppRequest",
      required: [:client_name],
      properties: %{
        client_name:   %Schema{type: :string, example: "My PRZMA App"},
        redirect_uris: %Schema{type: :string, example: "urn:ietf:wg:oauth:2.0:oob"},
        scopes:        %Schema{type: :string, example: "read write"},
        website:       %Schema{type: :string, example: "https://example.com"}
      }
    }
  end

  defp oauth_token_request_schema do
    %Schema{
      type: :object, title: "OAuthTokenRequest",
      required: [:grant_type, :username, :password],
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

  defp register_account_request_schema do
    %Schema{
      type: :object, title: "RegisterAccountRequest",
      required: [:nickname, :email, :password, :captcha_token, :captcha_solution],
      properties: %{
        nickname:         %Schema{type: :string, example: "johndoe"},
        email:            %Schema{type: :string, format: :email, example: "john@example.com"},
        password:         %Schema{type: :string, format: :password, example: "securepassword123"},
        fullname:         %Schema{type: :string, example: "John Doe"},
        bio:              %Schema{type: :string, example: "Software developer"},
        captcha_token:    %Schema{type: :string, description: "`token` from Step 1 captcha response"},
        captcha_solution: %Schema{type: :string, description: "`answer_data` from Step 1 captcha response", example: "A8F3K2"}
      }
    }
  end

  defp verify_email_request_schema do
    %Schema{
      type: :object, title: "VerifyEmailRequest",
      required: [:user_id, :code],
      properties: %{
        user_id: %Schema{
          type: :string,
          description: "`user_id` from the Step 3 register response",
          example: "mK92pqRtYuIoplKj"
        },
        code: %Schema{
          type: :string,
          description: "6-digit code from your verification email",
          example: "713776"
        }
      }
    }
  end

  defp resend_otp_request_schema do
    %Schema{
      type: :object, title: "ResendOTPRequest",
      required: [:user_id],
      properties: %{
        user_id: %Schema{
          type: :string,
          description: "`user_id` from the Step 3 register response",
          example: "mK92pqRtYuIoplKj"
        }
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

  # ===========================================================================
  # Response Schemas
  # ===========================================================================

  defp register_app_response_schema do
    %Schema{
      type: :object, title: "RegisterAppResponse",
      properties: %{
        id:            %Schema{type: :string},
        name:          %Schema{type: :string, example: "My PRZMA App"},
        client_id:     %Schema{type: :string, example: "K7mF2xQ9rP..."},
        client_secret: %Schema{type: :string, example: "abc123..."},
        redirect_uri:  %Schema{type: :string},
        vapid_key:     %Schema{type: :string, nullable: true}
      }
    }
  end

  defp oauth_token_response_schema do
    %Schema{
      type: :object, title: "OAuthTokenResponse",
      properties: %{
        access_token:  %Schema{type: :string, example: "a-GvXrUzM9Fv..."},
        token_type:    %Schema{type: :string, example: "Bearer"},
        scope:         %Schema{type: :string, example: "read write"},
        expires_in:    %Schema{type: :integer, example: 2592000},
        refresh_token: %Schema{type: :string},
        me:            %Schema{type: :string, description: "Your nickname", example: "johndoe"},
        did:           %Schema{type: :string, example: "did:przma:K7mF2xQ9rP..."},
        created_at:    %Schema{type: :integer, example: 1740614645}
      }
    }
  end

  defp register_response_schema do
    %Schema{
      type: :object, title: "RegisterResponse",
      description: "Returned after successful registration. Save user_id for verify_email step.",
      properties: %{
        message:   %Schema{type: :string, example: "Registration successful. Check your email for your 6-digit verification code."},
        user_id:   %Schema{type: :string, description: "Save this — needed for verify_email", example: "mK92pqRtYuIoplKj"},
        email:     %Schema{type: :string, example: "john@example.com"},
        next_step: %Schema{type: :string, example: "POST /api/v1/account/verify_email with {user_id, code}"}
      }
    }
  end

  defp verify_email_response_schema do
    %Schema{
      type: :object, title: "VerifyEmailResponse",
      properties: %{
        ok:        %Schema{type: :boolean, example: true},
        message:   %Schema{type: :string, example: "Email verified successfully. You can now log in."},
        user_id:   %Schema{type: :string, example: "mK92pqRtYuIoplKj"},
        next_step: %Schema{type: :string, example: "POST /api/v1/oauth/token"}
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
        did:          %Schema{type: :string, example: "did:przma:K7mF2xQ9rP..."},
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
        token:         %Schema{type: :string, description: "Pass as `captcha_token` in register"},
        answer_data:   %Schema{type: :string, description: "Pass as `captcha_solution` in register", example: "A8F3K2"},
        seconds_valid: %Schema{type: :integer, example: 300}
      }
    }
  end

  defp did_response_schema do
    %Schema{
      type: :object, title: "DIDResponse",
      properties: %{
        user_id:       %Schema{type: :string},
        nickname:      %Schema{type: :string},
        did:           %Schema{type: :string, example: "did:przma:K7mF2xQ9rP..."},
        did_method:    %Schema{type: :string, example: "przma"},
        fingerprint:   %Schema{type: :string},
        namespace_key: %Schema{type: :string},
        description:   %Schema{type: :string}
      }
    }
  end

  defp sessions_response_schema do
    %Schema{
      type: :object, title: "SessionsResponse",
      properties: %{
        sessions: %Schema{
          type: :array,
          items: %Reference{"$ref": "#/components/schemas/SessionObject"}
        }
      }
    }
  end

  defp session_object_schema do
    %Schema{
      type: :object, title: "SessionObject",
      properties: %{
        id:             %Schema{type: :string, description: "Use for DELETE /api/v1/sessions/:id"},
        device:         %Schema{type: :string, example: "desktop"},
        ip_address:     %Schema{type: :string, example: "192.168.1.1"},
        user_agent:     %Schema{type: :string},
        last_active_at: %Schema{type: :string, format: :"date-time"},
        created_at:     %Schema{type: :string, format: :"date-time"}
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
        ok:      %Schema{type: :boolean, example: true},
        message: %Schema{type: :string, example: "Email verified successfully"}
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
      name: :id, in: :path, required: true,
      description: "Session ID from GET /api/v1/sessions",
      schema: %Schema{type: :string, example: "abc123xyz"}
    }
  end

  defp resp(desc, schema_name) do
    OpenApiSpex.Operation.response(desc, "application/json",
      %Reference{"$ref": "#/components/schemas/#{schema_name}"}
    )
  end

  defp build_responses(map), do: Enum.into(map, %{})
end
