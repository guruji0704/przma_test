defmodule AlemWeb.Router do
  use AlemWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AlemWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: AlemWeb.Swagger
  end

  pipeline :swagger do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: AlemWeb.Swagger
  end

  scope "/api/v1", AlemWeb do
    pipe_through :api

    get "/test-namespace", NamespaceController, :test

    # DID (Decentralized Identifier) Endpoints
    post "/did/generate",      DIDController, :generate
    post "/did/validate",      DIDController, :validate
    get  "/did/:did/resolve",  DIDController, :resolve
    get  "/did/:did",          DIDController, :show

    # Identity Resolution Endpoints
    get  "/identity/resolve/:identifier",     IdentityController, :resolve
    post "/identity/compare",                 IdentityController, :compare
    get  "/identity/:identifier/identifiers", IdentityController, :identifiers

    # Namespace Endpoints
    post "/namespaces",         NamespacePleromaController, :create_or_get
    get  "/namespaces",         NamespacePleromaController, :get
    post "/namespaces/sync",    NamespacePleromaController, :sync
    get  "/namespaces/account", NamespacePleromaController, :get_account_info

    # Auth Endpoints
    post "/apps",                     AuthController, :register_app
    post "/account/register",         AuthController, :register_account
    get  "/pleroma/captcha",           AuthController, :get_captcha
    post "/pleroma/delete_account",    AuthController, :delete_account
    post "/pleroma/disable_account",   AuthController, :disable_account
    get  "/pleroma/accounts/mfa",      AuthController, :get_mfa
    post "/oauth/token",               AuthController, :get_token
    get  "/accounts/verify_credentials", AuthController, :verify_credentials
    get  "/accounts/did",              AuthController, :get_did

    # ── Session Endpoints ──────────────────────────────────
    get    "/sessions",      AuthController, :list_sessions        # list all active sessions
    # delete "/sessions/all",  AuthController, :revoke_all_sessions  # logout from every device
    # delete "/sessions/:id",  AuthController, :revoke_session       # logout from one device
    delete "/sessions", AuthController, :revoke_all_sessions
    delete "/sessions/:id", AuthController, :revoke_session



    post "/account/verify_email", AuthController, :verify_email
    post "/account/resend_otp",   AuthController, :resend_otp

    post "/account/reset_password",  AuthController, :reset_password
    post "/account/forgot_password", AuthController, :forgot_password

  end
  scope "/", AlemWeb do
    pipe_through :browser
    get "/reset-password", AuthController, :reset_password_page
  end



  # ── Vault epoch key + DID document (public, no auth) ───────────────────
  scope "/api/v1/vault", AlemWeb do
    pipe_through :api
    get "/epoch/current", EpochController, :current
  end

  # DID document at well-known path (did:web resolution)
  scope "/", AlemWeb do
    pipe_through :api
    get "/.well-known/did.json", EpochController, :did_document
  end

  # ── Analytics: Arrow IPC ingest from Tauri client → Parquet → S3 ────────
  scope "/api/v1/analytics", AlemWeb do
    pipe_through :api
    post "/ingest",  AnalyticsController, :ingest   # receive Arrow IPC batch
    get  "/schema",  AnalyticsController, :schema   # Arrow schema reference
  end

  # ── Media NLP: audio/video transcription + Arrow metadata ────────────────
  scope "/api/v1/media", AlemWeb do
    pipe_through :api
    post "/transcribe",  MediaController, :transcribe  # audio → Whisper → Arrow
    post "/analyze",     MediaController, :analyze     # video frames → metadata Arrow
  end

  scope "/api/v1/sync", AlemWeb do
    pipe_through :api

    post "/upload-url",   SyncController, :get_upload_url
    post "/apply",        SyncController, :apply_changes
    get  "/changes",      SyncController, :get_changes
    get  "/stats",        SyncController, :get_stats
    get  "/download/:doc_id", SyncController, :download_file
    post "/upload",       SyncController, :upload_document
    post "/crdt/upload",          SyncController, :crdt_upload
    post "/crdt/upload_chunk",    SyncController, :chunk_upload
    post "/crdt/finalize_upload", SyncController, :finalize_upload

    # V2 Parallel Sync (Track A)
    post "/v2/initiate", SyncController, :v2_initiate
    post "/v2/part",     SyncController, :v2_upload_part
    post "/v2/complete", SyncController, :v2_complete

    # SSE stream for real-time push events (Phase 3)
    get  "/stream",       SyncController, :event_stream
  end

  # ── GraphQL endpoint ────────────────────────────────────────────────────────
  scope "/graphql" do
    pipe_through :api
    forward "/", Absinthe.Plug,
      schema: AlemWeb.Schema,
      json_codec: Jason
  end

  # ── GraphiQL browser UI (dev only) ─────────────────────────────────────────
  if Mix.env() == :dev do
    scope "/graphiql" do
      pipe_through :browser
      forward "/", Absinthe.Plug.GraphiQL,
        schema: AlemWeb.Schema,
        interface: :simple
    end
  end

  scope "/api", AlemWeb do
    pipe_through :api
    get "/health", HealthController, :check
  end

  if Application.compile_env(:alem, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: AlemWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # ── Admin Panel (LiveView) ────────────────────────────────────────────────
  pipeline :admin_auth do
    plug :browser
  end

  scope "/admin", AlemWeb do
    pipe_through [:browser, :admin_auth]
    live "/",          AdminLive, :index
    live "/users",     AdminLive, :users
    live "/vault",     AdminLive, :vault
    live "/dupes",     AdminLive, :duplicates
  end
end
