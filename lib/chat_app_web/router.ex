defmodule ChatAppWeb.Router do
  use ChatAppWeb, :router

  # Browser pipeline — every web request goes through these steps
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session          # reads the saved session (username, room)
    plug :fetch_live_flash
    plug :put_root_layout, html: {ChatAppWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", ChatAppWeb do
    pipe_through :browser

    # Home page — user enters name and picks a room
    #live "/", JoinLive

    # Chat page — actual chat happens here
    # Single entry point (from PRZMA/Tauri)
    live "/chat", ChatLive

    # After joining, we save username+room in session using this route
    #get "/save_session", SessionController, :save
  end

  if Application.compile_env(:chat_app, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser
      live_dashboard "/dashboard", metrics: ChatAppWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
