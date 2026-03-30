defmodule AlemWeb.Swagger do
  @moduledoc "OpenAPI/Swagger specification for PRZMA/ALEM API"

  alias OpenApiSpex.{Components, Info, OpenApi, Reference, Schema, Server}

  @behaviour OpenApi

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title:   "PRZMA / ALEM API",
        version: "1.0.0",
        description: """
        ## How to Test (follow steps in order)

        1. `GET /api/health` — confirm PostgreSQL + S3 are healthy
        2. `POST /api/v1/apps` — register OAuth app, save **client_id** + **client_secret**
        3. `POST /api/v1/account/register` — create user, check terminal for OTP code
        4. `POST /api/v1/account/verify_email` — paste user_id + OTP code from terminal
        5. `POST /api/v1/oauth/token` — login, save **access_token**
        6. Click **Authorize** (lock icon, top right) and paste: `Bearer <access_token>`
        7. `GET /api/v1/accounts/verify_credentials` — confirm token works
        8. `GET /api/v1/accounts/did` — get your DID + namespace_key
        9. `GET /api/v1/test-namespace` — run full CAS pipeline smoke test

        > **OTP tip:** In dev mode, look at your server terminal for
        > `[info] [OTP] Generated code XXXXXX for user ...`
        """
      },
      servers: [
        %Server{url: "http://localhost:4000", description: "Development"}
      ],
      paths: build_paths(),
      components: %Components{
        schemas:         build_schemas(),
        securitySchemes: build_security_schemes()
      }
    }
  end

  # ===========================================================================
  # Paths
  # ===========================================================================

  defp build_paths do
    %{
      # ── 0 Health ────────────────────────────────────────────────────────────
      "/api/health" => path_item(get:
        op("Health check — no auth needed", "0 - Health", "healthCheck",
          """
          Checks PostgreSQL, S3 (perkeep bucket), sqld, and Horde.
          sqld being unhealthy is **fine** — sync is optional.
          As long as postgres + object_storage are healthy, the app works.
          """,
          %{
            200 => resp("All critical services healthy",    "HealthResponse"),
            503 => resp("One or more critical services down", "HealthResponse")
          })),

      # ── 1 OAuth App ─────────────────────────────────────────────────────────
      "/api/v1/pleroma/captcha" => path_item(get:
        op("Get captcha challenge (optional, skip in dev)", "1 - OAuth App", "getCaptcha",
          """
          Returns token + answer_data. Captcha is **optional** in this system.
          In dev just leave captcha_token and captcha_solution empty when registering.
          Code: `verify_captcha(nil, _) -> {:ok, :skipped}`
          """,
          %{200 => resp("Captcha challenge", "CaptchaResponse")})),

      "/api/v1/apps" => path_item(post:
        op_body("Register OAuth App (Step 1)", "1 - OAuth App", "registerApp",
          """
          **Step 1** — Register your OAuth app.
          **Save `client_id` and `client_secret` from the response** — you need them for login (Step 5).

          Only `client_name` is required. Use `redirect_uris: urn:ietf:wg:oauth:2.0:oob` for testing.
          """,
          "RegisterAppRequest",
          %{
            200 => resp("App registered. Save client_id and client_secret.", "RegisterAppResponse"),
            422 => resp("Validation error", "ErrorResponse")
          })),

      # ── 2 Account Registration ───────────────────────────────────────────────
      "/api/v1/account/register" => path_item(post:
        op_body("Register user account (Step 2)", "2 - Account Registration", "registerAccount",
          """
          **Step 2** — Create user. A DID (`did:przma:...`) is auto-generated and stored.

          **Captcha: skip it** — leave captcha fields empty or omit them entirely.

          After this call, check your **server terminal** for:
          ```
          [info] [OTP] Generated code XXXXXX for user ...
          ```

          **Save `user_id` from the response** — needed for Step 3.
          """,
          "RegisterAccountRequest",
          %{
            200 => resp("User created. Save user_id. Check terminal for OTP.", "RegisterAccountResponse"),
            400 => resp("Validation error (duplicate nickname/email, etc.)", "ErrorResponse")
          })),

      "/api/v1/account/verify_email" => path_item(post:
        op_body("Verify email OTP (Step 3)", "2 - Account Registration", "verifyEmail",
          """
          **Step 3** — Verify the 6-digit OTP from your server terminal.

          - `user_id` from Step 2 response
          - `code` from terminal: `[info] [OTP] Generated code XXXXXX for user ...`

          Security: OTP stored as Pbkdf2 hash (plaintext never persisted).
          Max 3 attempts before lockout. Expires in 10 minutes.
          """,
          "VerifyEmailRequest",
          %{
            200 => resp("Email verified. You can now log in.", "VerifyEmailResponse"),
            400 => resp("Invalid or expired OTP code", "ErrorResponse"),
            404 => resp("User not found", "ErrorResponse"),
            429 => resp("Too many attempts (max 3 — locked out)", "ErrorResponse")
          })),

      "/api/v1/account/resend_otp" => path_item(post:
        op_body("Resend OTP code", "2 - Account Registration", "resendOTP",
          """
          Request a fresh OTP if the previous one expired or was not received.
          Rate limited: 60-second cooldown between resends.
          Generates a new hash, invalidates the old code.
          """,
          "ResendOTPRequest",
          %{
            200 => resp("New OTP sent (check terminal again)", "MessageResponse"),
            400 => resp("Already verified or bad request", "ErrorResponse"),
            404 => resp("User not found", "ErrorResponse"),
            429 => resp("Rate limited (60s cooldown)", "ErrorResponse")
          })),

      # ── 3 Login / Token ──────────────────────────────────────────────────────
      "/api/v1/oauth/token" => path_item(post:
        op_body("Login — get Bearer token (Step 4)", "3 - Login / Token", "getToken",
          """
          **Step 4** — Login with nickname + password + client credentials from Step 1.

          **After getting the response:**
          1. Copy `access_token`
          2. Click **Authorize** button (lock icon, top right)
          3. Enter: `Bearer <your_access_token>`

          Also creates a session record tracking your IP and device type.

          Supports `grant_type: password` (user login) and
          `grant_type: client_credentials` (app-only token).
          """,
          "OAuthTokenRequest",
          %{
            200 => resp("Token issued. Copy access_token, click Authorize.", "OAuthTokenResponse"),
            400 => resp("Unsupported grant type", "ErrorResponse"),
            401 => resp("Invalid nickname or password", "ErrorResponse"),
            403 => resp("Account is disabled", "ErrorResponse")
          })),

      # ── 4 Verify Token & DID ─────────────────────────────────────────────────
      "/api/v1/accounts/verify_credentials" => path_item(get:
        op_auth("Verify token / credentials (Step 5)", "4 - Verify Token & DID", "verifyCredentials",
          """
          **Step 5** — Confirm your Bearer token is working.
          Returns full account info including your DID.
          If you get 401 here, go back and click **Authorize** and re-paste the token.
          """,
          %{
            200 => resp("Token valid. Account info returned.", "AccountResponse"),
            401 => resp("Missing or invalid token", "ErrorResponse")
          })),

      "/api/v1/accounts/did" => path_item(get:
        op_auth("Get your DID + namespace_key (Step 6)", "4 - Verify Token & DID", "getDID",
          """
          **Step 6** — Get your Decentralized Identifier and namespace_key.

          `namespace_key` = first 16 chars of DID fingerprint.
          Used as `tenant_id` in all DB tables and as the S3 path prefix
          (`user/<namespace_key>/`).

          If the user has no DID yet, one is auto-generated here.
          """,
          %{
            200 => resp("DID + namespace_key", "DIDResponse"),
            401 => resp("Unauthorized", "ErrorResponse")
          })),

      # ── 5 CAS Smoke Test ─────────────────────────────────────────────────────
      "/api/v1/test-namespace" => path_item(get:
        op("Full CAS pipeline smoke test — 9 auto-tests, no auth", "5 - CAS Smoke Test", "testNamespace",
          """
          **Step 7** — No auth needed. Runs 9 automated tests:

          | # | Test | What it proves |
          |---|------|----------------|
          | 1 | start_namespace   | Horde.DynamicSupervisor starts the GenServer |
          | 2 | namespace_exists  | Horde.Registry lookup works |
          | 3 | get_status        | GenServer state + health_status |
          | 4 | ingest_document   | SHA-256 -> dedup -> S3 -> cas_objects -> documents -> dedup_refs -> activities |
          | 5 | list_documents    | PostgreSQL query with tenant isolation |
          | 6 | get_document      | PostgreSQL lookup by doc_id |
          | 7 | search_documents  | Full-text search (tsvector/plainto_tsquery) |
          | 8 | registry_stats    | Horde.Registry.count |
          | 9 | stop_namespace    | GenServer.stop(:normal) |

          All 9 `status: passed` = full pipeline working.
          """,
          %{200 => resp("Smoke test results", "NamespaceSmokeTestResponse")})),

      # ── 6 Sessions ───────────────────────────────────────────────────────────
      "/api/v1/sessions" => %OpenApiSpex.PathItem{
        get: op_auth("List active sessions", "6 - Sessions", "listSessions",
          """
          Get all active login sessions for your account.
          Each session shows device type (desktop/mobile/tablet/api_client),
          IP address, user-agent, and timestamps.
          Use the session `id` to revoke a specific device.
          """,
          %{
            200 => resp("Active sessions list", "SessionsResponse"),
            401 => resp("Unauthorized", "ErrorResponse")
          }),
        delete: op_auth("Logout from ALL devices", "6 - Sessions", "revokeAllSessions",
          """
          Immediately revoke ALL active sessions and tokens across every device.
          Use this if you suspect your account has been compromised.
          All devices will need to log in again after this.
          """,
          %{
            200 => resp("All sessions revoked", "MessageResponse"),
            401 => resp("Unauthorized", "ErrorResponse")
          })
      },

      "/api/v1/sessions/{id}" => path_item(delete:
        op_auth_param("Revoke one session by ID", "6 - Sessions", "revokeSession",
          """
          Logout from a specific device.
          Get the `id` from `GET /api/v1/sessions`.
          Only revokes sessions belonging to the authenticated user.
          """,
          [session_id_param()],
          %{
            200 => resp("Session revoked", "MessageResponse"),
            404 => resp("Session not found", "ErrorResponse"),
            401 => resp("Unauthorized", "ErrorResponse")
          })),

      # ── 7 Password Reset ─────────────────────────────────────────────────────
      "/api/v1/account/forgot_password" => path_item(post:
        op_body("Request password reset email", "7 - Password Reset", "forgotPassword",
          """
          Send a reset link to the email address.
          Always returns success (never reveals whether email exists — prevents enumeration).
          Reset link expires in 15 minutes.
          """,
          "ForgotPasswordRequest",
          %{
            200 => resp("Reset email sent (or silently ignored if not found)", "ForgotPasswordResponse"),
            400 => resp("email field is required", "ErrorResponse"),
            429 => resp("Rate limited (60s between requests)", "ErrorResponse")
          })),

      "/api/v1/account/reset_password" => path_item(post:
        op_body("Reset password with token", "7 - Password Reset", "resetPassword",
          """
          Set a new password using `user_id` and `token` from the reset email link.
          Token is single-use, Pbkdf2-hashed, expires in 15 minutes, max 3 attempts.
          """,
          "ResetPasswordRequest",
          %{
            200 => resp("Password reset successful", "ResetPasswordResponse"),
            400 => resp("Invalid/expired token or passwords don't match", "ErrorResponse"),
            404 => resp("No pending reset for this account", "ErrorResponse"),
            429 => resp("Too many attempts (max 3)", "ErrorResponse")
          })),

      # ── 8 Account Management ─────────────────────────────────────────────────
      "/api/v1/pleroma/delete_account" => path_item(post:
        op_auth_body("Delete account (needs password)", "8 - Account Management", "deleteAccount",
          """
          Delete account permanently. Requires password confirmation.
          Calls `Auth.revoke_all_tokens` + `Session.revoke_all`.
          """,
          "PasswordConfirmRequest",
          %{
            200 => resp("Account deleted — status: success", "StatusResponse"),
            401 => resp("Unauthorized", "ErrorResponse"),
            403 => resp("Wrong password", "ErrorResponse")
          })),

      "/api/v1/pleroma/disable_account" => path_item(post:
        op_auth_body("Disable account (needs password)", "8 - Account Management", "disableAccount",
          """
          Set `is_active = false`. Requires password confirmation.
          Revokes all tokens and sessions. User can be re-enabled by an admin.
          """,
          "PasswordConfirmRequest",
          %{
            200 => resp("Account disabled — status: success", "StatusResponse"),
            401 => resp("Unauthorized", "ErrorResponse"),
            403 => resp("Wrong password", "ErrorResponse")
          })),

      "/api/v1/pleroma/accounts/mfa" => path_item(get:
        op_auth("Get MFA status", "8 - Account Management", "getMFA",
          "Returns MFA configuration. Currently always returns `enabled: false` — MFA not yet implemented.",
          %{
            200 => resp("MFA config", "MFAResponse"),
            401 => resp("Unauthorized", "ErrorResponse")
          })),

      # ── 9 DID Management ─────────────────────────────────────────────────────
      "/api/v1/did/generate" => path_item(post:
        op_body("Generate a new DID (testing only)", "9 - DID Management", "generateDID",
          """
          Generate a fresh `did:przma:<sha256-base64url-fingerprint>` for any user_id.
          Normally auto-generated at registration — use this for testing the DID module directly.
          """,
          "DIDGenerateRequest",
          %{200 => resp("DID generated", "DIDGenerateResponse")})),

      "/api/v1/did/validate" => path_item(post:
        op_body("Validate DID format", "9 - DID Management", "validateDID",
          "Check whether a string is a valid `did:przma:...` DID and return its namespace_key.",
          "DIDValidateRequest",
          %{
            200 => resp("Validation result", "DIDGenerateResponse"),
            400 => resp("did is required", "ErrorResponse")
          })),

      "/api/v1/did/{did}/resolve" => path_item(get:
        op_param("Resolve DID to namespace", "9 - DID Management", "resolveDID",
          "Look up a namespace record by its DID string.",
          [did_path_param()],
          %{
            200 => resp("Namespace info", "GenericResponse"),
            400 => resp("Invalid DID format", "ErrorResponse")
          })),

      "/api/v1/did/{did}" => path_item(get:
        op_param("Show DID info", "9 - DID Management", "showDID",
          "Get namespace info associated with a DID.",
          [did_path_param()],
          %{
            200 => resp("DID info", "GenericResponse"),
            400 => resp("Invalid DID", "ErrorResponse")
          })),

      # ── 10 Identity Resolution ───────────────────────────────────────────────
      "/api/v1/identity/resolve/{identifier}" => path_item(get:
        op_param("Resolve any identifier to namespace", "10 - Identity Resolution", "resolveIdentity",
          """
          Find a namespace by any of its identifiers:
          namespace_key, DID (`did:przma:...`), or Pleroma account ID.
          Uses `Manager.find_namespace/1` which tries all three strategies.
          """,
          [identifier_path_param()],
          %{
            200 => resp("Identity resolved", "GenericResponse"),
            404 => resp("Not found", "ErrorResponse")
          })),

      "/api/v1/identity/compare" => path_item(post:
        op_body("Compare two identifiers — same person?", "10 - Identity Resolution", "compareIdentity",
          "Check whether two identifiers (namespace_key, DID, Pleroma account ID) resolve to the same namespace/user.",
          "IdentityCompareRequest",
          %{
            200 => resp("Comparison result", "IdentityCompareResponse"),
            400 => resp("Both identifiers required", "ErrorResponse")
          })),

      "/api/v1/identity/{identifier}/identifiers" => path_item(get:
        op_param("Get all identifiers for a namespace", "10 - Identity Resolution", "getIdentifiers",
          "Returns all known identifiers (namespace_key, DID, Pleroma account ID) for the given namespace.",
          [identifier_path_param()],
          %{
            200 => resp("All identifiers", "GenericResponse"),
            404 => resp("Not found", "ErrorResponse")
          })),

      # ── 11 Namespace ─────────────────────────────────────────────────────────
      "/api/v1/namespaces" => %OpenApiSpex.PathItem{
        post: op_auth("Create or get namespace", "11 - Namespace", "createOrGetNamespace",
          "Create or retrieve the namespace for the authenticated user (keyed by DID).",
          %{
            200 => resp("Namespace", "GenericResponse"),
            401 => resp("Unauthorized", "ErrorResponse")
          }),
        get: op_auth("Get namespace status", "11 - Namespace", "getNamespace",
          "Get namespace status for the authenticated user.",
          %{
            200 => resp("Namespace status", "GenericResponse"),
            401 => resp("Unauthorized", "ErrorResponse"),
            404 => resp("Not found", "ErrorResponse")
          })
      },

      "/api/v1/namespaces/sync" => path_item(post:
        op_auth("Sync namespace with Pleroma", "11 - Namespace", "syncNamespace",
          "Sync the authenticated user's namespace document list with their Pleroma account.",
          %{
            200 => resp("Sync result", "GenericResponse"),
            401 => resp("Unauthorized", "ErrorResponse")
          })),

      "/api/v1/namespaces/account" => path_item(get:
        op_auth("Get account info in namespace", "11 - Namespace", "getNamespaceAccount",
          "Get account info stored in the authenticated user's namespace config.",
          %{
            200 => resp("Account info", "AccountResponse"),
            401 => resp("Unauthorized", "ErrorResponse")
          })),

      # ── 12 Sync ──────────────────────────────────────────────────────────────
      "/api/v1/sync/upload" => path_item(post:
        op_auth("Upload document (sync)", "12 - Sync", "syncUpload",
          "Upload a document through the sync pipeline. CAS dedup is applied automatically.",
          %{
            200 => resp("Upload result", "GenericResponse"),
            401 => resp("Unauthorized", "ErrorResponse")
          })),

      "/api/v1/sync/upload-url" => path_item(post:
        op_auth("Get presigned S3 upload URL", "12 - Sync", "getUploadUrl",
          "Get a presigned S3 URL for direct client-side upload.",
          %{
            200 => resp("Presigned URL", "GenericResponse"),
            401 => resp("Unauthorized", "ErrorResponse")
          })),

      "/api/v1/sync/apply" => path_item(post:
        op_auth("Apply sync changes", "12 - Sync", "applyChanges",
          "Apply a batch of CRDT sync changes from the client.",
          %{
            200 => resp("Apply result", "GenericResponse"),
            401 => resp("Unauthorized", "ErrorResponse")
          })),

      "/api/v1/sync/changes" => path_item(get:
        op_auth("Get sync changes", "12 - Sync", "getChanges",
          "Get pending changes for the client to pull.",
          %{
            200 => resp("Changes list", "GenericResponse"),
            401 => resp("Unauthorized", "ErrorResponse")
          })),

      "/api/v1/sync/stats" => path_item(get:
        op_auth("Get sync stats", "12 - Sync", "getSyncStats",
          "Get sync statistics for the authenticated user's namespace.",
          %{
            200 => resp("Sync stats", "GenericResponse"),
            401 => resp("Unauthorized", "ErrorResponse")
          })),

      "/api/v1/sync/download/{doc_id}" => path_item(get:
        op_auth_param("Download file", "12 - Sync", "downloadFile",
          "Get a signed S3 download URL for a document.",
          [%OpenApiSpex.Parameter{
            name: :doc_id, in: :path, required: true,
            description: "Document ID",
            schema: %Schema{type: :string, example: "doc-uuid-here"}
          }],
          %{
            200 => resp("Download URL", "GenericResponse"),
            401 => resp("Unauthorized", "ErrorResponse"),
            404 => resp("Not found", "ErrorResponse")
          })),

      "/api/v1/sync/crdt/upload" => path_item(post:
        op_auth("CRDT upload", "12 - Sync", "crdtUpload",
          "Upload a CRDT document state.",
          %{200 => resp("Result", "GenericResponse"), 401 => resp("Unauthorized", "ErrorResponse")})),

      "/api/v1/sync/crdt/upload_chunk" => path_item(post:
        op_auth("CRDT chunked upload", "12 - Sync", "chunkUpload",
          "Upload a chunk of a large CRDT document.",
          %{200 => resp("Result", "GenericResponse"), 401 => resp("Unauthorized", "ErrorResponse")})),

      "/api/v1/sync/crdt/finalize_upload" => path_item(post:
        op_auth("Finalize CRDT upload", "12 - Sync", "finalizeUpload",
          "Finalize a chunked CRDT upload after all chunks are sent.",
          %{200 => resp("Result", "GenericResponse"), 401 => resp("Unauthorized", "ErrorResponse")})),

      "/api/v1/sync/stream" => path_item(get:
        op_auth("SSE event stream", "12 - Sync", "eventStream",
          "Server-Sent Events stream for real-time push sync events (Phase 3).",
          %{200 => resp("SSE stream", "GenericResponse"), 401 => resp("Unauthorized", "ErrorResponse")})),

      # ── 13 Analytics ─────────────────────────────────────────────────────────
      "/api/v1/analytics/ingest" => path_item(post:
        op_auth("Ingest Arrow IPC batch", "13 - Analytics", "analyticsIngest",
          "Receive an Apache Arrow IPC batch from the Tauri client. Converted to Parquet and stored in S3.",
          %{200 => resp("Ingest result", "GenericResponse"), 401 => resp("Unauthorized", "ErrorResponse")})),

      "/api/v1/analytics/schema" => path_item(get:
        op_auth("Get Arrow schema reference", "13 - Analytics", "analyticsSchema",
          "Return the Arrow IPC schema expected by the ingest endpoint.",
          %{200 => resp("Arrow schema", "GenericResponse"), 401 => resp("Unauthorized", "ErrorResponse")})),

      # ── 14 Media NLP ─────────────────────────────────────────────────────────
      "/api/v1/media/transcribe" => path_item(post:
        op_auth("Transcribe audio/video", "14 - Media NLP", "transcribeMedia",
          "Submit audio/video for Whisper transcription. Returns transcript + Arrow metadata.",
          %{200 => resp("Transcript + metadata", "GenericResponse"), 401 => resp("Unauthorized", "ErrorResponse")})),

      "/api/v1/media/analyze" => path_item(post:
        op_auth("Analyze video frames", "14 - Media NLP", "analyzeMedia",
          "Extract metadata from video frames. Returns Arrow IPC metadata batch.",
          %{200 => resp("Frame metadata", "GenericResponse"), 401 => resp("Unauthorized", "ErrorResponse")})),

      # ── 15 Vault / DID Well-Known ────────────────────────────────────────────
      "/api/v1/vault/epoch/current" => path_item(get:
        op("Get current vault epoch key", "15 - Vault", "getEpochCurrent",
          "Returns the current vault epoch key used for client-side encryption.",
          %{200 => resp("Epoch key", "GenericResponse")})),

      "/.well-known/did.json" => path_item(get:
        op("DID document (did:web resolution)", "15 - Vault", "didDocument",
          "Returns the DID document for this server at the well-known path, enabling did:web resolution.",
          %{200 => resp("DID document", "GenericResponse")}))
    }
  end

  # ===========================================================================
  # Schema definitions
  # ===========================================================================

  defp build_schemas do
    %{
      # ── Request schemas ──────────────────────────────────────────────────────
      "RegisterAppRequest"     => register_app_request(),
      "RegisterAccountRequest" => register_account_request(),
      "VerifyEmailRequest"     => verify_email_request(),
      "ResendOTPRequest"       => resend_otp_request(),
      "OAuthTokenRequest"      => oauth_token_request(),
      "ForgotPasswordRequest"  => forgot_password_request(),
      "ResetPasswordRequest"   => reset_password_request(),
      "PasswordConfirmRequest" => password_confirm_request(),
      "DIDGenerateRequest"     => did_generate_request(),
      "DIDValidateRequest"     => did_validate_request(),
      "IdentityCompareRequest" => identity_compare_request(),

      # ── Response schemas ─────────────────────────────────────────────────────
      "HealthResponse"              => health_response(),
      "CaptchaResponse"             => captcha_response(),
      "RegisterAppResponse"         => register_app_response(),
      "RegisterAccountResponse"     => register_account_response(),
      "VerifyEmailResponse"         => verify_email_response(),
      "OAuthTokenResponse"          => oauth_token_response(),
      "AccountResponse"             => account_response(),
      "DIDResponse"                 => did_response(),
      "DIDGenerateResponse"         => did_generate_response(),
      "ForgotPasswordResponse"      => forgot_password_response(),
      "ResetPasswordResponse"       => reset_password_response(),
      "SessionsResponse"            => sessions_response(),
      "SessionObject"               => session_object(),
      "NamespaceSmokeTestResponse"  => namespace_smoke_test_response(),
      "IdentityCompareResponse"     => identity_compare_response(),
      "MFAResponse"                 => mfa_response(),
      "ErrorResponse"               => error_response(),
      "MessageResponse"             => message_response(),
      "StatusResponse"              => status_response(),
      "GenericResponse"             => generic_response()
    }
  end

  defp build_security_schemes do
    %{
      "BearerAuth" => %OpenApiSpex.SecurityScheme{
        type:        "http",
        scheme:      "bearer",
        description: "OAuth Bearer token. Obtain from POST /api/v1/oauth/token. In Swagger UI click Authorize and enter: Bearer <your_token>"
      }
    }
  end

  # ── Request schemas ──────────────────────────────────────────────────────────

  defp register_app_request do
    %Schema{
      type: :object, title: "RegisterAppRequest",
      required: [:client_name],
      properties: %{
        client_name:   %Schema{type: :string, example: "PRZMA Swagger Test"},
        redirect_uris: %Schema{type: :string, example: "urn:ietf:wg:oauth:2.0:oob"},
        scopes:        %Schema{type: :string, example: "read write"},
        website:       %Schema{type: :string, example: "https://example.com"}
      }
    }
  end

  defp register_account_request do
    %Schema{
      type: :object, title: "RegisterAccountRequest",
      required: [:nickname, :email, :password],
      properties: %{
        nickname:         %Schema{type: :string,  example: "testuser1",        description: "1 to 30 characters"},
        email:            %Schema{type: :string,  example: "test@example.com", format: :email},
        password:         %Schema{type: :string,  example: "password123",      description: "Minimum 6 characters", format: :password},
        fullname:         %Schema{type: :string,  example: "Test User"},
        bio:              %Schema{type: :string,  example: "Hello world"},
        captcha_token:    %Schema{type: :string,  example: "",                 description: "Leave empty — captcha is optional"},
        captcha_solution: %Schema{type: :string,  example: "",                 description: "Leave empty — captcha is optional"}
      }
    }
  end

  defp verify_email_request do
    %Schema{
      type: :object, title: "VerifyEmailRequest",
      required: [:user_id, :code],
      properties: %{
        user_id: %Schema{type: :string, example: "mK92pqRtYuIoplKj", description: "user_id from register response"},
        code:    %Schema{type: :string, example: "123456",           description: "6-digit OTP from server terminal logs"}
      }
    }
  end

  defp resend_otp_request do
    %Schema{
      type: :object, title: "ResendOTPRequest",
      required: [:user_id],
      properties: %{
        user_id: %Schema{type: :string, example: "mK92pqRtYuIoplKj"}
      }
    }
  end

  defp oauth_token_request do
    %Schema{
      type: :object, title: "OAuthTokenRequest",
      required: [:grant_type],
      properties: %{
        grant_type:    %Schema{type: :string, enum: ["password", "client_credentials"], example: "password"},
        username:      %Schema{type: :string, example: "testuser1",              description: "Required for grant_type=password"},
        password:      %Schema{type: :string, example: "password123",            description: "Required for grant_type=password", format: :password},
        client_id:     %Schema{type: :string, example: "K7mF2xQ9rPvN3wLt",      description: "From POST /api/v1/apps"},
        client_secret: %Schema{type: :string, example: "xyz789secretabc123def", description: "From POST /api/v1/apps"},
        scope:         %Schema{type: :string, example: "read write"}
      }
    }
  end

  defp forgot_password_request do
    %Schema{
      type: :object, title: "ForgotPasswordRequest",
      required: [:email],
      properties: %{
        email: %Schema{type: :string, example: "test@example.com", format: :email}
      }
    }
  end

  defp reset_password_request do
    %Schema{
      type: :object, title: "ResetPasswordRequest",
      required: [:user_id, :token, :password, :password_confirmation],
      properties: %{
        user_id:               %Schema{type: :string, example: "mK92pqRtYuIoplKj"},
        token:                 %Schema{type: :string, example: "reset-token-from-email-link"},
        password:              %Schema{type: :string, example: "newpassword123", format: :password, description: "Minimum 8 characters"},
        password_confirmation: %Schema{type: :string, example: "newpassword123", format: :password}
      }
    }
  end

  defp password_confirm_request do
    %Schema{
      type: :object, title: "PasswordConfirmRequest",
      required: [:password],
      properties: %{
        password: %Schema{type: :string, example: "password123", format: :password}
      }
    }
  end

  defp did_generate_request do
    %Schema{
      type: :object, title: "DIDGenerateRequest",
      properties: %{
        user_id: %Schema{type: :string, example: "any-identifier", description: "Optional — random UUID used if omitted"}
      }
    }
  end

  defp did_validate_request do
    %Schema{
      type: :object, title: "DIDValidateRequest",
      required: [:did],
      properties: %{
        did: %Schema{type: :string, example: "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"}
      }
    }
  end

  defp identity_compare_request do
    %Schema{
      type: :object, title: "IdentityCompareRequest",
      required: [:identifier1, :identifier2],
      properties: %{
        identifier1: %Schema{type: :string, example: "k7mf2xq9rpvn3wlt"},
        identifier2: %Schema{type: :string, example: "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"}
      }
    }
  end

  # ── Response schemas ─────────────────────────────────────────────────────────

  defp health_response do
    %Schema{
      type: :object, title: "HealthResponse",
      properties: %{
        status:    %Schema{type: :string,  example: "ok"},
        timestamp: %Schema{type: :string,  example: "2026-03-30T10:00:00Z"},
        version:   %Schema{type: :string,  example: "0.1.0"},
        services: %Schema{
          type: :object,
          properties: %{
            postgres:       service_schema("healthy",   "PostgreSQL OK"),
            object_storage: service_schema("healthy",   "S3 accessible (perkeep)"),
            sqld:           service_schema("unhealthy", "sqld optional — sync not required"),
            horde:          service_schema("healthy",   "Horde active, 0 registrations")
          }
        }
      }
    }
  end

  defp service_schema(status, message) do
    %Schema{
      type: :object,
      properties: %{
        status:  %Schema{type: :string, example: status},
        message: %Schema{type: :string, example: message}
      }
    }
  end

  defp captcha_response do
    %Schema{
      type: :object, title: "CaptchaResponse",
      properties: %{
        type:          %Schema{type: :string,  example: "image"},
        token:         %Schema{type: :string,  example: "oU-MJtbyHvXrZ9..."},
        answer_data:   %Schema{type: :string,  example: "A8F3K2", description: "The captcha answer — pass as captcha_solution in register"},
        seconds_valid: %Schema{type: :integer, example: 300}
      }
    }
  end

  defp register_app_response do
    %Schema{
      type: :object, title: "RegisterAppResponse",
      properties: %{
        id:            %Schema{type: :string, example: "550e8400-e29b-41d4-a716-446655440000"},
        name:          %Schema{type: :string, example: "PRZMA Swagger Test"},
        website:       %Schema{type: :string, nullable: true},
        redirect_uri:  %Schema{type: :string, example: "urn:ietf:wg:oauth:2.0:oob"},
        client_id:     %Schema{type: :string, example: "K7mF2xQ9rPvN3wLt",       description: "SAVE THIS"},
        client_secret: %Schema{type: :string, example: "xyz789secretabc123def456", description: "SAVE THIS"},
        vapid_key:     %Schema{type: :string, nullable: true}
      }
    }
  end

  defp register_account_response do
    %Schema{
      type: :object, title: "RegisterAccountResponse",
      properties: %{
        message:   %Schema{type: :string, example: "Registration successful. Check test@example.com for your 6-digit verification code."},
        user_id:   %Schema{type: :string, example: "mK92pqRtYuIoplKj", description: "SAVE THIS — needed for verify_email"},
        email:     %Schema{type: :string, example: "test@example.com"},
        next_step: %Schema{type: :string, example: "POST /api/v1/account/verify_email with {user_id, code}"}
      }
    }
  end

  defp verify_email_response do
    %Schema{
      type: :object, title: "VerifyEmailResponse",
      properties: %{
        ok:        %Schema{type: :boolean, example: true},
        message:   %Schema{type: :string,  example: "Email verified successfully. You can now log in."},
        user_id:   %Schema{type: :string,  example: "mK92pqRtYuIoplKj"},
        next_step: %Schema{type: :string,  example: "POST /api/v1/oauth/token"}
      }
    }
  end

  defp oauth_token_response do
    %Schema{
      type: :object, title: "OAuthTokenResponse",
      description: "Login response. Includes access_token, DID, and creates a session record.",
      properties: %{
        access_token:  %Schema{type: :string,  example: "a-GvXrUzM9FvK7mF2xQ9rPvN3wLtZoYeA8hCbDs...", description: "SAVE THIS — use as: Bearer <access_token>"},
        token_type:    %Schema{type: :string,  example: "Bearer"},
        scope:         %Schema{type: :string,  example: "read write"},
        expires_in:    %Schema{type: :integer, example: 2592000, description: "30 days in seconds"},
        refresh_token: %Schema{type: :string,  example: "refresh_abc123..."},
        created_at:    %Schema{type: :integer, example: 1740614645},
        me:            %Schema{type: :string,  example: "testuser1"},
        did:           %Schema{type: :string,  example: "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"}
      }
    }
  end

  defp account_response do
    %Schema{
      type: :object, title: "AccountResponse",
      properties: %{
        id:           %Schema{type: :string,  example: "mK92pqRtYuIoplKj"},
        username:     %Schema{type: :string,  example: "testuser1"},
        acct:         %Schema{type: :string,  example: "testuser1"},
        display_name: %Schema{type: :string,  example: "Test User"},
        note:         %Schema{type: :string,  example: ""},
        avatar:       %Schema{type: :string,  example: ""},
        created_at:   %Schema{type: :string,  example: "2026-03-30T10:00:00Z"},
        locked:       %Schema{type: :boolean, example: false},
        bot:          %Schema{type: :boolean, example: false},
        did:          %Schema{type: :string,  example: "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"},
        pleroma: %Schema{
          type: :object,
          properties: %{
            is_admin:     %Schema{type: :boolean, example: false},
            is_moderator: %Schema{type: :boolean, example: false},
            is_active:    %Schema{type: :boolean, example: true}
          }
        }
      }
    }
  end

  defp did_response do
    %Schema{
      type: :object, title: "DIDResponse",
      properties: %{
        user_id:       %Schema{type: :string, example: "mK92pqRtYuIoplKj"},
        nickname:      %Schema{type: :string, example: "testuser1"},
        did:           %Schema{type: :string, example: "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"},
        did_method:    %Schema{type: :string, example: "przma"},
        fingerprint:   %Schema{type: :string, example: "K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"},
        namespace_key: %Schema{type: :string, example: "k7mf2xq9rpvn3wlt", description: "First 16 chars of fingerprint. Used as tenant_id in all DB tables and S3 path prefix."},
        description:   %Schema{type: :string, example: "This DID is your unique decentralized identifier. One per user, never changes."}
      }
    }
  end

  defp did_generate_response do
    %Schema{
      type: :object, title: "DIDGenerateResponse",
      properties: %{
        did:           %Schema{type: :string,  example: "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"},
        namespace_key: %Schema{type: :string,  example: "k7mf2xq9rpvn3wlt"},
        valid:         %Schema{type: :boolean, example: true}
      }
    }
  end

  defp forgot_password_response do
    %Schema{
      type: :object, title: "ForgotPasswordResponse",
      properties: %{
        ok:      %Schema{type: :boolean, example: true},
        message: %Schema{type: :string,  example: "If that email is registered, a reset link has been sent. Check your inbox."},
        note:    %Schema{type: :string,  example: "Link expires in 15 minutes."}
      }
    }
  end

  defp reset_password_response do
    %Schema{
      type: :object, title: "ResetPasswordResponse",
      properties: %{
        ok:        %Schema{type: :boolean, example: true},
        message:   %Schema{type: :string,  example: "Password reset successfully. You can now log in."},
        next_step: %Schema{type: :string,  example: "POST /api/v1/oauth/token"}
      }
    }
  end

  defp sessions_response do
    %Schema{
      type: :object, title: "SessionsResponse",
      description: "All active sessions for the authenticated user",
      properties: %{
        sessions: %Schema{
          type: :array,
          items: %Reference{"$ref": "#/components/schemas/SessionObject"}
        }
      }
    }
  end

  defp session_object do
    %Schema{
      type: :object, title: "SessionObject",
      properties: %{
        id:             %Schema{type: :string, description: "Session ID — pass to DELETE /api/v1/sessions/:id to revoke", example: "abc123xyz"},
        device:         %Schema{type: :string, description: "desktop | mobile | tablet | api_client | unknown", example: "desktop"},
        ip_address:     %Schema{type: :string, example: "192.168.1.1"},
        user_agent:     %Schema{type: :string, example: "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"},
        last_active_at: %Schema{type: :string, format: :"date-time"},
        created_at:     %Schema{type: :string, format: :"date-time", description: "Login time"}
      }
    }
  end

  defp namespace_smoke_test_response do
    %Schema{
      type: :object, title: "NamespaceSmokeTestResponse",
      properties: %{
        namespace_key: %Schema{type: :string, example: "test_ns_smoke_001"},
        tests: %Schema{
          type: :array,
          items: %Schema{
            type: :object,
            properties: %{
              test:   %Schema{type: :string, example: "start_namespace"},
              status: %Schema{type: :string, example: "passed", enum: ["passed", "failed", "skipped"]},
              data:   %Schema{type: :object, additionalProperties: true}
            }
          }
        }
      }
    }
  end

  defp identity_compare_response do
    %Schema{
      type: :object, title: "IdentityCompareResponse",
      properties: %{
        identifier1:   %Schema{type: :string},
        identifier2:   %Schema{type: :string},
        same_identity: %Schema{type: :boolean, example: true}
      }
    }
  end

  defp mfa_response do
    %Schema{
      type: :object, title: "MFAResponse",
      properties: %{
        enabled:      %Schema{type: :boolean, example: false},
        backup_codes: %Schema{type: :array, items: %Schema{type: :string}, example: []},
        totp: %Schema{
          type: :object,
          properties: %{
            enabled:          %Schema{type: :boolean, example: false},
            provisioning_uri: %Schema{type: :string, nullable: true}
          }
        }
      }
    }
  end

  defp error_response do
    %Schema{
      type: :object, title: "ErrorResponse",
      required: [:error],
      properties: %{
        error: %Schema{type: :string, example: "Invalid or expired token"}
      }
    }
  end

  defp message_response do
    %Schema{
      type: :object, title: "MessageResponse",
      properties: %{
        message: %Schema{type: :string, example: "Operation successful"}
      }
    }
  end

  defp status_response do
    %Schema{
      type: :object, title: "StatusResponse",
      properties: %{
        status: %Schema{type: :string, example: "success"}
      }
    }
  end

  defp generic_response do
    %Schema{
      type: :object, title: "GenericResponse",
      additionalProperties: true
    }
  end

  # ===========================================================================
  # Builder helpers
  # ===========================================================================

  defp path_item(opts) do
    struct(OpenApiSpex.PathItem, opts)
  end

  defp op(summary, tag, op_id, desc, responses) do
    %OpenApiSpex.Operation{
      summary:     summary,
      tags:        [tag],
      operationId: op_id,
      description: desc,
      responses:   Enum.into(responses, %{})
    }
  end

  defp op_auth(summary, tag, op_id, desc, responses) do
    %OpenApiSpex.Operation{
      summary:     summary,
      tags:        [tag],
      operationId: op_id,
      description: desc,
      security:    [%{"BearerAuth" => []}],
      responses:   Enum.into(responses, %{})
    }
  end

  defp op_body(summary, tag, op_id, desc, schema_name, responses) do
    %OpenApiSpex.Operation{
      summary:     summary,
      tags:        [tag],
      operationId: op_id,
      description: desc,
      requestBody: json_body(schema_name),
      responses:   Enum.into(responses, %{})
    }
  end

  defp op_auth_body(summary, tag, op_id, desc, schema_name, responses) do
    %OpenApiSpex.Operation{
      summary:     summary,
      tags:        [tag],
      operationId: op_id,
      description: desc,
      security:    [%{"BearerAuth" => []}],
      requestBody: json_body(schema_name),
      responses:   Enum.into(responses, %{})
    }
  end

  defp op_param(summary, tag, op_id, desc, parameters, responses) do
    %OpenApiSpex.Operation{
      summary:     summary,
      tags:        [tag],
      operationId: op_id,
      description: desc,
      parameters:  parameters,
      responses:   Enum.into(responses, %{})
    }
  end

  defp op_auth_param(summary, tag, op_id, desc, parameters, responses) do
    %OpenApiSpex.Operation{
      summary:     summary,
      tags:        [tag],
      operationId: op_id,
      description: desc,
      security:    [%{"BearerAuth" => []}],
      parameters:  parameters,
      responses:   Enum.into(responses, %{})
    }
  end

  defp json_body(schema_name) do
    OpenApiSpex.Operation.request_body(
      "Request body", "application/json",
      %Reference{"$ref": "#/components/schemas/#{schema_name}"},
      required: true
    )
  end

  defp resp(desc, schema_name) do
    OpenApiSpex.Operation.response(
      desc, "application/json",
      %Reference{"$ref": "#/components/schemas/#{schema_name}"}
    )
  end

  defp session_id_param do
    %OpenApiSpex.Parameter{
      name:        :id,
      in:          :path,
      required:    true,
      description: "Session ID from GET /api/v1/sessions",
      schema:      %Schema{type: :string, example: "abc123xyz"}
    }
  end

  defp did_path_param do
    %OpenApiSpex.Parameter{
      name:        :did,
      in:          :path,
      required:    true,
      description: "Full DID string (did:przma:...)",
      schema:      %Schema{type: :string, example: "did:przma:K7mF2xQ9rPvN3wLtZoYeA8hCbDsJuGiMnRkXpWqTcVlH"}
    }
  end

  defp identifier_path_param do
    %OpenApiSpex.Parameter{
      name:        :identifier,
      in:          :path,
      required:    true,
      description: "namespace_key, DID, or Pleroma account ID",
      schema:      %Schema{type: :string, example: "k7mf2xq9rpvn3wlt"}
    }
  end
end
