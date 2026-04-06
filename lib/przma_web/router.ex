defmodule PrzmaWeb.Router do
  use PrzmaWeb, :router

  # ═══════════════════════════════════════════════════════════════
  # PIPELINES
  # ═══════════════════════════════════════════════════════════════

  pipeline :api do
    plug :accepts, ["json"]
    plug PrzmaWeb.Plugs.SecurityHeaders
    plug PrzmaWeb.Plugs.RateLimit, limit: 100, window_seconds: 60
  end

  pipeline :authenticated do
    plug :accepts, ["json"]
    plug PrzmaWeb.Plugs.SecurityHeaders
    plug PrzmaWeb.Plugs.DIDAuthPlug
    plug PrzmaWeb.Plugs.RateLimit, limit: 500, window_seconds: 60
  end

  pipeline :agent_auth do
    plug :accepts, ["json"]
    plug PrzmaWeb.Plugs.CapabilityTokenPlug
    plug PrzmaWeb.Plugs.RateLimit, limit: 200, window_seconds: 60
  end

  pipeline :activitypub do
    plug :accepts, ["json", "application/activity+json", "application/ld+json"]
    plug PrzmaWeb.Plugs.SecurityHeaders
    plug PrzmaWeb.Plugs.RateLimit, limit: 50, window_seconds: 60
  end

  pipeline :xrpc do
    plug :accepts, ["json"]
    plug PrzmaWeb.Plugs.SecurityHeaders
    plug PrzmaWeb.Plugs.XRPCLexiconValidate
  end

  pipeline :xrpc_auth do
    plug :accepts, ["json"]
    plug PrzmaWeb.Plugs.SecurityHeaders
    plug PrzmaWeb.Plugs.DIDAuthPlug
    plug PrzmaWeb.Plugs.XRPCLexiconValidate
  end

  # ═══════════════════════════════════════════════════════════════
  # SWAGGER UI
  # ═══════════════════════════════════════════════════════════════

  scope "/api" do
    pipe_through :api
    get "/openapi",   OpenApiSpex.Plug.RenderSpec,  []
    get "/swaggerui", OpenApiSpex.Plug.SwaggerUI,   path: "/api/openapi"
  end

  # ═══════════════════════════════════════════════════════════════
  # WELL-KNOWN — Fediverse discovery
  # ═══════════════════════════════════════════════════════════════

  scope "/.well-known", PrzmaWeb do
    pipe_through :api
    get "/webfinger", WebFingerController, :show
    get "/nodeinfo",  NodeInfoController,  :show
    get "/host-meta", HostMetaController,  :show
    get "/did.json",  DIDController,       :well_known
  end

  # ═══════════════════════════════════════════════════════════════
  # ACTIVITYPUB — Federation (S2S)
  # ═══════════════════════════════════════════════════════════════

  scope "/", PrzmaWeb.ActivityPub do
    pipe_through :activitypub

    get  "/users/:did",              ActorController,       :show
    post "/users/:did/inbox",        InboxController,       :create
    get  "/users/:did/outbox",       OutboxController,      :index
    post "/inbox",                   SharedInboxController, :create
    get  "/circles/:circle_did",     CircleActorController, :show
    post "/circles/:circle_did/inbox", CircleInboxController, :create
    get  "/memorial/:did",           MemorialActorController, :show
    get  "/objects/:cid",            ObjectController,      :show
    get  "/users/:did/followers",    FollowersController,   :index
    get  "/users/:did/following",    FollowingController,   :index
  end

  # ═══════════════════════════════════════════════════════════════
  # AUTH — DID registration and token issuance
  # ═══════════════════════════════════════════════════════════════

  scope "/auth", PrzmaWeb.Auth do
    pipe_through :api
    post   "/did/register",  DIDController,   :register
    post   "/did/challenge", DIDController,   :challenge
    post   "/did/verify",    DIDController,   :verify
    post   "/did/rotate",    DIDController,   :rotate_key
    post   "/token/refresh", TokenController, :refresh
    delete "/token/revoke",  TokenController, :revoke
  end

  # ═══════════════════════════════════════════════════════════════
  # XRPC — Public (no auth)
  # ═══════════════════════════════════════════════════════════════

  scope "/xrpc", PrzmaWeb do
    pipe_through :xrpc
    get "/app.przma.chat.shout.feed", XRPCRouter, :handle
    get "/app.przma.actor.resolve",   XRPCRouter, :handle
  end

  # ═══════════════════════════════════════════════════════════════
  # XRPC — Authenticated
  # ═══════════════════════════════════════════════════════════════

  scope "/xrpc", PrzmaWeb do
    pipe_through :xrpc_auth

    get  "/app.przma.inbox.list",             XRPCRouter, :handle
    post "/app.przma.inbox.markRead",         XRPCRouter, :handle
    post "/app.przma.inbox.delete",           XRPCRouter, :handle
    get  "/app.przma.outbox.list",            XRPCRouter, :handle
    post "/app.przma.outbox.retry",           XRPCRouter, :handle

    post "/app.przma.chat.dm.send",           XRPCRouter, :handle
    get  "/app.przma.chat.dm.list",           XRPCRouter, :handle
    get  "/app.przma.chat.dm.threads",        XRPCRouter, :handle
    post "/app.przma.chat.dm.delete",         XRPCRouter, :handle
    post "/app.przma.chat.dm.react",          XRPCRouter, :handle

    post "/app.przma.chat.circle.send",       XRPCRouter, :handle
    get  "/app.przma.chat.circle.list",       XRPCRouter, :handle
    post "/app.przma.chat.circle.join",       XRPCRouter, :handle
    post "/app.przma.chat.circle.accept",     XRPCRouter, :handle
    post "/app.przma.chat.circle.leave",      XRPCRouter, :handle

    post "/app.przma.collab.circle.share",    XRPCRouter, :handle
    post "/app.przma.collab.circle.docOp",    XRPCRouter, :handle

    post "/app.przma.chat.shout.broadcast",   XRPCRouter, :handle

    post "/app.przma.vault.put",              XRPCRouter, :handle
    get  "/app.przma.vault.get",              XRPCRouter, :handle
    get  "/app.przma.vault.list",             XRPCRouter, :handle
    post "/app.przma.vault.delete",           XRPCRouter, :handle
    post "/app.przma.vault.grant",            XRPCRouter, :handle

    post "/app.przma.scan.create",            XRPCRouter, :handle
    get  "/app.przma.scan.list",              XRPCRouter, :handle
    post "/app.przma.signal.emit",            XRPCRouter, :handle
    post "/app.przma.reflection.create",      XRPCRouter, :handle

    post "/app.przma.circle.create",          XRPCRouter, :handle
    get  "/app.przma.circle.members",         XRPCRouter, :handle
    post "/app.przma.circle.invite",          XRPCRouter, :handle

    post "/app.przma.agent.message",          XRPCRouter, :handle
    post "/app.przma.agent.draft.approve",    XRPCRouter, :handle

    post "/app.przma.memorial.query",         XRPCRouter, :handle
    post "/app.przma.memorial.activate",      XRPCRouter, :handle

    post "/app.przma.studio.upload.initiate", XRPCRouter, :handle
    get  "/app.przma.studio.upload.status",   XRPCRouter, :handle

    get  "/app.przma.analytics.filterTrend",        XRPCRouter, :handle
    get  "/app.przma.analytics.signalDistribution", XRPCRouter, :handle
    get  "/app.przma.analytics.foggedFilters",      XRPCRouter, :handle
    get  "/app.przma.analytics.collectivePattern",  XRPCRouter, :handle
    get  "/app.przma.analytics.circleInsight",      XRPCRouter, :handle
  end

  scope "/xrpc", PrzmaWeb do
    pipe_through :agent_auth
    post "/app.przma.agent.vault.read",  XRPCRouter, :handle
    post "/app.przma.agent.draft.stage", XRPCRouter, :handle
  end

  # ═══════════════════════════════════════════════════════════════
  # VAULT BLOB UPLOAD
  # ═══════════════════════════════════════════════════════════════

  scope "/vault", PrzmaWeb.Vault do
    pipe_through :authenticated
    post "/upload/presign",  BlobController, :presign
    post "/upload/confirm",  BlobController, :confirm
    post "/upload/inline",   BlobController, :inline
  end

  # ═══════════════════════════════════════════════════════════════
  # HEALTH
  # ═══════════════════════════════════════════════════════════════

  scope "/", PrzmaWeb do
    pipe_through :api
    get "/health",       HealthController,  :check
    get "/nodeinfo/2.1", NodeInfoController, :v21
  end
end
