defmodule AlemWeb.Plugs.ChatAuth do
  @moduledoc """
  Chat Auth Plug — Direct DB query approach.
  - No HTTP self-call
  - Queries Token table directly from DB
  - Gets User (username + DID) from DB via token.user_id
  - Single token — Pleroma OAuth token is enough
  """

  import Plug.Conn
  import Phoenix.Controller

  alias Alem.Repo
  alias Alem.Pleroma.User
  alias Alem.Pleroma.Web.OAuth.Token

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> access_token] ->
        access_token = String.trim(access_token)

        # Step 1: Find token record in DB
        token = Repo.get_by(Token, token: access_token)

        case token do
          nil ->
            # Token not found in DB — invalid
            conn
            |> put_status(401)
            |> json(%{
              error: "Unauthorized",
              message: "Token not found. Login via POST /api/v1/oauth/token"
            })
            |> halt()

          token ->
            # Step 2: Get user from DB using token.user_id
            user = Repo.get(User, token.user_id)

            case user do
              nil ->
                # User not found — deleted or not registered
                conn
                |> put_status(403)
                |> json(%{
                  error: "User not found",
                  message: "Please register via POST /api/v1/account/register"
                })
                |> halt()

              user ->
                # Success — attach user to conn
                # username + DID available in all chat controllers
                conn
                |> assign(:current_user, %{
                  username: user.nickname,
                  did:      user.did_id,
                  email:    user.email,
                  id:       user.id
                })
                |> assign(:access_token, access_token)
            end
        end

      _ ->
        # No Authorization header
        conn
        |> put_status(401)
        |> json(%{
          error: "Unauthorized",
          message: "Send Bearer token in Authorization header. Login via POST /api/v1/oauth/token"
        })
        |> halt()
    end
  end
end
