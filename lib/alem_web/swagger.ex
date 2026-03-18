defmodule AlemWeb.Swagger do
  @moduledoc "OpenAPI/Swagger specification for PRZMA/ALEM API"

  alias OpenApiSpex.{Components, Info, OpenApi, Reference, Schema, Server}

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    # Server URL comes from environment — works in dev, Docker, and production
    server_url = Application.get_env(:alem, :base_url,
                   System.get_env("APP_BASE_URL", "http://localhost:4000"))

    %OpenApi{
      info: %Info{
        title:       "PRZMA / ALEM API",
        version:     "1.0.0",
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
        A **6-digit OTP** is sent to your email.
        Save the `user_id` from the response.

        ### Step 4 — Verify your email
        `POST /api/v1/account/verify_email`
        Submit `user_id` + the 6-digit `code` from your inbox.
        OTP is valid for **10 minutes**.

        ### Step 5 — Login
        `POST /api/v1/oauth/token`
        Accepts **nickname OR email** as the `username` field.
        Returns `access_token` (Bearer token) and your `did`.

        ### Step 6 — Authorize in Swagger UI
        Click the **Authorize 🔒** button (top right).
        Paste your `access_token`. All 🔒 endpoints will work.

        ---

        ## Health Check
        `GET /api/health` — checks all services (no auth required).
        Used by the load balancer to route traffic.

        ## Session Management
        Each login creates a session record (device, IP, browser).
        - `GET /api/v1/sessions` — list all active sessions
        - `DELETE /api/v1/sessions/:id` — logout one device
        - `DELETE /api/v1/sessions` — logout all devices

        ## DID (Decentralized Identifier)
        Every user gets one DID at registration: `did:przma:<sha256-fingerprint>`

        ---

        ## Forgot Password Flow
        ### Step A — Request reset link
        `POST /api/v1/account/forgot_password`

        ### Step B — Reset password
        `POST /api/v1/account/reset_password`
        Token expires in **15 minutes**. Max 3 attempts.
        """
      },
      servers: [
        %Server{url: server_url, description: "Current server"}
      ],
      paths: %{
        # ── Health ────────────────────────────────────────────────────────────
        "/api/health" => %OpenApiSpex.PathItem{
          get: op("Health Check", "System", "health_check",
            "Check all services. Used by load balancer. No auth required.",
            %{200 => resp("All services healthy", "HealthResponse"),
              503 => resp("One or more services degraded", "HealthResponse")})
        },

        # ── Captcha ───────────────────────────────────────────────────────────
        "/api/v1/pleroma/captcha" => %OpenApiSpex.PathItem{
          get: op("Step 1 — Get Captcha", "Authentication", "get_captcha",
            "Get a captcha challenge. Save `token` and `answer_data`.",
            %{200 => resp("Captcha challenge", "CaptchaResponse"),
              500 => resp("Error", "ErrorResponse")})
        },

        # ── OAuth App ─────────────────────────────────────────────────────────
        "/api/v1/apps" => %OpenApiSpex.PathItem{
          post: op_body("Step 2 — Register OAuth App", "Authentication", "register_app",
            "Register an OAuth app. Save `client_id` + `client_secret`.",
            "RegisterAppRequest",
            %{200 => resp("App registered", "RegisterAppResponse"),
              422 => resp("Validation error", "ErrorResponse")})
        },

        # ── Register ──────────────────────────────────────────────────────────
        "/api/v1/account/register" => %OpenApiSpex.PathItem{
          post: op_body("Step 3 — Register Account", "Authentication", "register_account",
            """
            Create a new user account.

            **Password rules:** Min 12 chars, uppercase, lowercase, digit, special char.

            **On success:** A 6-digit code is emailed. Save `user_id` from the response.
            """,
            "RegisterAccountRequest",
            %{200 => resp("Account created", "RegisterResponse"),
              400 => resp("Missing fields", "ErrorResponse"),
              422 => resp("Validation error", "ErrorResponse")})
        },

        # ── Verify Email ──────────────────────────────────────────────────────
        "/api/v1/account/verify_email" => %OpenApiSpex.PathItem{
          post: op_body("Step 4 — Verify Email", "Email Verification", "verify_email",
            "Submit the 6-digit code from your inbox. Code valid 10 minutes, max 3 attempts.",
            "VerifyEmailRequest",
            %{200 => resp("Verified", "VerifyEmailResponse"),
              400 => resp("Invalid/expired code", "ErrorResponse"),
              429 => resp("Too many attempts", "ErrorResponse")})
        },

        # ── Resend OTP ────────────────────────────────────────────────────────
        "/api/v1/account/resend_otp" => %OpenApiSpex.PathItem{
          post: op_body("Resend Verification Code", "Email Verification", "resend_otp",
            "Resend the 6-digit code. Rate limited: 60s cooldown.",
            "ResendOTPRequest",
            %{200 => resp("Code resent", "MessageResponse"),
              400 => resp("Already verified", "ErrorResponse"),
              429 => resp("Rate limited", "ErrorResponse")})
        },

        # ── OAuth Token ───────────────────────────────────────────────────────
        "/api/v1/oauth/token" => %OpenApiSpex.PathItem{
          post: op_body("Step 5 — Login", "Authentication", "get_oauth_token",
            "Login with nickname OR email + password. Returns `access_token`.",
            "OAuthTokenRequest",
            %{200 => resp("Token issued", "OAuthTokenResponse"),
              401 => resp("Invalid credentials", "ErrorResponse"),
              403 => resp("Email not verified", "UnverifiedResponse")})
        },

        # ── Verify Credentials ────────────────────────────────────────────────
        "/api/v1/accounts/verify_credentials" => %OpenApiSpex.PathItem{
          get: op_auth("Verify Token", "Authentication", "verify_credentials",
            "Verify Bearer token. Returns account info including DID.",
            %{200 => resp("Account info", "AccountResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        # ── DID ───────────────────────────────────────────────────────────────
        "/api/v1/accounts/did" => %OpenApiSpex.PathItem{
          get: op_auth("Get My DID", "DID", "get_did",
            "Get your DID. Format: `did:przma:<sha256-fingerprint>`",
            %{200 => resp("DID info", "DIDResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        # ── Sessions ──────────────────────────────────────────────────────────
        "/api/v1/sessions" => %OpenApiSpex.PathItem{
          get:    op_auth("List Active Sessions", "Sessions", "list_sessions",
            "Get all active login sessions.",
            %{200 => resp("Sessions list", "SessionsResponse"),
              401 => resp("Unauthorized", "ErrorResponse")}),
          delete: op_auth("Logout All Devices", "Sessions", "revoke_all_sessions",
            "Revoke ALL sessions and tokens immediately.",
            %{200 => resp("Revoked", "MessageResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        "/api/v1/sessions/{id}" => %OpenApiSpex.PathItem{
          delete: op_auth_param("Logout One Device", "Sessions", "revoke_session",
            "Revoke a single session by ID.",
            [session_id_param()],
            %{200 => resp("Revoked", "MessageResponse"),
              404 => resp("Not found", "ErrorResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        # ── Forgot Password ───────────────────────────────────────────────────
        "/api/v1/account/forgot_password" => %OpenApiSpex.PathItem{
          post: op_body("Forgot Password", "Account Management", "forgot_password",
            "Request reset link. Always returns 200 (prevents enumeration). Expires in 15 min.",
            "ForgotPasswordRequest",
            %{200 => resp("Email sent", "MessageResponse"),
              429 => resp("Rate limited — wait 60s", "ErrorResponse")})
        },

        # ── Reset Password ────────────────────────────────────────────────────
        "/api/v1/account/reset_password" => %OpenApiSpex.PathItem{
          post: op_body("Reset Password", "Account Management", "reset_password",
            "Reset password using token from email. Single-use, 15 min expiry, max 3 attempts.",
            "ResetPasswordRequest",
            %{200 => resp("Password reset", "VerifyEmailResponse"),
              400 => resp("Invalid/expired token", "ErrorResponse"),
              429 => resp("Too many attempts", "ErrorResponse")})
        },

        # ── Delete / Disable Account ──────────────────────────────────────────
        "/api/v1/pleroma/delete_account" => %OpenApiSpex.PathItem{
          post: op_auth_body("Delete Account", "Account Management", "delete_account",
            "Permanently delete account. Requires password.",
            "PasswordConfirmRequest",
            %{200 => resp("Deleted", "StatusResponse"),
              403 => resp("Wrong password", "ErrorResponse")})
        },

        "/api/v1/pleroma/disable_account" => %OpenApiSpex.PathItem{
          post: op_auth_body("Disable Account", "Account Management", "disable_account",
            "Disable account. Requires password.",
            "PasswordConfirmRequest",
            %{200 => resp("Disabled", "StatusResponse"),
              403 => resp("Wrong password", "ErrorResponse")})
        },

        # ── Namespaces ────────────────────────────────────────────────────────
        "/api/v1/namespaces" => %OpenApiSpex.PathItem{
          post: op_auth("Create/Get Namespace", "Namespace", "create_or_get_namespace",
            "Create or retrieve namespace for the authenticated user.",
            %{200 => resp("Namespace", "NamespaceResponse"),
              401 => resp("Unauthorized", "ErrorResponse")}),
          get:  op_auth("Get Namespace", "Namespace", "get_namespace",
            "Get namespace status.",
            %{200 => resp("Namespace", "NamespaceResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        # ── Sync ─────────────────────────────────────────────────────────────
        "/api/v1/sync/documents" => %OpenApiSpex.PathItem{
          get: op_auth("List Synced Documents", "Sync", "list_sync_documents",
            "Get all documents for user from sqld. Add `?since=ISO_TIMESTAMP` for incremental pull.",
            %{200 => resp("Documents list", "DocumentsResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },

        "/api/v1/sync/crdt/upload" => %OpenApiSpex.PathItem{
          post: op_auth_body("Upload File", "Sync", "crdt_upload",
            "Upload a file to Linode S3 and record metadata in sqld.",
            "UploadRequest",
            %{200 => resp("Upload successful", "UploadResponse"),
              401 => resp("Unauthorized", "ErrorResponse"),
              400 => resp("Missing fields", "ErrorResponse")})
        },

        "/api/v1/sync/download/{id}" => %OpenApiSpex.PathItem{
          get: op_auth_param("Download File", "Sync", "download_document",
            "Download raw file bytes from S3 via Phoenix. Authenticated.",
            [doc_id_param()],
            %{200 => resp("File bytes", "ErrorResponse"),
              404 => resp("Not found", "ErrorResponse"),
              401 => resp("Unauthorized", "ErrorResponse")})
        },
      },

      components: %Components{
        schemas: %{
          "RegisterAppRequest"     => register_app_request_schema(),
          "OAuthTokenRequest"      => oauth_token_request_schema(),
          "RegisterAccountRequest" => register_account_request_schema(),
          "VerifyEmailRequest"     => verify_email_request_schema(),
          "ResendOTPRequest"       => resend_otp_request_schema(),
          "PasswordConfirmRequest" => password_confirm_schema(),
          "ForgotPasswordRequest"  => forgot_password_request_schema(),
          "ResetPasswordRequest"   => reset_password_request_schema(),
          "UploadRequest"          => upload_request_schema(),
          "RegisterAppResponse"    => register_app_response_schema(),
          "OAuthTokenResponse"     => oauth_token_response_schema(),
          "RegisterResponse"       => register_response_schema(),
          "VerifyEmailResponse"    => verify_email_response_schema(),
          "UnverifiedResponse"     => unverified_response_schema(),
          "AccountResponse"        => account_response_schema(),
          "CaptchaResponse"        => captcha_response_schema(),
          "DIDResponse"            => did_response_schema(),
          "SessionsResponse"       => sessions_response_schema(),
          "SessionObject"          => session_object_schema(),
          "NamespaceResponse"      => namespace_response_schema(),
          "DocumentsResponse"      => documents_response_schema(),
          "UploadResponse"         => upload_response_schema(),
          "HealthResponse"         => health_response_schema(),
          "ErrorResponse"          => error_response_schema(),
          "MessageResponse"        => message_response_schema(),
          "StatusResponse"         => status_response_schema(),
        },
        securitySchemes: %{
          "BearerAuth" => %OpenApiSpex.SecurityScheme{
            type:        "http",
            scheme:      "bearer",
            description: "Paste the access_token from POST /api/v1/oauth/token"
          }
        }
      }
    }
  end

  # ── Request schemas ───────────────────────────────────────────────────────────

  defp register_app_request_schema do
    %Schema{type: :object, title: "RegisterAppRequest",
      required: [:client_name],
      properties: %{
        client_name:   %Schema{type: :string, example: "My PRZMA App"},
        redirect_uris: %Schema{type: :string, example: "urn:ietf:wg:oauth:2.0:oob"},
        scopes:        %Schema{type: :string, example: "read write"},
        website:       %Schema{type: :string, example: "https://example.com"}
      }}
  end

  defp oauth_token_request_schema do
    %Schema{type: :object, title: "OAuthTokenRequest",
      required: [:grant_type, :username, :password],
      properties: %{
        grant_type: %Schema{type: :string, enum: ["password"], example: "password"},
        username:   %Schema{type: :string, description: "Nickname OR email", example: "Arun"},
        password:   %Schema{type: :string, format: :password, example: "Arun@123456Xyz"},
        client_id:  %Schema{type: :string},
        scope:      %Schema{type: :string, example: "read write"}
      }}
  end

  defp register_account_request_schema do
    %Schema{type: :object, title: "RegisterAccountRequest",
      required: [:nickname, :email, :date_of_birth, :password,
                 :password_confirmation, :captcha_token, :captcha_solution],
      properties: %{
        nickname:              %Schema{type: :string, example: "Arun"},
        email:                 %Schema{type: :string, format: :email, example: "arun@example.com"},
        date_of_birth:         %Schema{type: :string, format: :date, example: "1995-06-15"},
        password:              %Schema{type: :string, format: :password,
                                  description: "Min 12 chars, uppercase, lowercase, digit, special char",
                                  example: "Arun@123456Xyz"},
        password_confirmation: %Schema{type: :string, format: :password, example: "Arun@123456Xyz"},
        fullname:              %Schema{type: :string, example: "Arun Kumar"},
        bio:                   %Schema{type: :string, example: "Software developer"},
        captcha_token:         %Schema{type: :string},
        captcha_solution:      %Schema{type: :string, example: "A8F3K2"}
      }}
  end

  defp verify_email_request_schema do
    %Schema{type: :object, title: "VerifyEmailRequest",
      required: [:user_id, :code],
      properties: %{
        user_id: %Schema{type: :string, example: "mK92pqRtYuIoplKj"},
        code:    %Schema{type: :string, example: "713776"}
      }}
  end

  defp resend_otp_request_schema do
    %Schema{type: :object, title: "ResendOTPRequest",
      required: [:user_id],
      properties: %{user_id: %Schema{type: :string, example: "mK92pqRtYuIoplKj"}}}
  end

  defp password_confirm_schema do
    %Schema{type: :object, title: "PasswordConfirmRequest",
      required: [:password],
      properties: %{password: %Schema{type: :string, format: :password}}}
  end

  defp forgot_password_request_schema do
    %Schema{type: :object, title: "ForgotPasswordRequest",
      required: [:email],
      properties: %{email: %Schema{type: :string, format: :email}}}
  end

  defp reset_password_request_schema do
    %Schema{type: :object, title: "ResetPasswordRequest",
      required: [:token, :password, :password_confirmation],
      properties: %{
        token:                 %Schema{type: :string},
        password:              %Schema{type: :string, format: :password,
                                  description: "Min 12 chars"},
        password_confirmation: %Schema{type: :string, format: :password}
      }}
  end

  defp upload_request_schema do
    %Schema{type: :object, title: "UploadRequest",
      required: [:doc_id, :filename, :file_content_b64],
      properties: %{
        doc_id:           %Schema{type: :string, example: "uuid-here"},
        filename:         %Schema{type: :string, example: "document.pdf"},
        file_content_b64: %Schema{type: :string, description: "Base64-encoded file bytes"},
        content_type:     %Schema{type: :string, example: "application/pdf"},
        device_id:        %Schema{type: :string},
        automerge_state:  %Schema{type: :string, description: "Base64 CRDT state (optional)"}
      }}
  end

  # ── Response schemas ──────────────────────────────────────────────────────────

  defp register_app_response_schema do
    %Schema{type: :object, title: "RegisterAppResponse",
      properties: %{
        id:            %Schema{type: :string},
        name:          %Schema{type: :string},
        client_id:     %Schema{type: :string},
        client_secret: %Schema{type: :string},
        redirect_uri:  %Schema{type: :string}
      }}
  end

  defp oauth_token_response_schema do
    %Schema{type: :object, title: "OAuthTokenResponse",
      properties: %{
        access_token: %Schema{type: :string},
        token_type:   %Schema{type: :string, example: "Bearer"},
        me:           %Schema{type: :string, description: "Nickname"},
        did:          %Schema{type: :string},
        user_id:      %Schema{type: :string},
        expires_in:   %Schema{type: :integer}
      }}
  end

  defp register_response_schema do
    %Schema{type: :object, title: "RegisterResponse",
      properties: %{
        message:   %Schema{type: :string},
        user_id:   %Schema{type: :string, description: "Save this for verify_email"},
        email:     %Schema{type: :string},
        next_step: %Schema{type: :string}
      }}
  end

  defp verify_email_response_schema do
    %Schema{type: :object, title: "VerifyEmailResponse",
      properties: %{
        ok:        %Schema{type: :boolean},
        message:   %Schema{type: :string},
        user_id:   %Schema{type: :string},
        next_step: %Schema{type: :string}
      }}
  end

  defp unverified_response_schema do
    %Schema{type: :object, title: "UnverifiedResponse",
      properties: %{
        error:     %Schema{type: :string},
        user_id:   %Schema{type: :string},
        email:     %Schema{type: :string},
        next_step: %Schema{type: :string}
      }}
  end

  defp account_response_schema do
    %Schema{type: :object, title: "AccountResponse",
      properties: %{
        id:           %Schema{type: :string},
        username:     %Schema{type: :string},
        display_name: %Schema{type: :string},
        did:          %Schema{type: :string},
        created_at:   %Schema{type: :string}
      }}
  end

  defp captcha_response_schema do
    %Schema{type: :object, title: "CaptchaResponse",
      properties: %{
        type:          %Schema{type: :string},
        token:         %Schema{type: :string},
        answer_data:   %Schema{type: :string},
        seconds_valid: %Schema{type: :integer}
      }}
  end

  defp did_response_schema do
    %Schema{type: :object, title: "DIDResponse",
      properties: %{
        did:           %Schema{type: :string},
        did_method:    %Schema{type: :string},
        namespace_key: %Schema{type: :string}
      }}
  end

  defp sessions_response_schema do
    %Schema{type: :object, title: "SessionsResponse",
      properties: %{
        sessions: %Schema{type: :array,
          items: %Reference{"$ref": "#/components/schemas/SessionObject"}}
      }}
  end

  defp session_object_schema do
    %Schema{type: :object, title: "SessionObject",
      properties: %{
        id:             %Schema{type: :string},
        device:         %Schema{type: :string},
        ip_address:     %Schema{type: :string},
        last_active_at: %Schema{type: :string}
      }}
  end

  defp namespace_response_schema do
    %Schema{type: :object, title: "NamespaceResponse",
      properties: %{
        status:    %Schema{type: :string},
        namespace: %Schema{type: :object, additionalProperties: true}
      }}
  end

  defp documents_response_schema do
    %Schema{type: :object, title: "DocumentsResponse",
      properties: %{
        documents: %Schema{type: :array, items: %Schema{type: :object, additionalProperties: true}},
        total:     %Schema{type: :integer}
      }}
  end

  defp upload_response_schema do
    %Schema{type: :object, title: "UploadResponse",
      properties: %{
        success:  %Schema{type: :boolean},
        doc_id:   %Schema{type: :string},
        s3_key:   %Schema{type: :string},
        file_size:%Schema{type: :integer}
      }}
  end

  defp health_response_schema do
    %Schema{type: :object, title: "HealthResponse",
      properties: %{
        status:    %Schema{type: :string, example: "ok"},
        timestamp: %Schema{type: :string},
        version:   %Schema{type: :string},
        instance:  %Schema{type: :object, additionalProperties: true},
        services:  %Schema{type: :object, additionalProperties: true}
      }}
  end

  defp error_response_schema do
    %Schema{type: :object, title: "ErrorResponse",
      required: [:error],
      properties: %{error: %Schema{type: :string}}}
  end

  defp message_response_schema do
    %Schema{type: :object, title: "MessageResponse",
      properties: %{
        ok:      %Schema{type: :boolean},
        message: %Schema{type: :string},
        note:    %Schema{type: :string, nullable: true}
      }}
  end

  defp status_response_schema do
    %Schema{type: :object, title: "StatusResponse",
      properties: %{status: %Schema{type: :string}}}
  end

  # ── Builder helpers ───────────────────────────────────────────────────────────

  defp op(summary, tag, op_id, desc, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: [tag], operationId: op_id,
      description: desc, responses: build_responses(responses)}
  end

  defp op_auth(summary, tag, op_id, desc, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: [tag], operationId: op_id,
      description: desc, security: [%{"BearerAuth" => []}],
      responses: build_responses(responses)}
  end

  defp op_body(summary, tag, op_id, desc, schema_name, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: [tag], operationId: op_id, description: desc,
      requestBody: OpenApiSpex.Operation.request_body(
        "Request body", "application/json",
        %Reference{"$ref": "#/components/schemas/#{schema_name}"},
        required: true),
      responses: build_responses(responses)}
  end

  defp op_auth_body(summary, tag, op_id, desc, schema_name, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: [tag], operationId: op_id, description: desc,
      security: [%{"BearerAuth" => []}],
      requestBody: OpenApiSpex.Operation.request_body(
        "Request body", "application/json",
        %Reference{"$ref": "#/components/schemas/#{schema_name}"},
        required: true),
      responses: build_responses(responses)}
  end

  defp op_auth_param(summary, tag, op_id, desc, parameters, responses) do
    %OpenApiSpex.Operation{
      summary: summary, tags: [tag], operationId: op_id, description: desc,
      security: [%{"BearerAuth" => []}], parameters: parameters,
      responses: build_responses(responses)}
  end

  defp session_id_param do
    %OpenApiSpex.Parameter{name: :id, in: :path, required: true,
      schema: %Schema{type: :string}}
  end

  defp doc_id_param do
    %OpenApiSpex.Parameter{name: :id, in: :path, required: true,
      description: "Document ID from list_documents",
      schema: %Schema{type: :string}}
  end

  defp resp(desc, schema_name) do
    OpenApiSpex.Operation.response(desc, "application/json",
      %Reference{"$ref": "#/components/schemas/#{schema_name}"})
  end

  defp build_responses(map), do: Enum.into(map, %{})
end
