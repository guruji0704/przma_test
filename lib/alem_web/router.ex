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

  scope "/api", AlemWeb do
    pipe_through :api

    get "/test-namespace", NamespaceController, :test
  end

  scope "/api/swagger" do
    pipe_through :browser

    get "/", OpenApiSpex.Plug.SwaggerUI, path: "/api/swagger/openapi.json"
  end

  scope "/api/swagger" do
    pipe_through [:swagger]

    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
  end

  if Application.compile_env(:alem, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: AlemWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
