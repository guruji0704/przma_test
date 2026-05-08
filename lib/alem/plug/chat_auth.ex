defmodule AlemWeb.Plugs.ChatAuth do
  import Plug.Conn
  import Phoenix.Controller

  require Logger

  def init(opts), do: opts

  # =====================================================
  # MAIN
  # =====================================================

  def call(conn, _opts) do
    case extract_token(conn) do
      nil ->
        unauthorized(conn)

      token ->
        case verify_token(token) do
          {:ok, user} ->
            conn
            |> assign(:current_user, user)
            |> assign(:access_token, token)

          {:error, reason} ->
            Logger.error("Chat auth failed: #{inspect(reason)}")

            conn
            |> put_status(401)
            |> json(%{
              error: "Unauthorized"
            })
            |> halt()
        end
    end
  end

  # =====================================================
  # TOKEN EXTRACT
  # =====================================================

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        String.trim(token)

      _ ->
        nil
    end
  end

  # =====================================================
  # VERIFY TOKEN
  # =====================================================

  defp verify_token(token) do
    url = "http://localhost:4000/api/v1/accounts/verify_credentials"

    headers = [
      {"authorization", "Bearer #{token}"},
      {"accept", "application/json"}
    ]

    # IMPORTANT
    case HTTPoison.get(url, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        parse_user(body)

      {:ok, %HTTPoison.Response{status_code: 401}} ->
        {:error, :invalid_token}

      {:error, error} ->
        {:error, error}

      other ->
        {:error, other}
    end
  end

  # =====================================================
  # PARSE USER
  # =====================================================

  defp parse_user(body) do
    case Jason.decode(body) do
      {:ok, data} ->

        # YOUR TOKEN RESPONSE HAS "me"
        username =
          data["me"] ||
          data["nickname"] ||
          data["username"]

        did =
          data["did"] ||
          data["id"]

        if is_nil(username) do
          {:error, :invalid_user}
        else
          {:ok,
           %{
             username: username,
             did: did
           }}
        end

      error ->
        error
    end
  end

  # =====================================================
  # COMMON RESPONSE
  # =====================================================

  defp unauthorized(conn) do
    conn
    |> put_status(401)
    |> json(%{
      error: "Unauthorized",
      message: "Send Bearer token in Authorization header"
    })
    |> halt()
  end
end
