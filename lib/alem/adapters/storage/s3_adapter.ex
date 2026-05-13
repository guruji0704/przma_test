defmodule Alem.Adapters.Storage.S3Adapter do
  @moduledoc "S3-compatible adapter. Only place ExAws.S3 is called."
  @behaviour Alem.Services.StorageProvider
  require Logger

  @impl true
  def put(provider, key, data, content_type) do
    Logger.info("[S3] PUT #{provider.bucket}/#{key} (#{byte_size(data)}b) → #{host(provider)}")
    case exec(provider, ExAws.S3.put_object(provider.bucket, key, data, content_type: content_type)) do
      {:ok, _} -> :ok
      err      -> err
    end
  end

  @impl true
  def get(provider, key) do
    case exec(provider, ExAws.S3.get_object(provider.bucket, key)) do
      {:ok, %{body: body}} -> {:ok, body}
      err                  -> err
    end
  end

  @impl true
  def delete(provider, key) do
    case exec(provider, ExAws.S3.delete_object(provider.bucket, key)) do
      {:ok, _} -> :ok
      err      -> err
    end
  end

  @impl true
  def exists?(provider, key) do
    case exec(provider, ExAws.S3.head_object(provider.bucket, key)) do
      {:ok, _}                        -> true
      {:error, {:http_error, 404, _}} -> false
      _                               -> false
    end
  end

  @impl true
  def presigned_url(provider, key, opts) do
    expires_in = Keyword.get(opts, :expires_in, 3600)
    cfg = ex_aws_config(provider)
    ExAws.S3.presigned_url(cfg, :get, provider.bucket, key, expires_in: expires_in)
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp exec(provider, request) do
    ExAws.request(request, ex_aws_config(provider))
  end

  defp ex_aws_config(%{managed: true}) do
    ExAws.Config.new(:s3,
      access_key_id:     [{:system, "AWS_ACCESS_KEY_ID"}],
      secret_access_key: [{:system, "AWS_SECRET_ACCESS_KEY"}],
      host:              strip_scheme(System.get_env("AWS_ENDPOINT", "")),
      scheme:            "https://",
      region:            System.get_env("AWS_DEFAULT_REGION", "us-east-1")
    )
  end

  defp ex_aws_config(provider) do
    # Use ExAws.Config.new to properly override host for custom providers
    ExAws.Config.new(:s3,
      access_key_id:     provider[:access_key],
      secret_access_key: provider[:secret_key],
      host:              strip_scheme(provider[:endpoint] || "s3.amazonaws.com"),
      scheme:            "https://",
      region:            provider[:region] || "us-east-1"
    )
  end

  defp host(%{managed: true}), do: System.get_env("AWS_ENDPOINT", "managed")
  defp host(p), do: p[:endpoint] || "unknown"

  defp strip_scheme(url) do
    url
    |> String.replace("https://", "")
    |> String.replace("http://", "")
    |> String.trim_trailing("/")
  end
end
