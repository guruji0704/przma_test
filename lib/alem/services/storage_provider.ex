defmodule Alem.Services.StorageProvider do
  @moduledoc """
  Pluggable storage provider behaviour.
  Default: PRZMA managed Linode S3.
  Custom:  User's own S3/MinIO/R2 via Settings -> Providers (Phase 4).
  """

  @callback put(provider :: map, key :: String.t, data :: binary, ctype :: String.t) ::
              :ok | {:error, term}
  @callback get(provider :: map, key :: String.t) ::
              {:ok, binary} | {:error, term}
  @callback delete(provider :: map, key :: String.t) ::
              :ok | {:error, term}
  @callback exists?(provider :: map, key :: String.t) :: boolean
  @callback presigned_url(provider :: map, key :: String.t, opts :: keyword) ::
              {:ok, String.t} | {:error, term}

  # ── Resolution ─────────────────────────────────────────────────────────────

  def for_user(user) do
    case Alem.Api.ProviderApi.active_storage_provider(user) do
      {:managed, p} -> p
      {:custom,  p} -> p
    end
  rescue
    _ -> default_provider()
  end

  def for_vault(user, _vault), do: for_user(user)

  def default_provider do
    %{
      adapter:  Alem.Adapters.Storage.S3Adapter,
      bucket:   System.get_env("AWS_S3_BUCKET", "perkeep"),
      endpoint: System.get_env("AWS_ENDPOINT", "https://in-maa-1.linodeobjects.com"),
      region:   System.get_env("AWS_DEFAULT_REGION", "in-maa-1"),
      managed:  true
    }
  end

  # ── Dispatch ───────────────────────────────────────────────────────────────

  def put(%{adapter: a} = p, key, data, ctype),  do: a.put(p, key, data, ctype)
  def get(%{adapter: a} = p, key),               do: a.get(p, key)
  def delete(%{adapter: a} = p, key),            do: a.delete(p, key)
  def exists?(%{adapter: a} = p, key),           do: a.exists?(p, key)
  def presigned_url(%{adapter: a} = p, key, opts \\ []),
    do: a.presigned_url(p, key, opts)
end
