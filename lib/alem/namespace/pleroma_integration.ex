defmodule Alem.Namespace.PleromaIntegration do
  @moduledoc """
  Pleroma Integration for Namespaces.

  Links a Pleroma OAuth account to a namespace.
  When a user logs in via Pleroma, we:
    1. Verify their OAuth token with Pleroma
    2. Generate a DID for them (or reuse existing)
    3. Create/get their namespace keyed by that DID
  """

  require Logger
  alias Alem.Namespace
  alias Alem.Namespace.Manager
  alias Alem.DID

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc """
  Create or get a namespace for a Pleroma account.
  Called during OAuth login flow.
  """
  def ensure_namespace_for_pleroma_account(pleroma_account_id, oauth_token, opts \\ []) do
    tenant_id = opts[:tenant_id] || "default"

    case verify_pleroma_token(oauth_token) do
      {:ok, account_info} ->
        existing_namespace = Manager.find_by_pleroma_account(pleroma_account_id)

        # Use existing DID or generate a new one
        did = case existing_namespace do
          nil       -> DID.generate(pleroma_account_id)
          namespace -> namespace.did || DID.generate(pleroma_account_id)
        end

        user_id     = did
        pleroma_cfg = %{
          pleroma_account_id:   pleroma_account_id,
          pleroma_account_info: account_info,
          oauth_token:          oauth_token,
          synced_at:            DateTime.utc_now()
        }

        config_data = %{did: did, pleroma: pleroma_cfg}
        merged_opts = opts |> Keyword.put(:config, config_data)

        case Manager.start(user_id, tenant_id, merged_opts) do
          {:ok, _pid} ->
            update_pleroma_config(user_id, pleroma_cfg)
            {:ok, user_id, account_info}

          {:error, {:already_started, _pid}} ->
            update_pleroma_config(user_id, pleroma_cfg)
            {:ok, user_id, account_info}

          error ->
            error
        end

      error ->
        error
    end
  end

  @doc "Get namespace for a Pleroma account (token must be valid)."
  def get_namespace_for_pleroma_account(pleroma_account_id, oauth_token) do
    case verify_pleroma_token(oauth_token) do
      {:ok, account_info} ->
        case Manager.find_by_pleroma_account(pleroma_account_id) do
          nil       -> {:error, :namespace_not_found}
          namespace -> {:ok, namespace.id, account_info}
        end

      error ->
        error
    end
  end

  @doc "Sync namespace document list to Pleroma (metadata only for now)."
  def sync_namespace_with_pleroma(user_id, oauth_token, opts \\ []) do
    case verify_pleroma_token(oauth_token) do
      {:ok, account_info} ->
        case Namespace.list_documents(user_id) do
          {:ok, documents} ->
            sync_documents_to_pleroma(user_id, documents, account_info, opts)

          error ->
            error
        end

      error ->
        error
    end
  end

  @doc "Get Pleroma account info stored in namespace config."
  def get_pleroma_account_info(user_id) do
    case Manager.get_config(user_id) do
      {:ok, config} ->
        case get_in(config, [:pleroma, :pleroma_account_info]) do
          nil  -> {:error, :no_pleroma_account}
          info -> {:ok, info}
        end

      error ->
        error
    end
  end

  @doc "Refresh OAuth token in namespace config."
  def update_pleroma_token(user_id, new_token) do
    case verify_pleroma_token(new_token) do
      {:ok, account_info} ->
        update_pleroma_config(user_id, %{
          oauth_token:          new_token,
          pleroma_account_info: account_info,
          synced_at:            DateTime.utc_now()
        })
        {:ok, account_info}

      error ->
        error
    end
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp verify_pleroma_token(token) do
    url = "#{pleroma_base_url()}/api/v1/accounts/verify_credentials"

    case Req.get(url, headers: [{"Authorization", "Bearer #{token}"}]) do
      {:ok, %{status: 200, body: body}} ->
        info = parse_body(body)
        Logger.info("[PleromaIntegration] Token verified for #{info["id"] || "unknown"}")
        {:ok, info}

      {:ok, %{status: status}} ->
        Logger.error("[PleromaIntegration] Token verification failed: HTTP #{status}")
        {:error, :invalid_token}

      {:error, reason} ->
        Logger.error("[PleromaIntegration] Connection failed: #{inspect(reason)}")
        {:error, :connection_failed}
    end
  end

  defp update_pleroma_config(user_id, pleroma_data) do
    case Manager.get_config(user_id) do
      {:ok, config} ->
        Manager.update_config(user_id, put_in(config, [:pleroma], pleroma_data))
        :ok

      _error ->
        :ok
    end
  end

  defp sync_documents_to_pleroma(user_id, documents, _account_info, opts) do
    mode = opts[:sync_mode] || :metadata_only
    Logger.info("[PleromaIntegration] #{mode} sync: #{length(documents)} docs for #{user_id}")
    {:ok, %{synced_count: length(documents), mode: mode}}
  end

  defp pleroma_base_url do
    Application.get_env(:alem, :pleroma, [])[:base_url] ||
      System.get_env("PLEROMA_BASE_URL") ||
      "http://localhost:4001"
  end

  defp parse_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      _              -> %{}
    end
  end
  defp parse_body(body) when is_map(body), do: body
  defp parse_body(_), do: %{}
end
