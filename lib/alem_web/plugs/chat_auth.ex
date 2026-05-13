defmodule AlemWeb.Plugs.ChatAuth do
  @moduledoc """
  Chat Auth Plug — validates Bearer token and assigns a normalized current_user map.

  Calls Alem.Auth.verify_token/1 which checks:
    - Token exists in DB
    - Not revoked (revoked_at IS NULL)
    - Not expired (valid_until > NOW)
    - User is active (is_active == true)

  Assigns conn.assigns[:current_user] as:
    %{id: ..., username: ..., did: ..., email: ...}

  Field mapping: User.nickname -> username, User.did_id -> did
  """
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        token = String.trim(token)

        case Alem.Auth.verify_token(token) do
          {:ok, user} ->
            conn
            |> assign(:current_user, %{
              id:       user.id,
              username: user.nickname,
              did:      user.did_id,
              email:    user.email
            })
            |> assign(:access_token, token)

          {:error, :invalid_token} ->
            conn
            |> put_status(401)
            |> json(%{
              error:   "Unauthorized",
              message: "Token expired or invalid. Login via POST /api/v1/oauth/token"
            })
            |> halt()
        end

      _ ->
        conn
        |> put_status(401)
        |> json(%{
          error:   "Unauthorized",
          message: "Send Bearer token in Authorization header. Login via POST /api/v1/oauth/token"
        })
        |> halt()
    end
  end
end
