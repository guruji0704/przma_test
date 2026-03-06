defmodule AlemWeb.Router do
  use AlemWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
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

  # ── API Routes ────────────────────────────────────────────────────────────
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
    post "/apps",                        AuthController, :register_app
    post "/account/register",            AuthController, :register_account
    get  "/pleroma/captcha",             AuthController, :get_captcha
    post "/pleroma/delete_account",      AuthController, :delete_account
    post "/pleroma/disable_account",     AuthController, :disable_account
    get  "/pleroma/accounts/mfa",        AuthController, :get_mfa
    post "/oauth/token",                 AuthController, :get_token
    get  "/accounts/verify_credentials", AuthController, :verify_credentials
    get  "/accounts/did",                AuthController, :get_did

    # Email Verification
    post "/account/verify_email", AuthController, :verify_email
    post "/account/resend_otp",   AuthController, :resend_otp

    # Forgot / Reset Password
    post "/account/forgot_password", AuthController, :forgot_password
    post "/account/reset_password",  AuthController, :reset_password

    # Session Endpoints
    get    "/sessions",     AuthController, :list_sessions
    delete "/sessions",     AuthController, :revoke_all_sessions
    delete "/sessions/:id", AuthController, :revoke_session
  end

  # ── Sync Routes ───────────────────────────────────────────────────────────
  scope "/api/v1/sync", AlemWeb do
    pipe_through :api

    post "/upload-url",  SyncController, :get_upload_url
    post "/apply",       SyncController, :apply_changes
    get  "/changes",     SyncController, :get_changes
    get  "/stats",       SyncController, :get_stats
    post "/upload",      SyncController, :upload_document
    post "/crdt/upload", SyncController, :crdt_upload
  end

  # ── Swagger UI ────────────────────────────────────────────────────────────
  scope "/api/swagger" do
    pipe_through :browser
    get "/", OpenApiSpex.Plug.SwaggerUI, path: "/api/swagger/openapi.json"
  end

  scope "/api/swagger" do
    pipe_through [:swagger]
    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
  end

  # ── Dev Routes ────────────────────────────────────────────────────────────
  if Application.compile_env(:alem, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: AlemWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
