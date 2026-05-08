defmodule AlemWeb.Router do
  use AlemWeb, :router

  # =======================
  # PIPELINES
  # =======================

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

    # Swagger Spec Injection
    plug OpenApiSpex.Plug.PutApiSpec,
      module: AlemWeb.Swagger
  end

  pipeline :admin_auth do
    plug AlemWeb.Plugs.AdminAuth
  end

  pipeline :admin_layout do
    plug :put_root_layout, html: {AlemWeb.Layouts, :admin_root}
  end

  # =======================
  # PUBLIC ROUTES
  # =======================

  scope "/", AlemWeb do
    pipe_through :browser

    get "/", PageController, :redirect_to_admin
    get "/reset-password", AuthController, :reset_password_page
  end

  # =======================
  # ADMIN AUTH
  # =======================

  scope "/admin", AlemWeb do
    pipe_through :browser

    get    "/login",  AdminSessionController, :new
    post   "/login",  AdminSessionController, :create
    delete "/logout", AdminSessionController, :delete
    get    "/logout", AdminSessionController, :delete
  end

  # =======================
  # ADMIN PANEL
  # =======================

  scope "/admin", AlemWeb do
    pipe_through [:browser, :admin_auth, :admin_layout]

    live "/", AdminLive, :index
  end
#
  # =======================
  # API v1
  # =======================

  scope "/api/v1", AlemWeb do
    pipe_through :api

    get "/test-namespace", NamespaceController, :test

    # DID
    post "/did/generate",     DIDController, :generate
    post "/did/validate",     DIDController, :validate
    get  "/did/:did/resolve", DIDController, :resolve
    get  "/did/:did",         DIDController, :show

    # Identity
    get  "/identity/resolve/:identifier",     IdentityController, :resolve
    post "/identity/compare",                 IdentityController, :compare
    get  "/identity/:identifier/identifiers", IdentityController, :identifiers

    # Namespace
    post "/namespaces",         NamespacePleromaController, :create_or_get
    get  "/namespaces",         NamespacePleromaController, :get
    post "/namespaces/sync",    NamespacePleromaController, :sync
    get  "/namespaces/account", NamespacePleromaController, :get_account_info

    # Auth
    post "/apps",                        AuthController, :register_app
    post "/account/register",            AuthController, :register_account
    get  "/pleroma/captcha",             AuthController, :get_captcha
    post "/pleroma/delete_account",      AuthController, :delete_account
    post "/pleroma/disable_account",     AuthController, :disable_account
    get  "/pleroma/accounts/mfa",        AuthController, :get_mfa
    post "/oauth/token",                 AuthController, :get_token
    get  "/accounts/verify_credentials", AuthController, :verify_credentials
    get  "/accounts/did",                AuthController, :get_did

    # Sessions
    get    "/sessions",     AuthController, :list_sessions
    delete "/sessions",     AuthController, :revoke_all_sessions
    delete "/sessions/:id", AuthController, :revoke_session

    # Email / OTP
    post "/account/verify_email", AuthController, :verify_email
    post "/account/resend_otp",   AuthController, :resend_otp

    # Password
    post "/account/reset_password",  AuthController, :reset_password
    post "/account/forgot_password", AuthController, :forgot_password
  end

  # =======================
  # OTHER APIs
  # =======================

  scope "/api/v1/vault", AlemWeb do
    pipe_through :api
    get "/epoch/current", EpochController, :current
  end

  scope "/", AlemWeb do
    pipe_through :api
    get "/.well-known/did.json", EpochController, :did_document
  end

  scope "/api/v1/analytics", AlemWeb do
    pipe_through :api
    post "/ingest", AnalyticsController, :ingest
    get  "/schema", AnalyticsController, :schema
  end

  scope "/api/v1/media", AlemWeb do
    pipe_through :api
    post "/transcribe", MediaController, :transcribe
    post "/analyze",    MediaController, :analyze
  end

  scope "/api/v1/sync", AlemWeb do
    pipe_through :api

    post "/upload-url",           SyncController, :get_upload_url
    post "/apply",                SyncController, :apply_changes
    get  "/changes",              SyncController, :get_changes
    get  "/stats",                SyncController, :get_stats
    get  "/download/:doc_id",     SyncController, :download_file
    post "/upload",               SyncController, :upload_document
    post "/crdt/upload",          SyncController, :crdt_upload
    post "/crdt/upload_chunk",    SyncController, :chunk_upload
    post "/crdt/finalize_upload", SyncController, :finalize_upload

    # V2
    post "/v2/initiate", SyncController, :v2_initiate
    post "/v2/part",     SyncController, :v2_upload_part
    post "/v2/complete", SyncController, :v2_complete

    # SSE
    get "/stream", SyncController, :event_stream
  end

  # =======================
  # GRAPHQL
  # =======================

  scope "/graphql" do
    pipe_through :api

    forward "/", Absinthe.Plug,
      schema: AlemWeb.Schema,
      json_codec: Jason
  end

  if Mix.env() == :dev do
    scope "/graphiql" do
      pipe_through :browser

      forward "/", Absinthe.Plug.GraphiQL,
        schema: AlemWeb.Schema,
        interface: :simple
    end
  end

  # =======================
  # HEALTH
  # =======================

  scope "/api", AlemWeb do
    pipe_through :api
    get "/health", HealthController, :check
  end

  # =======================
  # DEV TOOLS
  # =======================

  if Application.compile_env(:alem, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AlemWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  # =======================
  # 🔥 SWAGGER UI
  # =======================

  scope "/api/docs" do
    pipe_through :browser

    get "/", OpenApiSpex.Plug.SwaggerUI,
      path: "/api/openapi",
      default_model_expand_depth: 2
  end
  # =======================
 # =======================
  # CHAT API
  # =======================

  # ✅ எல்லாமே Protected — Pleroma token required
  # Token controller வேண்டாம் — ஒரே token மட்டும்
  scope "/api/v1/chat", AlemWeb do
    pipe_through [:api, AlemWeb.Plugs.ChatAuth]

    # Rooms
    get    "/rooms",              Chat.RoomController,    :index
    post   "/rooms",              Chat.RoomController,    :create
    get    "/rooms/:id",          Chat.RoomController,    :show
    get    "/rooms/:id/members",  Chat.RoomController,    :members
    get    "/rooms/:id/status",   Chat.RoomController,    :status
    post   "/rooms/:id/join",     Chat.RoomController,    :join
    delete "/rooms/:id/leave",    Chat.RoomController,    :leave

    # Messages
    get    "/rooms/:id/messages", Chat.MessageController, :index
    post   "/rooms/:id/messages", Chat.MessageController, :send_message
    post   "/messages/private",   Chat.MessageController, :send_private

    # Typing
    post   "/rooms/:id/typing",   Chat.TypingController,  :notify
  end

  # =======================
  # OPENAPI JSON
  # =======================

  scope "/api" do
    pipe_through :api

    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
  end
end
