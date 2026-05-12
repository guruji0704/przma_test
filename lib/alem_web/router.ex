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

  pipeline :admin_auth do
    plug AlemWeb.Plugs.AdminAuth
  end

  pipeline :admin_layout do
    plug :put_root_layout, html: {AlemWeb.Layouts, :admin_root}
  end

  pipeline :user_layout do
    plug :put_root_layout, html: {AlemWeb.Layouts, :user_root}
  end

  pipeline :user_auth do
    plug AlemWeb.Plugs.UserAuth
  end

    # Studio layout pipeline
  pipeline :studio_layout do
    plug :put_root_layout, html: {AlemWeb.Layouts, :studio_root}
  end

  # ── Public browser routes ─────────────────────────────────────────────────
  scope "/", AlemWeb do
    pipe_through :browser
    get "/reset-password", AuthController, :reset_password_page
    get "/", PageController, :redirect_to_admin
    live "/demo", DemoLive
    get  "/panel/login",  UserSessionController, :new
    post "/panel/login",  UserSessionController, :create
    get  "/panel/logout", UserSessionController, :delete
  end

  # ── Admin login/logout (public — no admin_auth guard) ─────────────────────
  scope "/admin", AlemWeb do
    pipe_through :browser
    get    "/login",  AdminSessionController, :new
    post   "/login",  AdminSessionController, :create
    delete "/logout", AdminSessionController, :delete
    # Fallback: browser GET /admin/logout (direct URL navigation, expired session)
    get    "/logout", AdminSessionController, :delete
  end

  # ── Admin Panel (LiveView — protected) ────────────────────────────────────
  scope "/admin", AlemWeb do
    pipe_through [:browser, :admin_auth, :admin_layout]
    live "/", AdminLive, :index
  end

# ── user Panel (LiveView — protected) ────────────────────────────────────
  scope "/", AlemWeb do
    pipe_through [:browser, :user_layout, :user_auth]
    live "/panel", UserLive, :index
    live "/chat/:id", ChatLive, :show
    live "/chats",    ChatsLive,  :index
    live "/social", SocialLive, :index
  end

  # PRZMA Studio (protected, opens in new tab)
  scope "/", AlemWeb do
    pipe_through [:browser, :studio_layout, :user_auth]
    live "/studio",     StudioLive, :new
    live "/studio/:id", StudioLive, :edit
  end

  # ── API v1 ────────────────────────────────────────────────────────────────
  scope "/api/v1", AlemWeb do
    pipe_through :api

    get "/test-namespace", NamespaceController, :test

    # DID (Decentralized Identifier) Endpoints
    post "/did/generate",     DIDController, :generate
    post "/did/validate",     DIDController, :validate
    get  "/did/:did/resolve", DIDController, :resolve
    get  "/did/:did",         DIDController, :show

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
    post "/apps",                        AuthController, :register_app
    post "/account/register",            AuthController, :register_account
    get  "/pleroma/captcha",             AuthController, :get_captcha
    post "/pleroma/delete_account",      AuthController, :delete_account
    post "/pleroma/disable_account",     AuthController, :disable_account
    get  "/pleroma/accounts/mfa",        AuthController, :get_mfa
    post "/oauth/token",                 AuthController, :get_token
    get  "/accounts/verify_credentials", AuthController, :verify_credentials
    get  "/accounts/did",                AuthController, :get_did

    # Session Endpoints
    get    "/sessions",     AuthController, :list_sessions
    delete "/sessions",     AuthController, :revoke_all_sessions
    delete "/sessions/:id", AuthController, :revoke_session

    # Email verification & OTP
    post "/account/verify_email", AuthController, :verify_email
    post "/account/resend_otp",   AuthController, :resend_otp

    # Password reset
    post "/account/reset_password",  AuthController, :reset_password
    post "/account/forgot_password", AuthController, :forgot_password

    # File viewer — secure presigned URL
    get "/files/:id/url", FileController, :presign
  end

  # ── Vault epoch key (public, no auth) ─────────────────────────────────────
  scope "/api/v1/vault", AlemWeb do
    pipe_through :api
    get "/epoch/current", EpochController, :current
  end

  # ── DID document at well-known path (did:web resolution) ──────────────────
  scope "/", AlemWeb do
    pipe_through :api
    get "/.well-known/did.json", EpochController, :did_document
  end

  # ── Analytics ─────────────────────────────────────────────────────────────
  scope "/api/v1/analytics", AlemWeb do
    pipe_through :api
    post "/ingest", AnalyticsController, :ingest
    get  "/schema", AnalyticsController, :schema
  end

  # ── Media NLP ─────────────────────────────────────────────────────────────
  scope "/api/v1/media", AlemWeb do
    pipe_through :api
    post "/transcribe", MediaController, :transcribe
    post "/analyze",    MediaController, :analyze
  end

  # ── Sync ──────────────────────────────────────────────────────────────────
  scope "/api/v1/sync", AlemWeb do
    pipe_through :api

    post "/upload-url",           SyncController, :get_upload_url
    post "/apply",                SyncController, :apply_changes
    get  "/changes",              SyncController, :get_changes
    get  "/stats",                SyncController, :get_stats
    get  "/download/:doc_id",     SyncController, :download_file
    post "/upload",               SyncController, :crdt_upload
    post "/crdt/upload",          SyncController, :crdt_upload
    post "/crdt/upload_chunk",    SyncController, :chunk_upload
    post "/crdt/finalize_upload", SyncController, :finalize_upload

    # V2 Parallel Sync
    post "/v2/initiate", SyncController, :v2_initiate
    post "/v2/part",     SyncController, :v2_upload_part
    post "/v2/complete", SyncController, :v2_complete

    # SSE stream
    get "/stream", SyncController, :event_stream
  end

  # ── GraphQL ───────────────────────────────────────────────────────────────
  scope "/graphql" do
    pipe_through :api
    forward "/", Absinthe.Plug,
      schema: AlemWeb.Schema,
      json_codec: Jason
  end

  # ── GraphiQL (dev only) ───────────────────────────────────────────────────
  if Mix.env() == :dev do
    scope "/graphiql" do
      pipe_through :browser
      forward "/", Absinthe.Plug.GraphiQL,
        schema: AlemWeb.Schema,
        interface: :simple
    end
  end

  # ── Health check ──────────────────────────────────────────────────────────
  scope "/api", AlemWeb do
    pipe_through :api
    get "/health", HealthController, :check
  end

  # ── Dev tools ─────────────────────────────────────────────────────────────
  if Application.compile_env(:alem, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: AlemWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
