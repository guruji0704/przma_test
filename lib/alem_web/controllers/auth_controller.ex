defmodule AlemWeb.AuthController do
  use AlemWeb, :controller
  require Logger

  defp pleroma_base_url do
    Application.get_env(:alem, :pleroma, [])[:base_url] ||
      System.get_env("PLEROMA_BASE_URL") ||
      "https://pleroma.social"
  end

  # Helper to parse response body - handles both string and map responses
  defp parse_response_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> body
    end
  end

  defp parse_response_body(body) when is_map(body), do: body
  defp parse_response_body(body), do: body

  @doc """
  Register an OAuth application
  POST /api/v1/apps
  """
  def register_app(conn, params) do
    url = "#{pleroma_base_url()}/api/v1/apps"
    Logger.info("Calling Pleroma API: POST #{url}")

    # Prepare request body
    body = %{
      "client_name" => params["client_name"] || params[:client_name],
      "redirect_uris" => params["redirect_uris"] || params[:redirect_uris] || "",
      "scopes" => params["scopes"] || params[:scopes] || "read write follow push",
      "website" => params["website"] || params[:website]
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()

    case Req.post(url, json: body) do
      {:ok, %{status: status, body: response_body}} when status in [200, 201] ->
        Logger.info("OAuth app registered successfully")
        conn |> put_status(status) |> json(parse_response_body(response_body))

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("Pleroma API error: #{status} - URL: #{url} - Response: #{inspect(response_body)}")
        conn |> put_status(status) |> json(parse_response_body(response_body))

      {:error, reason} ->
        Logger.error("Failed to call Pleroma API: #{inspect(reason)}")
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to connect to Pleroma API", details: inspect(reason)})
    end
  end

  @doc """
  Get OAuth token
  POST /oauth/token
  """
  def get_token(conn, params) do
    url = "#{pleroma_base_url()}/oauth/token"
    Logger.info("Calling Pleroma API: POST #{url}")

    # Prepare form data for OAuth token request
    form_data =
      params
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

    case Req.post(url, form: form_data) do
      {:ok, %{status: status, body: response_body}} when status in [200, 201] ->
        Logger.info("OAuth token obtained successfully")
        conn |> put_status(status) |> json(parse_response_body(response_body))

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("Pleroma API error: #{status} - URL: #{url} - Response: #{inspect(response_body)}")
        conn |> put_status(status) |> json(parse_response_body(response_body))

      {:error, reason} ->
        Logger.error("Failed to call Pleroma API: #{inspect(reason)}")
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to connect to Pleroma API", details: inspect(reason)})
    end
  end

  @doc """
  Register a new user account
  POST /api/account/register
  """
  def register_account(conn, params) do
    url = "#{pleroma_base_url()}/api/account/register"
    Logger.info("Calling Pleroma API: POST #{url}")

    # Prepare request body
    body =
      params
      |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
      |> Map.new()

    case Req.post(url, json: body) do
      {:ok, %{status: status, body: response_body}} when status in [200, 201] ->
        Logger.info("Account registered successfully")
        conn |> put_status(status) |> json(parse_response_body(response_body))

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("Pleroma API error: #{status} - URL: #{url} - Response: #{inspect(response_body)}")
        conn |> put_status(status) |> json(parse_response_body(response_body))

      {:error, reason} ->
        Logger.error("Failed to call Pleroma API: #{inspect(reason)}")
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to connect to Pleroma API", details: inspect(reason)})
    end
  end

  @doc """
  Get captcha for registration
  GET /api/v1/pleroma/captcha
  """
  def get_captcha(conn, _params) do
    url = "#{pleroma_base_url()}/api/v1/pleroma/captcha"
    Logger.info("Calling Pleroma API: GET #{url}")
    |> IO.inspect(label: "url")

    case Req.get(url) do
      {:ok, %{status: 200, body: response_body}} ->
        Logger.info("Captcha retrieved successfully")
        conn |> json(parse_response_body(response_body))

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("Pleroma API error: #{status} - URL: #{url} - Response: #{inspect(response_body)}")
        conn |> put_status(status) |> json(parse_response_body(response_body))

      {:error, reason} ->
        Logger.error("Failed to call Pleroma API: #{inspect(reason)}")
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to connect to Pleroma API", details: inspect(reason)})
    end
  end

  @doc """
  Delete account
  POST /api/pleroma/delete_account
  """
  def delete_account(conn, params) do
    url = "#{pleroma_base_url()}/api/pleroma/delete_account"
    Logger.info("Calling Pleroma API: POST #{url}")

    # Get authorization header from request
    auth_header = Plug.Conn.get_req_header(conn, "authorization")

    headers =
      if auth_header != [] do
        [{"authorization", List.first(auth_header)}]
      else
        []
      end

    body = %{
      "password" => params["password"] || params[:password]
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
    |> Map.new()

    case Req.post(url, json: body, headers: headers) do
      {:ok, %{status: status, body: response_body}} when status in [200, 201, 204] ->
        Logger.info("Account deletion requested")
        parsed_body = parse_response_body(response_body || %{message: "Account deletion scheduled"})
        conn |> put_status(status) |> json(parsed_body)

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("Pleroma API error: #{status} - URL: #{url} - Response: #{inspect(response_body)}")
        conn |> put_status(status) |> json(parse_response_body(response_body))

      {:error, reason} ->
        Logger.error("Failed to call Pleroma API: #{inspect(reason)}")
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to connect to Pleroma API", details: inspect(reason)})
    end
  end

  @doc """
  Disable account
  POST /api/pleroma/disable_account
  """
  def disable_account(conn, params) do
    url = "#{pleroma_base_url()}/api/pleroma/disable_account"
    Logger.info("Calling Pleroma API: POST #{url}")

    # Get authorization header from request
    auth_header = Plug.Conn.get_req_header(conn, "authorization")

    headers =
      if auth_header != [] do
        [{"authorization", List.first(auth_header)}]
      else
        []
      end

    body = %{
      "password" => params["password"] || params[:password]
    }
    |> Enum.reject(fn {_, v} -> is_nil(v) or v == "" end)
    |> Map.new()

    case Req.post(url, json: body, headers: headers) do
      {:ok, %{status: status, body: response_body}} when status in [200, 201, 204] ->
        Logger.info("Account disable requested")
        parsed_body = parse_response_body(response_body || %{message: "Account disabled"})
        conn |> put_status(status) |> json(parsed_body)

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("Pleroma API error: #{status} - URL: #{url} - Response: #{inspect(response_body)}")
        conn |> put_status(status) |> json(parse_response_body(response_body))

      {:error, reason} ->
        Logger.error("Failed to call Pleroma API: #{inspect(reason)}")
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to connect to Pleroma API", details: inspect(reason)})
    end
  end

  @doc """
  Get MFA settings
  GET /api/v1/pleroma/accounts/mfa
  """
  def get_mfa(conn, _params) do
    url = "#{pleroma_base_url()}/api/v1/pleroma/accounts/mfa"
    Logger.info("Calling Pleroma API: GET #{url}")

    # Get authorization header from request
    auth_header = Plug.Conn.get_req_header(conn, "authorization")

    headers =
      if auth_header != [] do
        [{"authorization", List.first(auth_header)}]
      else
        []
      end

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: response_body}} ->
        Logger.info("MFA settings retrieved successfully")
        conn |> json(parse_response_body(response_body))

      {:ok, %{status: status, body: response_body}} ->
        Logger.error("Pleroma API error: #{status} - URL: #{url} - Response: #{inspect(response_body)}")
        conn |> put_status(status) |> json(parse_response_body(response_body))

      {:error, reason} ->
        Logger.error("Failed to call Pleroma API: #{inspect(reason)}")
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to connect to Pleroma API", details: inspect(reason)})
    end
  end
end
